import AppKit
import Carbon.HIToolbox
import VieWorkspace

/// The sidebar: the folder's tree in an outline view. Folders are listed when expanded; git-
/// ignored entries are dimmed; a click or Return opens a file. The context menu creates,
/// renames and trashes files.
@MainActor
final class FileTreeController: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
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
    /// Asks the window to run a file operation (it shows any error).
    var onError: ((Error) -> Void)?

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
    /// folder), h closes a folder (or the one holding the file), ⌃L goes back to the editor
    /// and Space e hides the sidebar. Other keys are the outline's (arrows, typing a name).
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
        add("Rename…", #selector(rename(_:)))
        add("Move to Trash", #selector(trash(_:)))
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
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard FileManager.default.createFile(atPath: url.path, contents: Data(), attributes: nil) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
            }
            refresh(dir)
            onOpen?(url)
        } catch {
            onError?(error)
        }
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

    @objc private func rename(_ sender: Any?) {
        guard let node = node(sender), let name = askName("Rename “\(node.name)”", initial: node.name, button: "Rename"),
              name != node.name else { return }
        let target = node.url.deletingLastPathComponent().appendingPathComponent(name)
        do {
            try FileManager.default.moveItem(at: node.url, to: target)
            refresh(node.url.deletingLastPathComponent())
            onRename?(node.url, target)
        } catch {
            onError?(error)
        }
    }

    /// A file or folder was renamed (open tabs should follow).
    var onRename: ((URL, URL) -> Void)?

    @objc private func trash(_ sender: Any?) {
        guard let node = node(sender) else { return }
        do {
            try FileManager.default.trashItem(at: node.url, resultingItemURL: nil)
            refresh(node.url.deletingLastPathComponent())
        } catch {
            onError?(error)
        }
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
}

/// The tree's outline view, which offers key presses to its controller first.
final class FileOutlineView: NSOutlineView {
    var onKeyDown: ((NSEvent) -> Bool)?

    override func keyDown(with event: NSEvent) {
        if onKeyDown?(event) != true { super.keyDown(with: event) }
    }
}
