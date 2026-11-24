import AppKit
import Carbon.HIToolbox
import VieText
import VieWorkspace

/// The sidebar: the folder's tree in an outline view, under a top row for the folder itself
/// (open at first, and folded like any other). Folders are listed when expanded; git-ignored
/// entries are dimmed; a click or Return opens a file (one that isn't text shows in Quick
/// Look). ⌘- and ⇧-clicks select several items, which dragging, the context menu, ⌘D and ⌘⌫
/// then act on together. The context menu makes new files and folders, named in their row,
/// renames in place, duplicates and trashes; dragging moves (⌥ copies), to and from Finder
/// too. Edit ▸ Undo takes back a new item, rename, duplicate, move, copy or trash. The top
/// folder itself isn't renamed, duplicated, trashed or dragged: the window is built on it.
@MainActor
final class FileTreeController: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate, NSTextFieldDelegate {
    let tree: FileTree
    let outline = FileOutlineView()
    let view: NSView
    /// Opens a file (the window decides which tab, or shows it in Quick Look if it isn't text).
    var onOpen: ((URL) -> Void)?
    /// Shows files in Quick Look.
    var onPreview: (([URL]) -> Void)?
    /// The selection changed (Quick Look follows it).
    var onSelectionChange: (() -> Void)?
    /// Opens a file in its default app (tests replace it).
    var openInDefaultApp: (URL) -> Void = { NSWorkspace.shared.open($0) }
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
    /// Copies an item, off the main thread (tests use one of their own).
    var copier: TreeTransfer.Copier = { try FileCopy.copy($0, to: $1, progress: $2, isCancelled: $3) }
    /// Counts the bytes a transfer copies, for its progress (tests use one of their own).
    var sizer: TreeTransfer.Sizer = { FileCopy.size(of: $0, isCancelled: $1) }
    /// Whether moving an item into a folder goes to another disk, where it's a copy (in the
    /// background) rather than a rename (tests say yes to try that).
    var isOtherDisk: (URL, URL) -> Bool = { item, folder in FileTreeController.onOtherDisk(item, folder) }
    /// How long a transfer runs before the progress bar shows.
    var progressDelay: TimeInterval = 0.5
    /// Copies, and moves to another disk: the first one running, the others waiting their turn.
    var transfers: [TreeTransfer] = []
    /// Waiting for the transfers to finish (`finishTransfers`).
    var transferWaiters: [CheckedContinuation<Void, Never>] = []
    /// The progress bar at the bottom of the sidebar, shown while a transfer takes a while.
    let transferBar = TransferBar()

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
        outline.allowsMultipleSelection = true
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(clicked(_:))
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
        transferBar.onStop = { [weak self] in self?.transfers.first?.cancel() }
        outline.reloadData()
        outline.expandItem(tree.root)
    }

    // MARK: - Keys

    /// Return opens the selected files (or opens or closes folders); Esc goes back to the
    /// editor; ⌘D duplicates the selection and ⌘⌫ moves it to the Trash. In Vim mode, as in
    /// LazyVim's explorer: j and k move, l opens (a file, or a folder), h closes a folder (or
    /// the one holding the file), r renames, c duplicates, a makes a new file and A a new
    /// folder, ⌃L goes back to the editor and Space e hides the sidebar. Other keys are the
    /// outline's (arrows, ⇧ with them to select more, typing a name).
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
        if flags == .command, Int(event.keyCode) == kVK_Delete {
            trashSelection()
            return true
        }
        // ⌘D by its character, or by its key where the layout's characters aren't Latin.
        if flags == .command, chars.lowercased() == "d" || (!chars.allSatisfy(\.isASCII) && Int(event.keyCode) == kVK_ANSI_D) {
            duplicateSelection()
            return true
        }
        guard vimKeys else { return false }
        if flags == .control {
            if chars == "l" { onLeave?(); return true }
            return chars == "h" // already here
        }
        guard flags.isEmpty || (flags == .shift && chars == "A") else { return false }
        switch chars {
        case " ": spaceAt = event.timestamp
        case "e" where afterSpace: onToggleSidebar?()
        case "j": move(by: 1)
        case "k": move(by: -1)
        case "l": openSelected(toggle: false)
        case "h": closeSelected()
        case "r": if let node = selectedNode { beginRename(node) }
        case "a", "A": newItem(folder: chars == "A", in: folder(for: selectedNode))
        case "c": duplicateSelection()
        default: return false
        }
        return true
    }

    private var selectedNode: FileNode? { outline.item(atRow: outline.selectedRow) as? FileNode }

    /// The selected items, in row order.
    var selectedNodes: [FileNode] { outline.selectedRowIndexes.compactMap { outline.item(atRow: $0) as? FileNode } }

    /// What an action on `node`'s row applies to: the whole selection when the row is part of
    /// it, as in Finder, else that item alone. Not the top folder, unless `includingTop` (for
    /// revealing and copying paths).
    func targets(for node: FileNode, includingTop: Bool = false) -> [FileNode] {
        let selected = selectedNodes
        let nodes = selected.contains { $0 === node } ? selected : [node]
        return includingTop ? nodes : nodes.filter { $0 !== tree.root }
    }

    /// ⌘⌫: the selected items (not the top folder) to the Trash.
    func trashSelection() {
        let urls = Self.topmost(selectedNodes.filter { $0 !== tree.root }.map(\.url))
        if urls.isEmpty { NSSound.beep() } else { trash(urls) }
    }

    /// Items without any that are inside another one listed (they go along with it), as Finder
    /// does when a folder and something in it are both selected.
    static func topmost(_ urls: [URL]) -> [URL] {
        let paths = urls.map(canonicalPath)
        var out: [URL] = []
        var seen: Set<String> = []
        for (url, path) in zip(urls, paths) where !seen.contains(path) {
            seen.insert(path)
            if !paths.contains(where: { path.hasPrefix($0 + "/") }) { out.append(url) }
        }
        return out
    }

    private func select(row: Int) {
        guard row >= 0, row < outline.numberOfRows else { return }
        outline.selectRowIndexes([row], byExtendingSelection: false)
        outline.scrollRowToVisible(row)
    }

    private func move(by delta: Int) {
        select(row: outline.selectedRow < 0 ? 0 : min(max(outline.selectedRow + delta, 0), outline.numberOfRows - 1))
    }

    /// Opens the selected file, or opens a folder. On an open folder, Return closes it and l
    /// moves into it. With several items selected, opens each text file among them and shows
    /// the others together in Quick Look; with only folders, opens those that are closed, or
    /// (Return) closes them when they're all open.
    private func openSelected(toggle: Bool) {
        let selected = selectedNodes
        if selected.count > 1 {
            let files = selected.filter { !$0.isDirectory }.map(\.url)
            if files.isEmpty { // folders only: open the closed ones, or close them all
                let closed = selected.filter { !outline.isItemExpanded($0) }
                if !closed.isEmpty { closed.forEach { outline.expandItem($0) } }
                else if toggle { selected.forEach { outline.collapseItem($0) } }
                return
            }
            let binary = files.filter { TextFile.looksBinary(at: $0) }
            for url in files where !binary.contains(url) { onOpen?(url) }
            if !binary.isEmpty { onPreview?(binary) }
            return
        }
        guard let node = selectedNode else { return }
        guard node.isDirectory else { onOpen?(node.url); return }
        if !outline.isItemExpanded(node) { outline.expandItem(node) }
        else if toggle { outline.collapseItem(node) }
        else if !(node.children ?? []).isEmpty { select(row: outline.selectedRow + 1) }
    }

    /// Closes the selected folder, or the folder holding the selection (and selects it); for
    /// an item at the top, that's the project's row.
    private func closeSelected() {
        guard let node = selectedNode else { return }
        if node.isDirectory, outline.isItemExpanded(node) { return outline.collapseItem(node) }
        guard let parent = node.parent else { return }
        outline.collapseItem(parent)
        select(row: outline.row(forItem: parent))
    }

    // MARK: - Data source

    /// One row at the top, the folder itself, and each folder's items under it.
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? FileNode else { return 1 }
        return tree.children(of: node).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? FileNode else { return tree.root }
        return tree.children(of: node)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? FileNode)?.isDirectory ?? false
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        onSelectionChange?()
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FileNode else { return nil }
        let cell = outlineView.makeView(withIdentifier: Self.cellID, owner: self) as? NSTableCellView ?? makeCell()
        cell.textField?.stringValue = node.name
        cell.textField?.textColor = node.isIgnored ? .tertiaryLabelColor : .labelColor
        let icon = FileIcon.style(forName: node.name, isDirectory: node.isDirectory)
        cell.imageView?.image = FileIcon.image(icon)
        cell.imageView?.contentTintColor = node.isIgnored ? .tertiaryLabelColor : icon.color
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
        let selected = selectedNodes
        outline.reloadItem(node, reloadChildren: true)
        let rows = IndexSet(selected.map { outline.row(forItem: $0) }.filter { $0 >= 0 })
        if !rows.isEmpty { outline.selectRowIndexes(rows, byExtendingSelection: false) }
    }

    // MARK: - Opening

    @objc private func clicked(_ sender: Any?) {
        let event = NSApp.currentEvent
        // ⌘- and ⇧-clicks only change the selection.
        if let flags = event?.modifierFlags, !flags.intersection([.command, .shift]).isEmpty { return }
        click(row: outline.clickedRow, count: event?.clickCount ?? 1)
    }

    /// A click on a row opens its file or opens or closes its folder. The second click of a
    /// double-click (`count` 2) does nothing: the first did it, and a folder would close again.
    func click(row: Int, count: Int) {
        guard count < 2, let node = outline.item(atRow: row) as? FileNode else { return }
        if node.isDirectory {
            if outline.isItemExpanded(node) { outline.collapseItem(node) } else { outline.expandItem(node) }
        } else {
            onOpen?(node.url)
        }
    }

    /// Expands the folders above a file (the top one too, if it was folded) and selects it
    /// (when a tab becomes active); selects nothing when the file isn't in the tree.
    func reveal(_ url: URL) { select([url]) }

    /// Expands the folders above the items and selects them (those in the tree), or nothing.
    func select(_ urls: [URL]) {
        var rows = IndexSet()
        for url in urls {
            guard let node = tree.expand(to: url) else { continue }
            var chain: [FileNode] = []
            var n = node.parent
            while let p = n {
                chain.append(p)
                n = p.parent
            }
            for p in chain.reversed() { outline.expandItem(p) }
            let row = outline.row(forItem: node)
            if row >= 0 { rows.insert(row) }
        }
        guard let first = rows.first else { return clearSelection() }
        outline.selectRowIndexes(rows, byExtendingSelection: false)
        outline.scrollRowToVisible(first)
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
        fill(menu, for: outline.item(atRow: outline.clickedRow) as? FileNode)
    }

    /// The context menu for an item's row, or for the space below the rows (nil). On a
    /// selected row its actions take the whole selection (`targets(for:)`); Rename is there
    /// only for one item, and nothing renames or trashes the top folder.
    func fill(_ menu: NSMenu, for node: FileNode?) {
        menu.removeAllItems()
        func add(_ title: String, _ action: Selector) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = node
        }
        if let node, !files(for: node).isEmpty {
            add("Quick Look", #selector(quickLookClicked(_:)))
            add("Open With Default App", #selector(openWithDefaultApp(_:)))
            menu.addItem(.separator())
        }
        add("New File", #selector(newFile(_:)))
        add("New Folder", #selector(newFolder(_:)))
        guard let node else { return }
        let targets = targets(for: node)
        if !targets.isEmpty {
            menu.addItem(.separator())
            if targets.count == 1 { add("Rename", #selector(renameClicked(_:))) }
            add("Duplicate", #selector(duplicateClicked(_:)))
            add("Move to Trash", #selector(trashClicked(_:)))
        }
        menu.addItem(.separator())
        add("Reveal in Finder", #selector(revealInFinder(_:)))
        add(self.targets(for: node, includingTop: true).count == 1 ? "Copy Path" : "Copy Paths", #selector(copyPath(_:)))
        if !targets.isEmpty { add(targets.count == 1 ? "Copy Relative Path" : "Copy Relative Paths", #selector(copyRelativePath(_:))) }
    }

    private func node(_ sender: Any?) -> FileNode? { (sender as? NSMenuItem)?.representedObject as? FileNode }

    /// The folder new items go in: the clicked folder, the clicked file's folder, or the root.
    private func folder(for node: FileNode?) -> URL {
        guard let node else { return tree.root.url }
        return node.isDirectory ? node.url : node.url.deletingLastPathComponent()
    }

    private func refresh(_ folder: URL) {
        if let n = tree.node(for: folder) {
            tree.reload(n)
            changed(n)
        }
    }

    /// Reloads a folder that changed (for a transfer that finished).
    func refreshFolder(_ folder: URL) { refresh(folder) }

    @objc private func newFile(_ sender: Any?) { newItem(folder: false, in: folder(for: node(sender))) }
    @objc private func newFolder(_ sender: Any?) { newItem(folder: true, in: folder(for: node(sender))) }

    /// Creates an empty file (and the folders above it), failing if one is already there
    /// rather than emptying it.
    static func createEmptyFile(at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: url, options: .withoutOverwriting)
    }

    @objc private func renameClicked(_ sender: Any?) {
        if let node = node(sender) { beginRename(node) }
    }

    @objc private func duplicateClicked(_ sender: Any?) {
        if let node = node(sender) { duplicate(targets(for: node).map(\.url)) }
    }

    @objc private func trashClicked(_ sender: Any?) {
        guard let node = node(sender) else { return }
        let urls = Self.topmost(targets(for: node).map(\.url))
        if !urls.isEmpty { trash(urls) }
    }

    /// The files (not folders) among the menu's targets.
    private func files(for node: FileNode) -> [URL] {
        targets(for: node).filter { !$0.isDirectory }.map(\.url)
    }

    @objc private func quickLookClicked(_ sender: Any?) {
        if let node = node(sender) { onPreview?(files(for: node)) }
    }

    @objc private func openWithDefaultApp(_ sender: Any?) {
        if let node = node(sender) { files(for: node).forEach(openInDefaultApp) }
    }

    @objc private func revealInFinder(_ sender: Any?) {
        guard let node = node(sender) else { return }
        NSWorkspace.shared.activateFileViewerSelecting(targets(for: node, includingTop: true).map(\.url))
    }

    /// The pasteboard paths are copied to (tests use one of their own).
    var pathPasteboard = NSPasteboard.general

    /// Copy Path: one path per line.
    @objc private func copyPath(_ sender: Any?) {
        guard let node = node(sender) else { return }
        pathPasteboard.clearContents()
        pathPasteboard.setString(targets(for: node, includingTop: true).map(\.url.path).joined(separator: "\n"), forType: .string)
    }

    @objc private func copyRelativePath(_ sender: Any?) {
        guard let node = node(sender) else { return }
        pathPasteboard.clearContents()
        pathPasteboard.setString(targets(for: node).map(\.relativePath).joined(separator: "\n"), forType: .string)
    }

    /// Choose a menu item for tests: what the item would do for `node`'s row.
    func perform(_ title: String, on node: FileNode?) {
        let menu = NSMenu()
        fill(menu, for: node)
        guard let item = menu.items.first(where: { $0.title == title }), let action = item.action else { return }
        _ = perform(action, with: item)
    }

    // MARK: - New files and folders

    /// A new file or folder being named in its row: Return keeps the name typed, Esc removes it.
    private var creating: URL?
    /// What was selected before the new item, selected again if it's removed.
    private var selectedBeforeNew: [URL] = []

    /// Makes an empty file "untitled" (or a folder "untitled folder", or "untitled 2" when
    /// taken) in `dir` and puts the name field on its row, its whole name selected. Return
    /// names it (with folders on the way, for "docs/notes.md") and opens a new file; Esc removes
    /// it. Undo moves it to the Trash.
    func newItem(folder: Bool, in dir: URL) {
        guard renaming == nil else { return }
        let base = folder ? "untitled folder" : "untitled"
        var url = dir.appendingPathComponent(base)
        var k = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(base) \(k)")
            k += 1
        }
        do {
            if folder {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            } else {
                try Data().write(to: url, options: .withoutOverwriting)
            }
        } catch {
            onError?(error)
            return
        }
        selectedBeforeNew = selectedNodes.map(\.url)
        refresh(dir)
        reveal(url)
        guard let node = tree.node(for: url) else { return }
        creating = url
        beginRename(node, wholeName: true)
        if renaming == nil, creating != nil { // no field to name it in (no window): keep it as it is
            creating = nil
            finishNewItem(node, typed: node.name, commit: true)
        }
    }

    /// The end of naming a new item: kept under the name typed, or removed (Esc, or a name it
    /// can't have, which is reported). Removed only while it's still as Vie made it: if
    /// something was put in the folder (or the file) meanwhile, it stays, under its "untitled"
    /// name.
    private func finishNewItem(_ node: FileNode, typed: String, commit: Bool) {
        let url = node.url, dir = url.deletingLastPathComponent()
        func remove() {
            if Self.isEmpty(url) { try? FileManager.default.removeItem(at: url) }
            refresh(dir)
            if FileManager.default.fileExists(atPath: url.path) { select([url]) } else { select(selectedBeforeNew) }
        }
        guard commit else { return remove() }
        let name = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        var target = url
        if !name.isEmpty && name != node.name {
            // Subfolders ("docs/notes.md") are made on the way; leaving the folder isn't allowed.
            let parts = name.split(separator: "/", omittingEmptySubsequences: false)
            guard !name.hasPrefix("/"), !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
                onError?(FileTreeError.invalidPath(name))
                return remove()
            }
            target = dir.appendingPathComponent(name)
            // A change of case alone ("Untitled") is the same item on a case-insensitive disk.
            guard !FileManager.default.fileExists(atPath: target.path) || Self.isSameItem(target, url) else {
                onError?(FileTreeError.nameTaken(name))
                return remove()
            }
            do {
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: url, to: target)
            } catch {
                onError?(error)
                return remove()
            }
            refresh(dir)
            refresh(target.deletingLastPathComponent())
        }
        reveal(target)
        let action = node.isDirectory ? "New Folder" : "New File"
        registerUndo(action) { $0.trash([target], actionName: action) }
        if !node.isDirectory { onOpen?(target) }
    }

    // MARK: - Renaming

    /// The item being renamed in place, and the field on its row.
    private var renaming: (node: FileNode, field: NSTextField)?
    /// Folders that changed on disk while a name was being typed: reloading them would take
    /// the field away, so they wait until the rename ends.
    private var changedWhileRenaming: [FileNode] = []

    /// Puts an edit field on the item's row with its name selected up to the extension, as
    /// Finder does (all of it with `wholeName`). Return or clicking elsewhere renames it; Esc
    /// leaves it as it was.
    func beginRename(_ node: FileNode, wholeName: Bool = false) {
        guard renaming == nil, node !== tree.root else { return }
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
        // Typing goes to the key window, which may be Quick Look's panel (it passes on only
        // the keys the tree takes), so the keyboard comes here.
        if !window.isKeyWindow { window.makeKey() }
        let stem = node.isDirectory || wholeName ? node.name : (node.name as NSString).deletingPathExtension
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
        if let created = creating, created.standardizedFileURL.path == node.url.standardizedFileURL.path {
            creating = nil
            finishNewItem(node, typed: typed, commit: commit)
        } else if commit {
            rename(node, to: typed)
        }
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

    /// An empty file, or a folder with nothing in it (not even hidden files).
    private static func isEmpty(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        if values?.isDirectory == true {
            return (try? FileManager.default.contentsOfDirectory(atPath: url.path))?.isEmpty ?? false
        }
        return values?.fileSize == 0
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
    /// involved are reloaded, open tabs follow (`onRename`), and Undo moves them back. Moves to
    /// another disk are copies, so they go in the background (`enqueue`), with tabs following and
    /// Undo when they're done; this returns the others, done at once.
    @discardableResult
    func move(_ moves: [Move], actionName: String) -> [Move] {
        let far = moves.filter { isOtherDisk($0.from, $0.to.deletingLastPathComponent()) }
        if !far.isEmpty { enqueue(TreeTransfer(kind: .move, items: far.map { ($0.from, $0.to) }, actionName: actionName)) }
        var done: [Move] = []
        for m in moves where !far.contains(m) {
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
    /// “a copy 2.txt” (Finder's names for duplicates), so nothing is replaced. It runs in the
    /// background (`enqueue`); the copies are selected when done, and Undo moves them to the Trash.
    func copy(_ urls: [URL], into folder: URL) {
        enqueue(TreeTransfer(kind: .copy, items: urls.map { ($0, folder) }, actionName: Self.actionName("Copy", urls)))
    }

    /// ⌘D (and c in Vim mode): the selected items (not the top folder) duplicated.
    func duplicateSelection() {
        let urls = selectedNodes.filter { $0 !== tree.root }.map(\.url)
        if urls.isEmpty { NSSound.beep() } else { duplicate(urls) }
    }

    /// Duplicate: a copy of each item next to it, under Finder's name for it (“a copy.txt”),
    /// made in the background (`enqueue`) and selected when done. A single copy gets the name
    /// field, its name selected up to the extension: Return renames it, Esc keeps the name.
    /// Undo moves the copies to the Trash.
    func duplicate(_ urls: [URL]) {
        let items = urls.map { ($0, $0.deletingLastPathComponent()) }
        enqueue(TreeTransfer(kind: .duplicate, items: items, actionName: Self.actionName("Duplicate", urls)))
    }

    /// Where a copy of `url` goes in `folder`.
    nonisolated static func freeName(for url: URL, in folder: URL) -> URL {
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
    func registerUndo(_ name: String, _ handler: @escaping @MainActor (FileTreeController) -> Void) {
        guard let undo = outline.undoManager else { return }
        // A transfer finishing later, outside any event, gets a group of its own even when
        // groups aren't made by event (as in tests).
        let ownGroup = !undo.groupsByEvent && undo.groupingLevel == 0
        if ownGroup { undo.beginUndoGrouping() }
        undo.registerUndo(withTarget: self) { target in MainActor.assumeIsolated { handler(target) } }
        undo.setActionName(name)
        if ownGroup { undo.endUndoGrouping() }
    }

    /// “Move “a.txt”” or “Move 3 Items”.
    static func actionName(_ verb: String, _ urls: [URL]) -> String {
        urls.count == 1 ? "\(verb) “\(urls[0].lastPathComponent)”" : "\(verb) \(urls.count) Items"
    }

    // MARK: - Dragging

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        // Not the top folder: a drag that starts anywhere on its row would copy the whole
        // project wherever it's let go.
        guard renaming == nil, let node = item as? FileNode, node !== tree.root else { return nil }
        return node.url as NSURL
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?,
                     proposedChildIndex index: Int) -> NSDragOperation {
        let folder = dropFolder(at: info)
        let operation = dropOperation(Self.topmost(Self.fileURLs(on: info.draggingPasteboard)), into: folder,
                                      fromTree: info.draggingSource is FileOutlineView, allowed: info.draggingSourceOperationMask)
        if operation != [] {
            // The folder is what's highlighted, wherever in it the pointer is.
            outlineView.setDropItem(folder, dropChildIndex: NSOutlineViewDropOnItemIndex)
        }
        return operation
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        let folder = dropFolder(at: info)
        let urls = Self.topmost(Self.fileURLs(on: info.draggingPasteboard))
        let operation = dropOperation(urls, into: folder, fromTree: info.draggingSource is FileOutlineView,
                                      allowed: info.draggingSourceOperationMask)
        guard operation != [] else { return false }
        return drop(urls, into: folder, copying: operation == .copy)
    }

    /// Where a drop goes, from the row under the pointer: a folder's row (the top one's too)
    /// into that folder, a file's row into the file's folder, the space below the rows into
    /// the top folder. Not from the outline's proposal: when the folder under the pointer
    /// refuses (the item is already in it), the outline goes on to propose the gap at the
    /// row's edge, which can belong to the folder above, and the item would land there.
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

    /// Moves or copies `urls` into `folder` (not items inside others among them, which go along)
    /// and selects them where they landed: at once for a move on the same disk, when it's done
    /// for a copy or a move to another disk. False when nothing was moved or started.
    @discardableResult
    func drop(_ urls: [URL], into folder: FileNode, copying: Bool) -> Bool {
        let urls = Self.topmost(urls)
        guard !urls.isEmpty else { return false }
        let waiting = transfers.count
        if copying {
            copy(urls, into: folder.url)
        } else {
            let placed = move(urls.map { Move(from: $0, to: folder.url.appendingPathComponent($0.lastPathComponent)) },
                              actionName: Self.actionName("Move", urls)).map(\.to)
            if !placed.isEmpty {
                select(placed)
                return true
            }
        }
        return transfers.count > waiting
    }

    private static func canonicalPath(_ url: URL) -> String { FileTree.canonicalPath(url) }
}

/// Why the tree refused a file operation.
enum FileTreeError: LocalizedError, Equatable {
    case nameTaken(String)
    case invalidName(String)
    /// A new item's name, which may hold folders ("docs/notes.md") but not empty, "." or ".."
    /// ones, and can't start with "/".
    case invalidPath(String)
    /// A move (a drop, or an Undo) whose item's name is taken in the folder it goes to.
    case alreadyThere(String, folder: String)
    /// Something in an item changed while it was being copied to another disk to move it there,
    /// so the original was kept and the copy removed.
    case changedWhileMoving(String)

    var errorDescription: String? {
        switch self {
        case .nameTaken(let name): "The name “\(name)” is already taken. Please choose a different name."
        case .invalidName(let name): "The name “\(name)” can’t be used. Names can’t contain “/”."
        case .invalidPath(let name):
            "The name “\(name)” can’t be used. It can name folders to make on the way, like “docs/notes.md”, but can’t start with “/” or have an empty, “.” or “..” folder."
        case .alreadyThere(let name, let folder): "“\(folder)” already has an item named “\(name)”."
        case .changedWhileMoving(let name): "“\(name)” changed while it was being moved to another disk."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .alreadyThere: "Nothing was moved or replaced. Rename one of them, then try again."
        case .changedWhileMoving: "It was left where it was, as it is now. Try moving it again."
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
    /// opens that file or folds that folder. (No drag starts from the top folder's row or while
    /// a name is being edited: the row then has nothing to put on the pasteboard.)
    override func canDragRows(with rowIndexes: IndexSet, at mouseDownPoint: NSPoint) -> Bool {
        !rowIndexes.isEmpty
    }
}
