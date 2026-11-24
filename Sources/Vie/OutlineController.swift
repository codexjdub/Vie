import AppKit
import Carbon.HIToolbox
import VieEditor
import VieSyntax

/// The sidebar's Outline, under the file tree: the current Markdown file's headings, nested by
/// level, kept current as parses land. The heading the cursor is under is selected as it
/// moves. A click on a heading, or Return, jumps to it and gives the keyboard back to the text;
/// Esc goes back to the text too, and in Vim mode j and k move. Headings folded stay folded
/// while the file changes, and when its tab is shown again.
@MainActor
final class OutlineController: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    /// The section: a header over the headings, in the sidebar's material.
    let view = NSVisualEffectView()
    let outline = FileOutlineView()
    private let header = NSTextField(labelWithString: "Outline")
    private let empty = NSTextField(labelWithString: "No headings")
    private let scroll = NSScrollView()
    static let headerHeight: CGFloat = 24

    /// Vim mode is on: j and k move.
    var vimKeys = false
    /// A heading was chosen (or Esc pressed): the keyboard goes back to the text.
    var onLeave: (() -> Void)?
    /// The current file has an outline or stopped having one (it's Markdown, or it isn't):
    /// the window shows or hides the section.
    var onAvailabilityChange: (() -> Void)?
    /// The current file is Markdown (it may have no headings yet).
    private(set) var isAvailable = false

    /// The editor whose headings are shown: the window's current tab.
    weak var editor: EditorView? {
        didSet { if editor !== oldValue { editorChanged(from: oldValue) } }
    }

    final class Node {
        var heading: MarkdownHeading
        var children: [Node] = []
        weak var parent: Node?
        init(_ heading: MarkdownHeading) { self.heading = heading }
    }

    private var roots: [Node] = []
    /// Every node in document order, for finding the heading the cursor is under.
    private(set) var nodes: [Node] = []
    /// The headings folded, as paths of titles, so they stay folded when the outline is rebuilt.
    private var folded: Set<String> = []
    /// Each editor's folded headings while another is shown, so a tab's folds come back with it.
    private let foldedByEditor = NSMapTable<EditorView, NSSet>.weakToStrongObjects()
    private var rebuilding = false
    private var current: Node?

    override init() {
        super.init()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState

        header.font = .systemFont(ofSize: 11, weight: .semibold)
        header.textColor = .secondaryLabelColor
        empty.font = .systemFont(ofSize: 11)
        empty.textColor = .tertiaryLabelColor
        empty.alignment = .center

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("title"))
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
        outline.onKeyDown = { [weak self] event in self?.key(event) ?? false }
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        for v in [header, scroll, empty] as [NSView] { view.addSubview(v) }
        layoutSection()
        NotificationCenter.default.addObserver(self, selector: #selector(sectionResized), name: NSView.frameDidChangeNotification, object: view)
        view.postsFrameChangedNotifications = true
    }

    @objc private func sectionResized(_ note: Notification) { layoutSection() }

    private func layoutSection() {
        let b = view.bounds, h = Self.headerHeight
        header.frame = NSRect(x: 10, y: b.height - h + (h - 14) / 2, width: max(0, b.width - 20), height: 14)
        scroll.frame = NSRect(x: 0, y: 0, width: b.width, height: max(0, b.height - h))
        empty.frame = NSRect(x: 0, y: max(0, b.height - h - 30), width: b.width, height: 16)
    }

    // MARK: - Following the editor

    private func editorChanged(from old: EditorView?) {
        old?.onSyntaxChange = nil
        old?.onStateChange = nil
        if let old { foldedByEditor.setObject(folded as NSSet, forKey: old) }
        folded = editor.flatMap { foldedByEditor.object(forKey: $0) as? Set<String> } ?? []
        editor?.onSyntaxChange = { [weak self] in self?.refresh() }
        editor?.onStateChange = { [weak self] in self?.followCursor() }
        refresh()
    }

    /// Reads the headings again: rebuilds the list when they changed, or only moves their
    /// places along when just the text around them did.
    func refresh() {
        let available = editor?.syntaxLanguage?.name == "markdown"
        let headings = available ? editor?.markdownHeadings ?? [] : []
        if headings.count == nodes.count, zip(headings, nodes).allSatisfy({ $0.level == $1.heading.level && $0.title == $1.heading.title }) {
            for (h, n) in zip(headings, nodes) { n.heading = h }
        } else {
            rebuild(headings)
        }
        empty.isHidden = !nodes.isEmpty
        if available != isAvailable {
            isAvailable = available
            onAvailabilityChange?()
        }
        current = nil
        followCursor()
    }

    private func rebuild(_ headings: [MarkdownHeading]) {
        roots = []
        nodes = []
        var stack: [Node] = []
        for h in headings {
            let node = Node(h)
            while let last = stack.last, last.heading.level >= h.level { stack.removeLast() }
            if let parent = stack.last {
                parent.children.append(node)
                node.parent = parent
            } else {
                roots.append(node)
            }
            stack.append(node)
            nodes.append(node)
        }
        rebuilding = true
        outline.reloadData()
        for node in nodes where !node.children.isEmpty && !folded.contains(path(node)) {
            if node.parent.map({ outline.isItemExpanded($0) }) ?? true { outline.expandItem(node) }
        }
        rebuilding = false
    }

    /// The heading's titles from the top, to remember it folded across rebuilds.
    private func path(_ node: Node) -> String {
        var parts: [String] = []
        var n: Node? = node
        while let x = n {
            parts.append("\(x.heading.level) \(x.heading.title)")
            n = x.parent
        }
        return parts.reversed().joined(separator: "\u{1F}")
    }

    /// Selects the heading the cursor is under (the last one starting at or before it), or the
    /// nearest one shown if it's folded away; nothing above the first heading.
    func followCursor() {
        guard let editor, !nodes.isEmpty else {
            if outline.selectedRow >= 0 { outline.deselectAll(nil) }
            return
        }
        let cursor = editor.cursorOffset
        var lo = 0, hi = nodes.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if nodes[mid].heading.offset <= cursor { lo = mid + 1 } else { hi = mid }
        }
        let node = lo > 0 ? nodes[lo - 1] : nil
        guard node !== current || (node == nil && outline.selectedRow >= 0) else { return }
        current = node
        var shown = node
        while let n = shown, outline.row(forItem: n) < 0 { shown = n.parent }
        guard let shown else { return outline.deselectAll(nil) }
        let row = outline.row(forItem: shown)
        outline.selectRowIndexes([row], byExtendingSelection: false)
        outline.scrollRowToVisible(row)
    }

    /// The heading the cursor is under, for tests.
    var currentTitle: String? { current?.heading.title }

    // MARK: - Choosing

    @objc private func clicked(_ sender: Any?) {
        guard let node = outline.item(atRow: outline.clickedRow) as? Node else { return }
        jump(to: node)
    }

    func jump(to node: Node) {
        editor?.jump(to: node.heading.offset)
        onLeave?()
    }

    /// Return jumps to the selected heading, Esc goes back to the text; in Vim mode j and k
    /// move, and ⌃L goes back too.
    private func key(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if flags.isEmpty {
            switch Int(event.keyCode) {
            case kVK_Return, kVK_ANSI_KeypadEnter:
                if let node = outline.item(atRow: outline.selectedRow) as? Node { jump(to: node) }
                return true
            case kVK_Escape:
                onLeave?()
                return true
            default: break
            }
        }
        guard vimKeys else { return false }
        let chars = event.charactersIgnoringModifiers ?? ""
        if flags == .control, chars == "l" {
            onLeave?()
            return true
        }
        guard flags.isEmpty, chars == "j" || chars == "k" else { return false }
        let row = min(max(outline.selectedRow + (chars == "j" ? 1 : -1), 0), outline.numberOfRows - 1)
        if row >= 0 {
            outline.selectRowIndexes([row], byExtendingSelection: false)
            outline.scrollRowToVisible(row)
        }
        return true
    }

    // MARK: - Data source and delegate

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? Node)?.children.count ?? roots.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? Node)?.children[index] ?? roots[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !((item as? Node)?.children.isEmpty ?? true)
    }

    private static let cellID = NSUserInterfaceItemIdentifier("heading")

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? Node else { return nil }
        let cell = outlineView.makeView(withIdentifier: Self.cellID, owner: self) as? NSTableCellView ?? {
            let cell = NSTableCellView()
            cell.identifier = Self.cellID
            let text = NSTextField(labelWithString: "")
            text.translatesAutoresizingMaskIntoConstraints = false
            text.lineBreakMode = .byTruncatingTail
            text.font = .systemFont(ofSize: 12)
            cell.addSubview(text)
            cell.textField = text
            NSLayoutConstraint.activate([
                text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }()
        cell.textField?.stringValue = node.heading.title.isEmpty ? "(no title)" : node.heading.title
        cell.textField?.textColor = node.heading.title.isEmpty ? .tertiaryLabelColor : .labelColor
        return cell
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard !rebuilding, let node = notification.userInfo?["NSObject"] as? Node else { return }
        folded.insert(path(node))
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard !rebuilding, let node = notification.userInfo?["NSObject"] as? Node else { return }
        folded.remove(path(node))
    }
}
