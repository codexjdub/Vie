import AppKit
import VieText

/// The Find bar above the text: ⌘F shows it, ⌥⌘F with its Replace row. It finds as you type,
/// highlights the matches, says which one is current ("2 of 5"), and replaces one match or all
/// of them (one undo step each). A window has one; it searches the window's current editor.
///
/// The search text is shared with other apps through the system's find pasteboard, as in
/// TextEdit and Safari. In Vim mode a plain-text search is handed to Vim when the bar closes,
/// so `n` and `N` go on with it.
@MainActor
public final class FindBar: NSView, NSSearchFieldDelegate {
    public static let rowHeight: CGFloat = 28
    /// The pasteboard new bars share their search text through (tests use one of their own).
    public static var defaultPasteboard = NSPasteboard(name: .find)
    /// At most this many matches are counted ("1 of 100,000+").
    static let countLimit = 100_000
    /// Texts up to this size are counted at once as the search changes; larger ones in the
    /// background (and every text after an edit, a moment later).
    static let quickCountLimit = 128 * 1024

    /// Its height: one row, or two with Replace.
    public var height: CGFloat { replacing ? 2 * Self.rowHeight : Self.rowHeight }
    public private(set) var replacing = false
    public private(set) var isShown = false
    /// Esc or Done: the window hides the bar and gives the keyboard back to the editor.
    public var onClose: (() -> Void)?
    /// The bar was shown or hidden, or its height changed: the window lays it out again.
    public var onResize: (() -> Void)?
    public var findPasteboard = FindBar.defaultPasteboard

    /// The editor it searches: the window's current tab.
    public weak var editor: EditorView? {
        didSet { if editor !== oldValue { editorChanged(from: oldValue) } }
    }

    let findField = NSSearchField()
    let replaceField = NSTextField()
    let countLabel = NSTextField(labelWithString: "")
    private let navigation = NSSegmentedControl()
    let caseButton = NSButton()
    let wordButton = NSButton()
    let regexButton = NSButton()
    private let doneButton = NSButton()
    private let replaceButton = NSButton()
    private let replaceAllButton = NSButton()

    /// The search compiled from `searchQuery` (nil: nothing to find, or an invalid expression).
    private var search: RopeRegex?
    private var searchQuery = FindQuery()
    /// Where finding as you type starts: the cursor when the bar opened, or the last match.
    private var origin = 0
    /// The match last shown and the selection that showed it. It's still the current match
    /// while the editor keeps that selection and the text doesn't change.
    private var shown: (range: Range<Int>, selection: Selection)?
    /// The start of every match in the text (up to `countLimit`), once counted.
    private var starts: [Int] = []
    private var counted = false
    private var counting: Task<Void, Never>?
    private var countGeneration = 0
    /// The find pasteboard's change count when the bar last read or wrote it.
    private var pasteboardChangeCount = -1
    /// What the count label says instead of the count, until the search or text changes.
    private var note: String?

    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        isHidden = true

        findField.placeholderString = "Find"
        findField.controlSize = .small
        findField.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
        findField.sendsWholeSearchString = true // its action is for the clear button; typing reaches controlTextDidChange
        findField.target = self
        findField.action = #selector(findFieldAction(_:))
        findField.delegate = self
        findField.cell?.isScrollable = true
        replaceField.placeholderString = "Replace"
        replaceField.controlSize = .small
        replaceField.font = findField.font
        replaceField.delegate = self
        replaceField.cell?.isScrollable = true
        replaceField.lineBreakMode = .byClipping
        findField.nextKeyView = replaceField
        replaceField.nextKeyView = findField

        countLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize(for: .small), weight: .regular)
        countLabel.textColor = .secondaryLabelColor
        countLabel.alignment = .right
        countLabel.lineBreakMode = .byTruncatingHead

        navigation.segmentCount = 2
        navigation.trackingMode = .momentary
        navigation.controlSize = .small
        navigation.setImage(NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Previous"), forSegment: 0)
        navigation.setImage(NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Next"), forSegment: 1)
        navigation.setToolTip("Previous Match (⇧⌘G)", forSegment: 0)
        navigation.setToolTip("Next Match (⌘G)", forSegment: 1)
        navigation.target = self
        navigation.action = #selector(navigate(_:))

        for (button, title, tip) in [(caseButton, "Aa", "Match Case"), (wordButton, "Word", "Whole Words Only"),
                                     (regexButton, ".*", "Regular Expression (ICU syntax; $1 in the replacement)")] {
            button.title = title
            button.toolTip = tip
            button.setButtonType(.pushOnPushOff)
            button.bezelStyle = .accessoryBar
            button.target = self
            button.action = #selector(optionChanged(_:))
        }
        for (button, title, action) in [(doneButton, "Done", #selector(doneClicked(_:))),
                                        (replaceButton, "Replace", #selector(replaceClicked(_:))),
                                        (replaceAllButton, "Replace All", #selector(replaceAllClicked(_:)))] {
            button.title = title
            button.bezelStyle = .push
            button.target = self
            button.action = action
        }
        for button in [caseButton, wordButton, regexButton, doneButton, replaceButton, replaceAllButton] {
            button.controlSize = .small
            button.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
        }
        for view in [findField, countLabel, navigation, caseButton, wordButton, regexButton, doneButton,
                     replaceField, replaceButton, replaceAllButton] as [NSView] {
            addSubview(view)
        }
        setReplaceRow(hidden: true)
        NotificationCenter.default.addObserver(self, selector: #selector(themeDidChange), name: Theme.didChange, object: nil)
    }

    public required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func themeDidChange(_ note: Notification) { needsDisplay = true }

    /// What the fields and buttons ask for.
    public var query: FindQuery {
        FindQuery(findField.stringValue, matchCase: caseButton.state == .on, wholeWord: wordButton.state == .on,
                  regex: regexButton.state == .on)
    }

    /// What the count label says ("2 of 5", "No matches"), for tests.
    public var status: String { countLabel.stringValue }

    // MARK: - Showing and hiding

    /// Shows the bar (with the Replace row when `replacing`), taking up text searched for in
    /// another app since. The window then puts the keyboard in its field (`focus()`).
    public func show(replacing: Bool) {
        takeFindPasteboard()
        let resized = !isShown || self.replacing != replacing
        self.replacing = replacing
        setReplaceRow(hidden: !replacing)
        if !isShown {
            isShown = true
            isHidden = false
            if let editor { origin = editor.vim == nil ? editor.selection.lowerBound : editor.cursorOffset }
            editor?.findSearch = search
            editor?.findCurrent = currentMatch()
            recount()
        }
        if resized { onResize?() }
        needsLayout = true
    }

    /// The keyboard to the search field, its text selected.
    public func focus() {
        window?.makeFirstResponder(findField)
    }

    /// Hides the bar and its highlights. In Vim mode, a plain-text search becomes Vim's.
    public func hide() {
        guard isShown else { return }
        isShown = false
        isHidden = true
        counting?.cancel()
        writeFindPasteboard()
        if let editor, editor.vim != nil, let pattern = Self.vimPattern(for: searchQuery) {
            editor.vimSession.useSearch(pattern)
        }
        editor?.findSearch = nil
        editor?.findCurrent = nil
        onResize?()
    }

    private func setReplaceRow(hidden: Bool) {
        for view in [replaceField, replaceButton, replaceAllButton] as [NSView] { view.isHidden = hidden }
    }

    private func editorChanged(from old: EditorView?) {
        old?.buffer.removeObserver(self)
        old?.findSearch = nil
        old?.findCurrent = nil
        shown = nil
        note = nil
        guard let editor else { return }
        editor.buffer.addObserver(self) { [weak self] _ in self?.textChanged() }
        if isShown {
            origin = editor.vim == nil ? editor.selection.lowerBound : editor.cursorOffset
            editor.findSearch = search
            recount()
        }
    }

    // MARK: - Finding

    /// Goes to the next match (or the previous one), past the current match or from the
    /// cursor, around the end of the text if need be. Beeps when there's none.
    @discardableResult
    public func findNext(forward: Bool) -> Bool {
        takeFindPasteboard()
        compileIfChanged()
        guard let editor, let search else {
            NSSound.beep()
            return false
        }
        let from: Int
        var acceptAt = false
        if let current = currentMatch() {
            from = current.lowerBound
        } else if editor.vim == nil, !editor.selection.isEmpty {
            from = editor.selection.lowerBound
        } else {
            from = editor.cursorOffset
            acceptAt = forward // a match right at the cursor is the next one
        }
        guard let (r, _) = search.find(in: editor.rope, from: from, forward: forward, wrap: true, acceptAt: acceptAt) else {
            NSSound.beep()
            return false
        }
        origin = r.lowerBound
        go(to: r)
        writeFindPasteboard()
        return true
    }

    /// ⌘E: the selected text becomes the search.
    @discardableResult
    public func useSelection() -> Bool {
        guard let editor, !editor.selection.isEmpty else {
            NSSound.beep()
            return false
        }
        let selection = editor.selection
        let text = String(decoding: editor.rope.bytes(in: selection.range), as: UTF8.self)
        findField.stringValue = regexButton.state == .on ? NSRegularExpression.escapedPattern(for: text) : text
        origin = selection.lowerBound
        compileIfChanged()
        if let search, let (r, _) = search.find(in: editor.rope, from: origin, forward: true, wrap: false, acceptAt: true),
           r == selection.range {
            shown = (r, selection)
            if isShown { editor.findCurrent = r }
        }
        recount()
        writeFindPasteboard()
        return true
    }

    /// Typing in the search field, or a changed option: finds from where the search started.
    private func queryChanged() {
        guard query != searchQuery else { return }
        compileIfChanged()
        if let editor {
            if let search, let (r, _) = search.find(in: editor.rope, from: origin, forward: true, wrap: true, acceptAt: true) {
                go(to: r)
            } else {
                shown = nil
                editor.findCurrent = nil
            }
        }
        recount()
    }

    private func compileIfChanged() {
        let q = query
        guard q != searchQuery || (search == nil && !q.text.isEmpty) else { return }
        searchQuery = q
        search = q.compiled()
        note = nil
        if isShown { editor?.findSearch = search }
    }

    private func go(to r: Range<Int>) {
        guard let editor else { return }
        editor.showMatch(r)
        if !isShown { editor.findCurrent = nil }
        shown = (r, editor.selection)
        updateStatus()
    }

    /// The match the editor is on, if it hasn't moved or changed since the bar put it there.
    private func currentMatch() -> Range<Int>? {
        guard let editor, let shown, editor.selection == shown.selection else { return nil }
        return shown.range
    }

    // MARK: - Replacing

    /// Replaces the current match (or a selected one) and goes to the next.
    public func replace() {
        compileIfChanged()
        guard let editor, let search else {
            NSSound.beep()
            return
        }
        var target = currentMatch()
        if target == nil, !editor.selection.isEmpty,
           let (r, _) = search.find(in: editor.rope, from: editor.selection.lowerBound, forward: true, wrap: false, acceptAt: true),
           r == editor.selection.range {
            target = r
        }
        guard let r = target else {
            findNext(forward: true)
            return
        }
        let text = Array(replacement(for: r, in: editor.rope).utf8)
        let end = r.lowerBound + text.count
        editor.replaceMatches([Change(r, text)], cursor: end)
        origin = end
        if let (next, _) = search.find(in: editor.rope, from: end, forward: true, wrap: true, acceptAt: true) {
            go(to: next)
        }
        recount()
        writeFindPasteboard()
    }

    /// Replaces every match in the text as one undo step; returns how many.
    @discardableResult
    public func replaceAll() -> Int {
        compileIfChanged()
        guard let editor, let search else {
            NSSound.beep()
            return 0
        }
        let typed = replaceField.stringValue
        let literal = Array(typed.utf8)
        var changes: [Change] = []
        search.forEachMatch(in: editor.rope) { m in
            changes.append(Change(m.range, searchQuery.regex ? Array(searchQuery.replacement(typed, for: m, in: search).utf8) : literal))
            return true
        }
        guard !changes.isEmpty else {
            NSSound.beep()
            return 0
        }
        // The cursor stays by the text it was in.
        let cursor = editor.vim == nil ? editor.selection.lowerBound : editor.cursorOffset
        var delta = 0
        var inside: Int?
        for c in changes {
            if c.range.upperBound <= cursor {
                delta += c.text.count - c.range.count
            } else {
                if c.range.lowerBound < cursor { inside = c.range.lowerBound + delta }
                break
            }
        }
        editor.replaceMatches(changes, cursor: inside ?? cursor + delta)
        origin = editor.cursorOffset
        recount()
        note = changes.count == 1 ? "1 replaced" : "\(changes.count.formatted()) replaced"
        updateStatus()
        writeFindPasteboard()
        return changes.count
    }

    /// What replaces `r`: the replacement as typed, or with a regular expression's `$1` and
    /// the like filled in.
    private func replacement(for r: Range<Int>, in rope: Rope) -> String {
        let typed = replaceField.stringValue
        guard searchQuery.regex, let search else { return typed }
        let start = rope.lineStart(containing: r.lowerBound)
        let end = min(rope.byteCount, rope.lineEnd(containing: r.upperBound) + 1)
        guard let m = search.matches(in: rope, start..<end).first(where: { $0.range == r }) else { return typed }
        return searchQuery.replacement(typed, for: m, in: search)
    }

    // MARK: - Counting

    private func textChanged() {
        shown = nil
        note = nil
        editor?.findCurrent = nil
        if isShown { recount(soon: true) }
    }

    /// Counts the matches for "2 of 5": at once for a small text, else in the background
    /// (`soon`: after a moment, so typing in the text doesn't count on every key).
    private func recount(soon: Bool = false) {
        counting?.cancel()
        counting = nil
        countGeneration += 1
        guard isShown, let editor, let search else {
            starts = []
            counted = false
            updateStatus()
            return
        }
        let rope = editor.rope
        if !soon && rope.byteCount <= Self.quickCountLimit {
            setCount(search.allMatches(in: rope, limit: Self.countLimit))
            return
        }
        counted = false
        if !soon { updateStatus() }
        let generation = countGeneration, limit = Self.countLimit
        counting = Task.detached(priority: .userInitiated) { [weak self] in
            if soon { try? await Task.sleep(for: .milliseconds(150)) }
            guard !Task.isCancelled else { return }
            let found = search.allMatches(in: rope, limit: limit) { Task.isCancelled }
            guard !Task.isCancelled else { return }
            await self?.counted(found, generation: generation)
        }
    }

    private func counted(_ found: [Range<Int>], generation: Int) {
        guard generation == countGeneration else { return }
        setCount(found)
    }

    private func setCount(_ found: [Range<Int>]) {
        starts = found.map(\.lowerBound)
        counted = true
        updateStatus()
    }

    private func updateStatus() {
        var text = ""
        var error = false
        if let note {
            text = note
        } else if findField.stringValue.isEmpty {
            text = ""
        } else if search == nil {
            text = "Invalid pattern"
            error = true
        } else if counted {
            let capped = starts.count >= Self.countLimit
            let total = starts.count.formatted() + (capped ? "+" : "")
            if starts.isEmpty {
                text = "No matches"
            } else if let r = currentMatch(), let k = index(of: r.lowerBound) {
                text = "\((k + 1).formatted()) of \(total)"
            } else {
                text = starts.count == 1 ? "1 match" : "\(total) matches"
            }
        }
        countLabel.stringValue = text
        countLabel.textColor = error ? .systemRed : .secondaryLabelColor
    }

    private func index(of start: Int) -> Int? {
        var lo = 0, hi = starts.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if starts[mid] < start { lo = mid + 1 } else { hi = mid }
        }
        return lo < starts.count && starts[lo] == start ? lo : nil
    }

    // MARK: - The find pasteboard

    /// Takes the search text from the system's find pasteboard if another app (or another
    /// window) put new text there.
    private func takeFindPasteboard() {
        let count = findPasteboard.changeCount
        guard count != pasteboardChangeCount else { return }
        pasteboardChangeCount = count
        guard let text = findPasteboard.string(forType: .string), !text.isEmpty, text != findField.stringValue else { return }
        findField.stringValue = text
        compileIfChanged()
        shown = nil
        if isShown { recount() }
    }

    private func writeFindPasteboard() {
        let text = findField.stringValue
        if !text.isEmpty, findPasteboard.string(forType: .string) != text {
            findPasteboard.clearContents()
            findPasteboard.setString(text, forType: .string)
        }
        pasteboardChangeCount = findPasteboard.changeCount
    }

    // MARK: - Vim

    /// The same search as a Vim pattern (very nomagic, so only `\` needs escaping), or nil for
    /// a regular expression, whose syntax differs from Vim's.
    static func vimPattern(for q: FindQuery) -> String? {
        guard !q.regex, !q.text.isEmpty else { return nil }
        func isWordChar(_ c: Character?) -> Bool { c.map { $0.isLetter || $0.isNumber || $0 == "_" } ?? false }
        var p = "\\V" + (q.matchCase ? "\\C" : "\\c")
        if q.wholeWord && isWordChar(q.text.first) { p += "\\<" }
        p += q.text.replacingOccurrences(of: "\\", with: "\\\\")
        if q.wholeWord && isWordChar(q.text.last) { p += "\\>" }
        return p
    }

    // MARK: - Controls

    public func controlTextDidChange(_ obj: Notification) {
        if (obj.object as? NSTextField) === findField { queryChanged() }
    }

    /// Return finds the next match (⇧Return the previous one) or, in the Replace field,
    /// replaces; Esc closes the bar.
    public func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?()
            return true
        case #selector(NSResponder.insertNewline(_:)):
            if control === replaceField {
                replace()
            } else {
                findNext(forward: NSApp.currentEvent?.modifierFlags.contains(.shift) != true)
            }
            return true
        default:
            return false
        }
    }

    /// The field's clear button.
    @objc private func findFieldAction(_ sender: Any?) { queryChanged() }
    @objc private func optionChanged(_ sender: Any?) { queryChanged() }
    @objc private func navigate(_ sender: NSSegmentedControl) { findNext(forward: sender.selectedSegment == 1) }
    @objc private func doneClicked(_ sender: Any?) { onClose?() }
    @objc private func replaceClicked(_ sender: Any?) { replace() }
    @objc private func replaceAllClicked(_ sender: Any?) { replaceAll() }

    // MARK: - Drawing and layout

    public override var isOpaque: Bool { true }

    public override func draw(_ dirtyRect: NSRect) {
        Theme.update(for: effectiveAppearance)
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setFillColor(Theme.bar)
        ctx.fill(bounds)
        ctx.setFillColor(Theme.statusBorder)
        ctx.fill(CGRect(x: 0, y: 0, width: bounds.width, height: 1))
    }

    /// Top row: the search field, the count, ‹ ›, the options and Done, right-aligned. Second
    /// row: the Replace field under the search field, its buttons after it.
    public override func layout() {
        super.layout()
        let pad: CGFloat = 8, gap: CGFloat = 6, h = Self.rowHeight
        func put(_ view: NSView, x: CGFloat, row: Int, width: CGFloat? = nil) {
            let size = view.fittingSize
            let w = width ?? size.width
            let mid = bounds.height - h * (CGFloat(row) + 0.5)
            view.frame = NSRect(x: round(x), y: round(mid - size.height / 2), width: round(w), height: size.height)
        }
        var right = bounds.width - pad
        for view in [doneButton, regexButton, wordButton, caseButton, navigation] as [NSView] {
            let w = view.fittingSize.width
            right -= w
            put(view, x: right, row: 0)
            right -= view === regexButton || view === wordButton ? 2 : gap // the three options sit together
        }
        let countWidth: CGFloat = 104
        right -= countWidth
        put(countLabel, x: right, row: 0, width: countWidth)
        let fieldWidth = max(80, right - gap - pad)
        put(findField, x: pad, row: 0, width: fieldWidth)
        put(replaceField, x: pad, row: 1, width: fieldWidth)
        var x = pad + fieldWidth + gap
        for button in [replaceButton, replaceAllButton] {
            put(button, x: x, row: 1)
            x += button.fittingSize.width + gap
        }
    }
}
