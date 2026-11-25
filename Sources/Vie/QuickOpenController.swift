import AppKit
import VieEditor
import VieWorkspace

/// ⌘P: a search field over the folder's files, fuzzy-matched on every keystroke. Up and down
/// move through the results, Return opens, Esc closes. With an empty query it lists the open
/// files, most recent first, then the files whose tabs were closed.
@MainActor
final class QuickOpenController: NSObject, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    let view = NSView()
    private let field = NSTextField()
    private let table = NSTableView()
    private let scroll = NSScrollView()

    /// The folder's files; nil while indexing (then only open files are offered).
    var index: FuzzyIndex? {
        didSet {
            // The last results point into the old index, so the next search can't narrow them.
            results = nil
            if view.superview != nil { update() }
        }
    }
    /// Open files (relative paths, or absolute for files outside the folder), most recent first.
    var recent: [String] = []
    /// Files whose tabs were closed, as `recent`, most recently closed first.
    var closed: [String] = []
    var onOpen: ((String) -> Void)?
    var onDismiss: (() -> Void)?

    private var results: FuzzyIndex.Results?
    private var rows: [Row] = []
    private struct Row {
        var path: String
        var positions: [Int] = []
        var closed = false
    }
    private static let rowHeight: CGFloat = 24
    private static let maxRows = 12

    override init() {
        super.init()
        view.wantsLayer = true
        view.layer?.cornerRadius = FloatingPanel.cornerRadius
        view.layer?.borderWidth = 1
        view.layer?.borderColor = NSColor.separatorColor.cgColor

        field.placeholderString = "Open file…"
        field.font = .systemFont(ofSize: 15)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = self
        field.cell?.isScrollable = true
        field.cell?.usesSingleLineMode = true

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("path"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = Self.rowHeight
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.style = .plain
        table.refusesFirstResponder = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked(_:))
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        view.addSubview(field)
        view.addSubview(scroll)
    }

    /// Space to leave above the panel (the tab bar).
    var topInset: CGFloat = 0

    /// Shows the panel at the top of `container` and focuses the field.
    func show(in container: NSView) {
        // In the theme's tint (FloatingPanel), opaque so the text doesn't show through.
        let appearance = container.effectiveAppearance
        view.layer?.backgroundColor = FloatingPanel.background(appearance).cgColor
        view.layer?.borderColor = FloatingPanel.border(appearance).cgColor
        if view.superview !== container {
            view.removeFromSuperview()
            container.addSubview(view, positioned: .above, relativeTo: nil)
            view.fadeIn()
        }
        field.stringValue = ""
        results = nil
        update()
        container.window?.makeFirstResponder(field)
    }

    func dismiss() {
        guard view.superview != nil else { return }
        view.removeFromSuperview()
        onDismiss?()
    }

    var isShown: Bool { view.superview != nil }

    private func layout() {
        guard let container = view.superview else { return }
        let width = min(640, container.bounds.width - 40)
        let visibleRows = CGFloat(min(max(rows.count, 1), Self.maxRows))
        let height = 44 + visibleRows * Self.rowHeight + 8
        let top = topInset + 8
        let y = container.isFlipped ? top : container.bounds.height - top - height
        view.frame = NSRect(x: (container.bounds.width - width) / 2, y: y, width: width, height: height)
        view.autoresizingMask = container.isFlipped ? [.minXMargin, .maxXMargin, .maxYMargin] : [.minXMargin, .maxXMargin, .minYMargin]
        field.frame = NSRect(x: 14, y: height - 38, width: width - 28, height: 26)
        scroll.frame = NSRect(x: 4, y: 6, width: width - 8, height: visibleRows * Self.rowHeight)
        table.tableColumns.first?.width = scroll.contentSize.width
    }

    // MARK: - Searching

    private func update() {
        let query = field.stringValue.trimmingCharacters(in: .whitespaces)
        let listed = recent.map { Row(path: $0) } + closed.map { Row(path: $0, closed: true) }
        if query.isEmpty {
            results = nil
            rows = Array(listed.prefix(100))
        } else if let index {
            let r = index.search(query, limit: 100, previous: results)
            results = r
            rows = r.top.map { m in Row(path: index.path(m.index), positions: index.positions(of: m.index, query: query)) }
        } else {
            rows = listed.filter { $0.path.localizedCaseInsensitiveContains(query) }
        }
        table.reloadData()
        if !rows.isEmpty {
            table.selectRowIndexes([0], byExtendingSelection: false)
            table.scrollRowToVisible(0)
        }
        layout()
    }

    func controlTextDidChange(_ obj: Notification) { update() }

    func type(_ text: String) {
        field.stringValue += text
        update()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)): move(1)
        case #selector(NSResponder.moveUp(_:)): move(-1)
        case #selector(NSResponder.insertNewline(_:)): openSelected()
        case #selector(NSResponder.cancelOperation(_:)): dismiss()
        default: return false
        }
        return true
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        // Clicking elsewhere closes the panel (the table never takes focus).
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isShown, self.view.window?.firstResponder !== self.field.currentEditor() else { return }
            self.dismiss()
        }
    }

    private func move(_ delta: Int) {
        guard !rows.isEmpty else { return }
        let row = min(max(table.selectedRow + delta, 0), rows.count - 1)
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    private func openSelected() {
        let row = table.selectedRow
        guard rows.indices.contains(row) else { return NSSound.beep() }
        let path = rows[row].path
        dismiss()
        onOpen?(path)
    }

    @objc private func clicked(_ sender: Any?) {
        guard table.clickedRow >= 0 else { return }
        table.selectRowIndexes([table.clickedRow], byExtendingSelection: false)
        openSelected()
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.isEmpty && index == nil && !field.stringValue.isEmpty ? 1 : rows.count
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        PanelRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("row")
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? QuickOpenCell ?? {
            let c = QuickOpenCell()
            c.identifier = id
            return c
        }()
        guard rows.indices.contains(row) else {
            cell.textField?.attributedStringValue = NSAttributedString(string: "Indexing files…", attributes: [.foregroundColor: NSColor.secondaryLabelColor])
            cell.closedLabel.stringValue = ""
            cell.imageView?.image = nil
            return cell
        }
        let icon = FileIcon.style(forName: (rows[row].path as NSString).lastPathComponent, isDirectory: false)
        cell.imageView?.image = FileIcon.image(icon)
        cell.imageView?.contentTintColor = icon.color
        cell.textField?.attributedStringValue = Self.label(rows[row].path, rows[row].positions)
        cell.closedLabel.stringValue = rows[row].closed ? "closed" : ""
        return cell
    }

    /// What the rows show, for tests: each path, with "(closed)" after a closed file's.
    var shownRows: [String] { rows.map { $0.closed ? "\($0.path) (closed)" : $0.path } }

    /// File name first (matched characters in bold), then its folder, dimmed.
    static func label(_ path: String, _ positions: [Int]) -> NSAttributedString {
        let bytes = Array(path.utf8)
        let slash = bytes.lastIndex(of: 0x2F)
        let nameStart = slash.map { $0 + 1 } ?? 0
        let matched = Set(positions)
        let out = NSMutableAttributedString()
        let regular: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor]
        let bold: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 13), .foregroundColor: NSColor.controlAccentColor]
        let dim: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
        let dimBold: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 11), .foregroundColor: NSColor.controlAccentColor]
        func append(_ range: Range<Int>, _ normal: [NSAttributedString.Key: Any], _ hit: [NSAttributedString.Key: Any]) {
            var i = range.lowerBound
            while i < range.upperBound {
                let on = matched.contains(i)
                var j = i + 1
                while j < range.upperBound && matched.contains(j) == on { j += 1 }
                out.append(NSAttributedString(string: String(decoding: bytes[i..<j], as: UTF8.self), attributes: on ? hit : normal))
                i = j
            }
        }
        append(nameStart..<bytes.count, regular, bold)
        if nameStart > 0 {
            out.append(NSAttributedString(string: "   ", attributes: dim))
            append(0..<(nameStart - 1), dim, dimBold)
        }
        return out
    }
}

