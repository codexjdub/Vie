import AppKit
import Carbon.HIToolbox
import VieWorkspace

/// The sidebar: the folder's tree in an outline view. Folders are listed when expanded; git-
/// ignored entries are dimmed; a click or Return opens a file. The context menu creates and
/// trashes files and renames them in place; dragging moves them (⌥ copies), to and from
/// Finder too. Edit ▸ Undo takes back a rename, move, copy or trash.
@MainActor
final class FileTreeController: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate, NSTextFieldDelegate {
    let tree: FileTree
    let outline = FileOutlineView()
    let view: NSView
    /// Opens a file (the window decides which tab).
    var onOpen: ((URL) -> Void)?
    /// The keyboard back to the editor: Esc, and ⌃L in Vim mode.
    var onLeave: (() -> Void)?
    /// Space e in Vim mode: hide the sidebar.
    var onToggleSidebar: (() -> Void)?
    /// Vim mode is on: the tree takes LazyVim's explorer keys (see `key(_:)`).
    var vimKeys = false
    /// When Space was pressed, waiting for e.
    private var spaceAt: TimeInterval?
    /// Shows why a file operation failed.
    var onError: ((Error) -> Void)?
    /// A file or folder was renamed or moved (open tabs follow it).
    var onRename: ((URL, URL) -> Void)?
    /// Moves an item to the Trash and gives where it went (tests use a folder of their own).
    var trashItem: (URL) throws -> URL = { url in
        var result: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &result)
        return (result as URL?) ?? url
    }

    private static let cellID = NSUserInterfaceItemIdentifier("cell")

    init(tree: FileTree) {
        self.tree = tree
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let effect = NSVisualEffectView()
        effect.material = .sidebar
        effect.blendingMode = .behindWindow
        effect.state = .followsWindowActiveState
        view = effect
        super.init()

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .sourceList
        outline.backgroundColor = .clear
        outline.rowSizeStyle = .small
        outline.indentationPerLevel = 12
        outline.autoresizesOutlineColumn = false
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(clicked(_:))
        outline.doubleAction = #selector(clicked(_:))
        let menu = NSMenu()
        menu.delegate = self
        outline.menu = menu
        // Dragged within Vie's trees an item moves (⌥ copies); dragged to another app it's a
        // file to copy, never to take away from the project.
        outline.registerForDraggedTypes([.fileURL])
        outline.setDraggingSourceOperationMask([.move, .copy], forLocal: true)
        outline.setDraggingSourceOperationMask(.copy, forLocal: false)
        scroll.documentView = outline
        scroll.frame = effect.bounds
        scroll.autoresizingMask = [.width, .height]
        effect.addSubview(scroll)

        tree.onChange = { [weak self] node in self?.changed(node) }
        outline.onKeyDown = { [weak self] event in self?.key(event) ?? false }
    }

    // MARK: - Keys

    /// Return opens the selected file (or opens or closes a folder); Esc goes back to the
    /// editor. In Vim mode, as in LazyVim's explorer: j and k move, l opens (a file, or a
    /// folder), h closes a folder (or the one holding the file), r renames, ⌃L goes back to
    /// the editor and Space e hides the sidebar. Other keys are the outline's (arrows, typing
    /// a name).
    private func key(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let chars = event.charactersIgnoringModifiers ?? ""
        let afterSpace = spaceAt.map { event.timestamp - $0 < 1 } ?? false
        spaceAt = nil
        if flags.isEmpty {
            switch Int(event.keyCode) {
            case kVK_Return, kVK_ANSI_KeypadEnter: openSelected(toggle: true); return true
            case kVK_Escape: onLeave?(); return true
            default: break
            }
        }
        guard vimKeys else { return false }
        if flags == .control {
            if chars == "l" { onLeave?(); return true }
            return chars == "h" // already here
        }
        guard flags.isEmpty else { return false }
        switch chars {
        case " ": spaceAt = event.timestamp
        case "e" where afterSpace: onToggleSidebar?()
        case "j": move(by: 1)
        case "k": move(by: -1)
        case "l": openSelected(toggle: false)
        case "h": closeSelected()
        case "r": if let node = selectedNode { beginRename(node) }
        default: return false
        }
        return true
    }

    private var selectedNode: FileNode? { outline.item(atRow: outline.selectedRow) as? FileNode }

    private func select(row: Int) {
        guard row >= 0, row < outline.numberOfRows else { return }
        outline.selectRowIndexes([row], byExtendingSelection: false)
        outline.scrollRowToVisible(row)
    }

    private func move(by delta: Int) {
        select(row: outline.selectedRow < 0 ? 0 : min(max(outline.selectedRow + delta, 0), outline.numberOfRows - 1))
    }

    /// Opens the selected file, or opens a folder. On an open folder, Return closes it and l
    /// moves into it.
    private func openSelected(toggle: Bool) {
        guard let node = selectedNode else { return }
        guard node.isDirectory else { onOpen?(node.url); return }
        if !outline.isItemExpanded(node) { outline.expandItem(node) }
        else if toggle { outline.collapseItem(node) }
        else if !(node.children ?? []).isEmpty { select(row: outline.selectedRow + 1) }
    }

    /// Closes the selected folder, or the folder holding the selection (and selects it).
    private func closeSelected() {
        guard let node = selectedNode else { return }
        if node.isDirectory, outline.isItemExpanded(node) { return outline.collapseItem(node) }
        guard let parent = node.parent, parent !== tree.root else { return }
        outline.collapseItem(parent)
        select(row: outline.row(forItem: parent))
    }

    // MARK: - Data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        tree.children(of: (item as? FileNode) ?? tree.root).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        tree.children(of: (item as? FileNode) ?? tree.root)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? FileNode)?.isDirectory ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FileNode else { return nil }
        let cell = outlineView.makeView(withIdentifier: Self.cellID, owner: self) as? NSTableCellView ?? makeCell()
        cell.textField?.stringValue = node.name
        cell.textField?.textColor = node.isIgnored ? .tertiaryLabelColor : .labelColor
        cell.imageView?.image = NSImage(systemSymbolName: node.isDirectory ? "folder" : "doc", accessibilityDescription: nil)
        cell.imageView?.contentTintColor = node.isIgnored ? .tertiaryLabelColor : (node.isDirectory ? .controlAccentColor : .secondaryLabelColor)
        return cell
    }

    private func makeCell() -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = Self.cellID
        let image = NSImageView()
        image.translatesAutoresizingMaskIntoConstraints = false
        image.symbolConfiguration = .init(pointSize: 11, weight: .regular)
        let text = NSTextField(labelWithString: "")
        text.translatesAutoresizingMaskIntoConstraints = false
        text.lineBreakMode = .byTruncatingMiddle
        text.font = .systemFont(ofSize: 12)
        cell.addSubview(image)
        cell.addSubview(text)
        cell.imageView = image
        cell.textField = text
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 16),
            text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 4),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    // MARK: - Changes on disk

    private func changed(_ node: FileNode) {
        if renaming != nil {
            if !changedWhileRenaming.contains(where: { $0 === node }) { changedWhileRenaming.append(node) }
            return
        }
        let selected = outline.item(atRow: outline.selectedRow) as? FileNode
        outline.reloadItem(node === tree.root ? nil : node, reloadChildren: true)
        if let selected {
            let row = outline.row(forItem: selected)
            if row >= 0 { outline.selectRowIndexes([row], byExtendingSelection: false) }
        }
    }

    // MARK: - Opening

    @objc private func clicked(_ sender: Any?) {
        guard let node = outline.item(atRow: outline.clickedRow) as? FileNode else { return }
        if node.isDirectory {
            if outline.isItemExpanded(node) { outline.collapseItem(node) } else { outline.expandItem(node) }
        } else {
            onOpen?(node.url)
        }
    }

    /// Expands the folders above a file and selects it (when a tab becomes active); selects
    /// nothing when the file isn't in the tree.
    func reveal(_ url: URL) {
        guard let node = tree.expand(to: url) else { return clearSelection() }
        var chain: [FileNode] = []
        var n = node.parent
        while let p = n, p !== tree.root {
            chain.append(p)
            n = p.parent
        }
        for p in chain.reversed() { outline.expandItem(p) }
        let row = outline.row(forItem: node)
        guard row >= 0 else { return clearSelection() }
        outline.selectRowIndexes([row], byExtendingSelection: false)
        outline.scrollRowToVisible(row)
    }

    func clearSelection() { outline.deselectAll(nil) }

    /// Paths (relative to the root) of expanded folders, for session restore.
    var expandedPaths: [String] {
        var out: [String] = []
        func visit(_ node: FileNode) {
            for c in node.children ?? [] where c.isDirectory && outline.isItemExpanded(c) {
                out.append(c.relativePath)
                visit(c)
            }
        }
        visit(tree.root)
        return out
    }

    func expand(paths: [String]) {
        for path in paths.sorted() {
            if let node = tree.expand(to: tree.root.url.appendingPathComponent(path)) { outline.expandItem(node) }
        }
    }

    // MARK: - Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let node = outline.item(atRow: outline.clickedRow) as? FileNode
        func add(_ title: String, _ action: Selector) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = node
        }
        add("New File…", #selector(newFile(_:)))
        add("New Folder…", #selector(newFolder(_:)))
        guard node != nil else { return }
        menu.addItem(.separator())
        add("Rename", #selector(renameClicked(_:)))
        add("Move to Trash", #selector(trashClicked(_:)))
        menu.addItem(.separator())
        add("Reveal in Finder", #selector(revealInFinder(_:)))
        add("Copy Path", #selector(copyPath(_:)))
        add("Copy Relative Path", #selector(copyRelativePath(_:)))
    }

    private func node(_ sender: Any?) -> FileNode? { (sender as? NSMenuItem)?.representedObject as? FileNode }

    /// The folder new items go in: the clicked folder, the clicked file's folder, or the root.
    private func folder(for node: FileNode?) -> URL {
        guard let node else { return tree.root.url }
        return node.isDirectory ? node.url : node.url.deletingLastPathComponent()
    }

    private func askName(_ message: String, initial: String = "", button: String) -> String? {
        let alert = NSAlert()
        alert.messageText = message
        let field = NSTextField(string: initial)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 22)
        alert.accessoryView = field
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        // Subfolders ("dir/file.txt") are fine; leaving the folder isn't.
        guard !name.isEmpty, !name.hasPrefix("/"), !name.split(separator: "/").contains("..") else { return nil }
        return name
    }

    private func refresh(_ folder: URL) {
        if let n = tree.node(for: folder) {
            tree.reload(n)
            changed(n)
        }
    }

    @objc private func newFile(_ sender: Any?) {
        let dir = folder(for: node(sender))
        guard let name = askName("New file in “\(dir.lastPathComponent)”", button: "Create") else { return }
        let url = dir.appendingPathComponent(name)
        do {
            try Self.createEmptyFile(at: url)
            refresh(dir)
            onOpen?(url)
        } catch {
            onError?(error)
        }
    }

    /// Creates an empty file (and the folders above it), failing if one is already there
    /// rather than emptying it.
    static func createEmptyFile(at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: url, options: .withoutOverwriting)
    }

    @objc private func newFolder(_ sender: Any?) {
        let dir = folder(for: node(sender))
        guard let name = askName("New folder in “\(dir.lastPathComponent)”", button: "Create") else { return }
        do {
            try FileManager.default.createDirectory(at: dir.appendingPathComponent(name), withIntermediateDirectories: true)
            refresh(dir)
        } catch {
            onError?(error)
        }
    }

    @objc private func renameClicked(_ sender: Any?) {
        if let node = node(sender) { beginRename(node) }
    }

    @objc private func trashClicked(_ sender: Any?) {
        if let node = node(sender) { trash([node.url]) }
    }

    @objc private func revealInFinder(_ sender: Any?) {
        guard let node = node(sender) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([node.url])
    }

    @objc private func copyPath(_ sender: Any?) {
        guard let node = node(sender) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(node.url.path, forType: .string)
    }

    @objc private func copyRelativePath(_ sender: Any?) {
        guard let node = node(sender) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(node.relativePath, forType: .string)
    }

    // MARK: - Renaming

    /// The item being renamed in place, and the field on its row.
    private var renaming: (node: FileNode, field: NSTextField)?
    /// Folders that changed on disk while a name was being typed: reloading them would take
    /// the field away, so they wait until the rename ends.
    private var changedWhileRenaming: [FileNode] = []

    /// Puts an edit field on the item's row with its name selected up to the extension, as
    /// Finder does. Return or clicking elsewhere renames it; Esc leaves it as it was.
    func beginRename(_ node: FileNode) {
        guard renaming == nil else { return }
        let row = outline.row(forItem: node)
        guard row >= 0 else { return }
        select(row: row)
        guard let field = (outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView)?.textField,
              let window = outline.window else { return }
        renaming = (node, field)
        field.isEditable = true
        field.drawsBackground = true
        field.backgroundColor = .textBackgroundColor
        field.textColor = .labelColor
        field.cell?.isScrollable = true
        field.delegate = self
        guard window.makeFirstResponder(field) else { return endRename(commit: false) }
        let stem = node.isDirectory ? node.name : (node.name as NSString).deletingPathExtension
        field.currentEditor()?.selectedRange = NSRange(location: 0, length: (stem as NSString).length)
    }

    /// Esc while renaming.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard control === renaming?.field, selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        endRename(commit: false)
        return true
    }

    /// Return, Tab or a click elsewhere while renaming.
    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, field === renaming?.field else { return }
        endRename(commit: true)
    }

    private func endRename(commit: Bool) {
        guard let (node, field) = renaming else { return }
        renaming = nil
        let typed = field.stringValue
        if field.currentEditor() != nil { field.abortEditing() }
        field.delegate = nil
        field.isEditable = false
        field.isSelectable = false
        field.drawsBackground = false
        field.cell?.isScrollable = false
        field.lineBreakMode = .byTruncatingMiddle
        field.stringValue = node.name
        field.textColor = node.isIgnored ? .tertiaryLabelColor : .labelColor
        // Return and Esc leave the keyboard in the tree; a click elsewhere has taken it.
        if let window = outline.window {
            let responder = window.firstResponder
            if responder == nil || responder === window || responder === field || (responder as? NSText)?.delegate === field {
                window.makeFirstResponder(outline)
            }
        }
        if commit { rename(node, to: typed) }
        let waiting = changedWhileRenaming
        changedWhileRenaming = []
        for folder in waiting { changed(folder) }
    }

    private func rename(_ node: FileNode, to typed: String) {
        let name = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != node.name else { return }
        guard !name.contains("/"), name != ".", name != ".." else { onError?(FileTreeError.invalidName(name)); return }
        let target = node.url.deletingLastPathComponent().appendingPathComponent(name)
        // A change of case alone is the same item on a case-insensitive disk.
        if FileManager.default.fileExists(atPath: target.path), !Self.isSameItem(target, node.url) {
            onError?(FileTreeError.nameTaken(name))
            return
        }
        if let done = move([Move(from: node.url, to: target)], actionName: "Rename").first { reveal(done.to) }
    }

    private static func isSameItem(_ a: URL, _ b: URL) -> Bool {
        func id(_ url: URL) -> NSObject? {
            (try? url.resourceValues(forKeys: [.fileResourceIdentifierKey]))?.fileResourceIdentifier as? NSObject
        }
        guard let ida = id(a) else { return false }
        return ida.isEqual(id(b))
    }

    // MARK: - Moving, copying and trashing

    /// An item's old and new place.
    struct Move: Equatable {
        var from: URL
        var to: URL
    }

    /// Moves each item to its new place (a rename is a move within its folder), never
    /// replacing anything, and stops at the first failure, which it reports. The folders
    /// involved are reloaded, open tabs follow (`onRename`), and Undo moves them back.
    @discardableResult
    func move(_ moves: [Move], actionName: String) -> [Move] {
        var done: [Move] = []
        for m in moves {
            do {
                try FileManager.default.moveItem(at: m.from, to: m.to)
                done.append(m)
            } catch {
                onError?(Self.explained(error, movingTo: m.to))
                break
            }
        }
        var folders: [URL] = []
        for m in done {
            for folder in [m.from.deletingLastPathComponent(), m.to.deletingLastPathComponent()] where !folders.contains(folder) {
                folders.append(folder)
                refresh(folder)
            }
            onRename?(m.from, m.to)
        }
        if !done.isEmpty {
            let back = done.reversed().map { Move(from: $0.to, to: $0.from) }
            registerUndo(actionName) { $0.move(back, actionName: actionName) }
        }
        return done
    }

    /// Copies each item into `folder` under a name not taken there: its own, else “a copy.txt”,
    /// “a copy 2.txt” (Finder's names for duplicates), so nothing is replaced. Undo moves the
    /// copies to the Trash.
    @discardableResult
    func copy(_ urls: [URL], into folder: URL) -> [URL] {
        var done: [URL] = []
        for url in urls {
            let target = Self.freeName(for: url, in: folder)
            do {
                try FileManager.default.copyItem(at: url, to: target)
                done.append(target)
            } catch {
                onError?(error)
                break
            }
        }
        if !done.isEmpty {
            refresh(folder)
            let name = Self.actionName("Copy", urls)
            registerUndo(name) { $0.trash(done, actionName: name) }
        }
        return done
    }

    /// Where a copy of `url` goes in `folder`.
    static func freeName(for url: URL, in folder: URL) -> URL {
        let fm = FileManager.default
        let name = url.lastPathComponent
        var target = folder.appendingPathComponent(name)
        guard fm.fileExists(atPath: target.path) else { return target }
        let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        let ext = isFolder ? "" : (name as NSString).pathExtension
        let stem = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        var k = 1
        repeat {
            let base = k == 1 ? "\(stem) copy" : "\(stem) copy \(k)"
            target = folder.appendingPathComponent(ext.isEmpty ? base : "\(base).\(ext)")
            k += 1
        } while fm.fileExists(atPath: target.path)
        return target
    }

    /// Moves items to the Trash; Undo puts them back.
    func trash(_ urls: [URL], actionName: String = "Move to Trash") {
        var moved: [Move] = []
        for url in urls {
            do {
                moved.append(Move(from: url, to: try trashItem(url)))
            } catch {
                onError?(error)
                break
            }
        }
        guard !moved.isEmpty else { return }
        for m in moved { refresh(m.from.deletingLastPathComponent()) }
        registerUndo(actionName) { $0.putBack(moved, actionName: actionName) }
    }

    /// Takes trashed items back to where they were; Undo trashes them again.
    private func putBack(_ moved: [Move], actionName: String) {
        var back: [URL] = []
        for m in moved {
            do {
                try FileManager.default.moveItem(at: m.to, to: m.from)
                back.append(m.from)
            } catch {
                onError?(Self.explained(error, movingTo: m.from))
                break
            }
        }
        guard !back.isEmpty else { return }
        for url in back { refresh(url.deletingLastPathComponent()) }
        registerUndo(actionName) { $0.trash(back, actionName: actionName) }
    }

    /// The error to show for a failed move to `target`: a name already taken there in Vie's
    /// words (Cocoa's message goes on about saving the file), else the error as it is.
    private static func explained(_ error: Error, movingTo target: URL) -> Error {
        guard (error as? CocoaError)?.code == .fileWriteFileExists else { return error }
        return FileTreeError.alreadyThere(target.lastPathComponent, folder: target.deletingLastPathComponent().lastPathComponent)
    }

    /// Offers Edit ▸ Undo `name` (the window's undo manager, used while the tree has the
    /// keyboard; the editor keeps its own).
    private func registerUndo(_ name: String, _ handler: @escaping @MainActor (FileTreeController) -> Void) {
        guard let undo = outline.undoManager else { return }
        undo.registerUndo(withTarget: self) { target in MainActor.assumeIsolated { handler(target) } }
        undo.setActionName(name)
    }

    /// “Move “a.txt”” or “Move 3 Items”.
    private static func actionName(_ verb: String, _ urls: [URL]) -> String {
        urls.count == 1 ? "\(verb) “\(urls[0].lastPathComponent)”" : "\(verb) \(urls.count) Items"
    }

    // MARK: - Dragging

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard renaming == nil, let node = item as? FileNode else { return nil }
        return node.url as NSURL
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?,
                     proposedChildIndex index: Int) -> NSDragOperation {
        let folder = dropFolder(at: info)
        let operation = dropOperation(Self.fileURLs(on: info.draggingPasteboard), into: folder,
                                      fromTree: info.draggingSource is FileOutlineView, allowed: info.draggingSourceOperationMask)
        if operation != [] {
            // The folder is what's highlighted, wherever in it the pointer is.
            outlineView.setDropItem(folder === tree.root ? nil : folder, dropChildIndex: NSOutlineViewDropOnItemIndex)
        }
        return operation
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        let folder = dropFolder(at: info)
        let urls = Self.fileURLs(on: info.draggingPasteboard)
        let operation = dropOperation(urls, into: folder, fromTree: info.draggingSource is FileOutlineView,
                                      allowed: info.draggingSourceOperationMask)
        guard operation != [] else { return false }
        return !drop(urls, into: folder, copying: operation == .copy).isEmpty
    }

    /// Where a drop goes, from the row under the pointer: a folder's row into that folder, a
    /// file's row into the file's folder, the space below the rows into the top folder. Not
    /// from the outline's proposal: when the folder under the pointer refuses (the item is
    /// already in it), the outline goes on to propose the gap at the row's edge, which can
    /// belong to the folder above, and the item would land there.
    private func dropFolder(at info: NSDraggingInfo) -> FileNode {
        let row = outline.row(at: outline.convert(info.draggingLocation, from: nil))
        guard row >= 0, let node = outline.item(atRow: row) as? FileNode else { return tree.root }
        return node.isDirectory ? node : (node.parent ?? tree.root)
    }

    private static func fileURLs(on pasteboard: NSPasteboard) -> [URL] {
        pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    /// What dropping `urls` into `folder` does: from one of Vie's trees a move, or a copy when
    /// ⌥ is held (`allowed` then lacks move); from elsewhere, such as Finder, a copy. Nothing
    /// for a folder into itself or a folder inside it, or a move to where the item already is.
    func dropOperation(_ urls: [URL], into folder: FileNode, fromTree: Bool, allowed: NSDragOperation) -> NSDragOperation {
        let moving = fromTree && allowed.contains(.move)
        guard !urls.isEmpty, moving || allowed.contains(.copy) else { return [] }
        let target = Self.canonicalPath(folder.url)
        for url in urls {
            let path = Self.canonicalPath(url)
            if target == path || target.hasPrefix(path + "/") { return [] }
            if moving && Self.canonicalPath(url.deletingLastPathComponent()) == target { return [] }
        }
        return moving ? .move : .copy
    }

    /// Moves or copies `urls` into `folder` and selects the first where it landed.
    @discardableResult
    func drop(_ urls: [URL], into folder: FileNode, copying: Bool) -> [URL] {
        let placed = copying
            ? copy(urls, into: folder.url)
            : move(urls.map { Move(from: $0, to: folder.url.appendingPathComponent($0.lastPathComponent)) },
                   actionName: Self.actionName("Move", urls)).map(\.to)
        if let first = placed.first { reveal(first) }
        return placed
    }

    /// The item's path with the folders above it resolved (/tmp is /private/tmp), the item
    /// itself left as it is (a link isn't its target).
    private static func canonicalPath(_ url: URL) -> String {
        let url = url.standardizedFileURL
        return url.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(url.lastPathComponent).path
    }
}

/// Why the tree refused a file operation.
enum FileTreeError: LocalizedError, Equatable {
    case nameTaken(String)
    case invalidName(String)
    /// A move (a drop, or an Undo) whose item's name is taken in the folder it goes to.
    case alreadyThere(String, folder: String)

    var errorDescription: String? {
        switch self {
        case .nameTaken(let name): "The name “\(name)” is already taken. Please choose a different name."
        case .invalidName(let name): "The name “\(name)” can’t be used. Names can’t contain “/”."
        case .alreadyThere(let name, let folder): "“\(folder)” already has an item named “\(name)”."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .alreadyThere: "Nothing was moved or replaced. Rename one of them, then try again."
        default: nil
        }
    }
}

/// The tree's outline view, which offers key presses to its controller first and drags a row
/// from anywhere in it.
final class FileOutlineView: NSOutlineView {
    var onKeyDown: ((NSEvent) -> Bool)?

    override func keyDown(with event: NSEvent) {
        if onKeyDown?(event) != true { super.keyDown(with: event) }
    }

    /// AppKit drags a row only when the press lands on its icon or name. In the rest of the row
    /// it sweeps the selection instead, and letting go clicks the row under the pointer, which
    /// opens that file or folds that folder. (No drag starts while a name is being edited: the
    /// row then has nothing to put on the pasteboard.)
    override func canDragRows(with rowIndexes: IndexSet, at mouseDownPoint: NSPoint) -> Bool {
        !rowIndexes.isEmpty
    }
}
