import AppKit
import VieWorkspace

/// ⌘P: a search field over the folder's files, fuzzy-matched on every keystroke. Up and down
/// move through the results, Return opens, Esc closes. With an empty query it lists the open
/// files, most recent first.
@MainActor
final class QuickOpenController: NSObject, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    let view: NSVisualEffectView
    private let field = NSTextField()
    private let table = NSTableView()
    private let scroll = NSScrollView()

    /// The folder's files; nil while indexing (then only open files are offered).
    var index: FuzzyIndex? {
        didSet { if view.superview != nil { update() } }
    }
    /// Open files (relative paths, or absolute for files outside the folder), most recent first.
    var recent: [String] = []
    var onOpen: ((String) -> Void)?
    var onDismiss: (() -> Void)?

    private var results: FuzzyIndex.Results?
    private var rows: [(path: String, positions: [Int])] = []
    private static let rowHeight: CGFloat = 24
    private static let maxRows = 12

    override init() {
        view = NSVisualEffectView()
        super.init()
        view.material = .popover
        view.blendingMode = .withinWindow
        view.state = .active
        view.wantsLayer = true
        view.layer?.cornerRadius = 10
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
        // Nearly opaque, so the editor text doesn't show through; in the window's appearance.
        container.effectiveAppearance.performAsCurrentDrawingAppearance {
            view.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.97).cgColor
        }
        if view.superview !== container {
            view.removeFromSuperview()
            container.addSubview(view, positioned: .above, relativeTo: nil)
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
        if query.isEmpty {
            results = nil
            rows = recent.prefix(100).map { ($0, []) }
        } else if let index {
            let r = index.search(query, limit: 100, previous: results)
            results = r
            rows = r.top.map { m in (index.path(m.index), index.positions(of: m.index, query: query)) }
        } else {
            rows = recent.filter { $0.localizedCaseInsensitiveContains(query) }.map { ($0, []) }
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

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("row")
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? {
            let c = NSTableCellView()
            c.identifier = id
            let t = NSTextField(labelWithString: "")
            t.lineBreakMode = .byTruncatingMiddle
            t.translatesAutoresizingMaskIntoConstraints = false
            c.addSubview(t)
            c.textField = t
            NSLayoutConstraint.activate([
                t.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 10),
                t.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -10),
                t.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])
            return c
        }()
        guard rows.indices.contains(row) else {
            cell.textField?.attributedStringValue = NSAttributedString(string: "Indexing files…", attributes: [.foregroundColor: NSColor.secondaryLabelColor])
            return cell
        }
        cell.textField?.attributedStringValue = Self.label(rows[row].path, rows[row].positions)
        return cell
    }

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