/// A ⌘P row: the file's icon, name and folder, and at the right a dim "closed" for a file
/// whose tab was closed.
private final class QuickOpenCell: NSTableCellView {
    let closedLabel = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.symbolConfiguration = .init(pointSize: 12, weight: .regular)
        addSubview(icon)
        imageView = icon
        let t = NSTextField(labelWithString: "")
        t.lineBreakMode = .byTruncatingMiddle
        t.translatesAutoresizingMaskIntoConstraints = false
        t.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        closedLabel.font = .systemFont(ofSize: 11)
        closedLabel.textColor = .tertiaryLabelColor
        closedLabel.translatesAutoresizingMaskIntoConstraints = false
        closedLabel.setContentHuggingPriority(.required, for: .horizontal)
        closedLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(t)
        addSubview(closedLabel)
        textField = t
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            t.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5),
            t.trailingAnchor.constraint(lessThanOrEqualTo: closedLabel.leadingAnchor, constant: -8),
            t.centerYAnchor.constraint(equalTo: centerYAnchor),
            closedLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            closedLabel.firstBaselineAnchor.constraint(equalTo: t.firstBaselineAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

/// A ⌘P row whose selection is a wash of the theme's accent, like the panel's tint.
private final class PanelRowView: NSTableRowView {
    override var isEmphasized: Bool {
        get { false } // keeps the row's text in its own colors
        set {}
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        FloatingPanel.selection(effectiveAppearance).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 1), xRadius: 5, yRadius: 5).fill()
    }
}
