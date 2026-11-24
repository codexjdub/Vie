import Foundation
import VieText

public enum VimMode: Equatable, Sendable {
    case normal, insert, replace, visual, visualLine, visualBlock, commandLine

    public var isVisual: Bool { self == .visual || self == .visualLine || self == .visualBlock }
}

/// How the view should draw the cursor.
public enum VimCursorShape: Sendable {
    case block, bar, underline
}

/// File commands from the command line, carried out by the host.
public enum VimFileCommand: Equatable, Sendable {
    case write(path: String?, force: Bool)
    case quit(force: Bool)
    /// `:wq`.
    case writeQuit(path: String?, force: Bool)
    /// `:x`: write if modified, then quit.
    case exit(force: Bool)
    /// `:e file`, or `:e` to re-read the file; `:e ++enc=sjis` re-reads it in that encoding.
    case edit(path: String?, force: Bool, encoding: String? = nil)
    /// `:qa`: close every buffer (the window).
    case quitAll(force: Bool)
    /// `:wa`.
    case writeAll
    /// `:wqa`, `:xa`.
    case writeQuitAll
    /// `:ls`: the host shows the list (with `showMessage`).
    case listBuffers
    /// `:b 3`, `:b name`, and `{count}gt`.
    case buffer(String)
    /// `:bn`, `gt`.
    case nextBuffer(count: Int)
    /// `:bp`, `gT`.
    case previousBuffer(count: Int)
    /// `:bd`.
    case deleteBuffer(force: Bool)
    /// Space e: show the file tree and move into it, or hide it.
    case toggleSidebar
    /// ⌃H: move into the file tree if it's showing (LazyVim's window-left).
    case focusSidebar
    /// Space b d: close the tab, asking about unsaved changes as ⌘W does.
    case closeTab
    /// Space Space, Space f f: the host's file finder (⌘P).
    case findFile
    /// Space f n: a new, empty tab.
    case newFile
    /// Space q q: quit the app, which asks about unsaved changes.
    case quitApp
    /// Space u w: turn line wrapping on or off.
    case toggleWrap
    /// `:set ft=name`: the buffer's language, for highlighting ("" for plain text).
    case setFiletype(String)
    /// `:set ft?`: show the buffer's language.
    case showFiletype
    /// `:set ff=dos`, `:set fenc=latin1`, `:set bomb`: how the file is saved. `value` is nil
    /// to show the option (`:set ff?`); for `bomb` it's "on", "off" or "toggle".
    case fileOption(VimFileOption, value: String?)
}

/// The options about the file on disk, which belong to the host.
public enum VimFileOption: String, Sendable {
    case fileformat, fileencoding, bomb
}

/// What Vim keeps across buffers: registers, the last search and substitute, command-line
/// history, the last change for `.`, and the global options. Engines of one window (or app)
/// share one session, so a yank in one buffer puts in another.
@MainActor
public final class VimSession {
    var registers = Registers()
    var lastFind: (target: Character, forward: Bool, till: Bool)?
    var lastSearch: (pattern: String, forward: Bool, offset: SearchOffset)?
    var highlightSearch = true
    var lastSubstitute: (pattern: String, replacement: String, flags: String)?
    var lastReplacement: String?
    var lastInserted = ""
    var lastCommandLine = ""
    var dot: DotRecord?
    var lastMacro: Character?
    var history: [Character: [String]] = [:]
    var patternCache: (key: String, pattern: VimPattern)?
    /// Options set with `:set`; the global ones (not tabs and indenting) apply to every engine.
    var options = VimOptions()

    public init() {}

    /// Makes `pattern` the last search, so `n` and `N` go on with it (the Find bar hands over
    /// its search this way when it closes). It isn't highlighted until then, as after `:noh`.
    public func useSearch(_ pattern: String) {
        lastSearch = (pattern, true, SearchOffset())
        highlightSearch = false
    }

    /// The last search's pattern, for tests.
    public var lastSearchPattern: String? { lastSearch?.pattern }
}

/// What the engine needs from the editor around it.
@MainActor
public protocol VimHost: AnyObject {
    /// Lines currently on screen.
    var visibleLines: Range<Int> { get }
    /// Scrolls so `line` is the first visible line.
    func vimScroll(toTopLine line: Int)
    func vimReadClipboard() -> String?
    func vimWriteClipboard(_ text: String)
    func vimBeep()
    /// Carries out a file command; returns an error message to show, or nil.
    func vimPerform(_ command: VimFileCommand) -> String?
    /// Mode, cursor, command line or message changed: redraw.
    func vimStateDidChange()
    /// Called when Esc leaves Insert mode, so typing commands isn't caught by an IME.
    func vimSwitchToASCIIInput()
}

/// The Vim engine: turns keys into motions, operators and edits on a `Buffer`.
///
/// Normal-mode keys are collected until they form a command (`"a3d2w`, `ci(`, `gUiw`), which
/// is then parsed into register · count · operator · motion and applied. Each change is one
/// undo step. Insert-mode text arrives through `insertText(_:)` (so the IME works), other
/// keys through `handle(_:)`. Behavior follows Vim; Tests/VieVimTests/Specs checks it
/// against real Vim.
@MainActor
public final class VimEngine {
    public let buffer: Buffer
    public weak var host: VimHost?
    public let session: VimSession
    /// Options: tabs and indenting belong to this buffer, the rest (searching, joining) are
    /// shared through the session, as in Vim.
    public var options: VimOptions {
        get {
            var o = localOptions
            o.takeGlobals(from: session.options)
            return o
        }
        set {
            localOptions = newValue
            session.options.takeGlobals(from: newValue)
        }
    }
    private var localOptions = VimOptions()

    public internal(set) var mode: VimMode = .normal
    /// Byte offset of the cursor: the character under the block in Normal mode, the insertion
    /// point in Insert mode.
    public internal(set) var cursor = 0
    /// Display column j and k aim for (`Int.max` after `$`). As with Vim's w_set_curswant,
    /// it's measured when a command first needs it after the cursor moved, so typing deep
    /// inside a very long line doesn't scan the line on every key.
    var curswant: Int {
        get {
            if let c = storedCurswant { return c }
            let c = cursorVcol(cursorPos)
            storedCurswant = c
            return c
        }
        set { storedCurswant = newValue }
    }
    private var storedCurswant: Int?

    var visualAnchor = 0
    var lastVisual: (mode: VimMode, anchor: Int, cursor: Int, curswant: Int)?

    /// Keys of the Normal-mode command being typed.
    var pending: [VimKey] = []
    var registers: Registers {
        get { session.registers }
        _modify { yield &session.registers }
    }
    /// Marks as byte offsets, kept in step with edits. `'` is the previous context mark.
    var marks: [Character: Int] = ["'": 0]
    var lastFind: (target: Character, forward: Bool, till: Bool)? {
        get { session.lastFind }
        set { session.lastFind = newValue }
    }
    var lastSearch: (pattern: String, forward: Bool, offset: SearchOffset)? {
        get { session.lastSearch }
        set { session.lastSearch = newValue }
    }
    /// False after `:nohlsearch`, until the next search.
    var highlightSearch: Bool {
        get { session.highlightSearch }
        set { session.highlightSearch = newValue }
    }
    var lastSubstitute: (pattern: String, replacement: String, flags: String)? {
        get { session.lastSubstitute }
        set { session.lastSubstitute = newValue }
    }
    var lastReplacement: String? {
        get { session.lastReplacement }
        set { session.lastReplacement = newValue }
    }
    var lastInserted: String {
        get { session.lastInserted }
        set { session.lastInserted = newValue }
    }
    var lastCommandLine: String {
        get { session.lastCommandLine }
        set { session.lastCommandLine = newValue }
    }

    var dot: DotRecord? {
        get { session.dot }
        set { session.dot = newValue }
    }
    /// The change being typed, committed to `dot` when it's complete.
    var dotPending: DotRecord?
    var replaying = 0

    var recording: (register: Character, keys: [VimKey])?
    var lastMacro: Character? {
        get { session.lastMacro }
        set { session.lastMacro = newValue }
    }
    var macroDepth = 0

    var insert: InsertSession?
    var cmdline: CommandLineState?
    var history: [Character: [String]] {
        get { session.history }
        _modify { yield &session.history }
    }

    var patternCache: (key: String, pattern: VimPattern)? {
        get { session.patternCache }
        set { session.patternCache = newValue }
    }
    /// The match the search being typed would go to ('incsearch'), for the view to show.
    public internal(set) var incsearchRange: Range<Int>?
    /// Edits since tracking started (for `:normal` over a range); on while above 0.
    var trackEdits = 0
    var editLog: [TextEdit] = []

    public internal(set) var message: String?
    public internal(set) var messageIsError = false
    /// Set by `beep()`; makes macros and `:normal` stop.
    var failed = false
    /// True while the engine edits the buffer, so the observer knows a change is its own.
    var applyingEdit = false
    /// Set by the editor: whether Markdown list editing applies at an offset (in a Markdown
    /// file, outside code). Return, Tab, ⇧Tab and Backspace in Insert mode and `o`/`O` then
    /// follow list items, and numbered lists are renumbered after commands change them.
    public var markdownLists: ((Int) -> Bool)?
    /// Starts of lines where the current command added, removed or indented lines in a
    /// Markdown list, kept in step with its edits: their lists are renumbered when it ends.
    var renumberAt: [Int] = []
    let lineCache = LineCache()

    public init(buffer: Buffer, session: VimSession = VimSession()) {
        self.buffer = buffer
        self.session = session
        cursor = min(buffer.selection.head, buffer.rope.byteCount)
        buffer.addObserver(self) { [weak self] change in self?.bufferDidChange(change) }
        cursor = clampNormal(cursor)
        updateCurswant()
        syncSelection()
    }

    // MARK: - Public state

    /// What the status bar shows for the mode.
    public var modeText: String {
        var s: String
        switch mode {
        case .insert: s = insert?.block != nil ? "-- VISUAL BLOCK INSERT --" : "-- INSERT --"
        case .replace: s = "-- REPLACE --"
        case .visual: s = "-- VISUAL --"
        case .visualLine: s = "-- VISUAL LINE --"
        case .visualBlock: s = "-- VISUAL BLOCK --"
        case .normal, .commandLine: s = ""
        }
        if let r = recording { s += (s.isEmpty ? "" : " ") + "recording @\(r.register)" }
        return s
    }

    /// Keys typed so far for an unfinished command (Vim's 'showcmd'), a Space shown as ␣.
    public var pendingText: String { pending.map { $0.character == " " ? "␣" : $0.description }.joined() }

    /// The command line being typed, including its `:`, `/` or `?`, or nil.
    public var commandLineText: String? { cmdline.map { String($0.kind) + String($0.text) } }

    /// Cursor position in `commandLineText`, in characters (counting the prefix).
    public var commandLineCursor: Int { (cmdline?.cursor ?? 0) + 1 }

    public var recordingRegister: Character? { recording?.register }

    public var cursorShape: VimCursorShape {
        switch mode {
        case .insert: .bar
        case .replace: .underline
        case .commandLine: cmdline?.origin == .insert ? .bar : .block
        default: .block
        }
    }

    /// In Visual block mode, the selected byte range of each line, for drawing.
    public var visualBlockRanges: [Range<Int>]? {
        guard mode == .visualBlock else { return nil }
        let b = blockBounds()
        return (b.top...b.bottom).map { line in
            let r = blockCols(line, b)
            let start = lineStart(line)
            return (start + r.lowerBound)..<(start + r.upperBound)
        }
    }

    // MARK: - Input

    /// Handles one key typed by the user. Returns false when it failed (Vim would beep).
    @discardableResult
    public func handle(_ key: VimKey) -> Bool {
        if var r = recording {
            r.keys.append(key)
            recording = r
        }
        if key.isEscape && (mode == .insert || mode == .replace) { host?.vimSwitchToASCIIInput() }
        // As LazyVim maps it, Esc in Normal, Insert or Replace mode also hides the search
        // highlighting, as `:nohlsearch` does; `n`, `N`, `*`, `#` and `/` show it again.
        if key.isEscape && (mode == .normal || mode == .insert || mode == .replace) { highlightSearch = false }
        failed = false
        process(key)
        renumberLists()
        notifyHost()
        return !failed
    }

    public func handle(keys: [VimKey]) {
        for k in keys { handle(k) }
    }

    /// Text typed in Insert or Replace mode or on the command line (from the input method).
    public func insertText(_ text: String) {
        if var r = recording {
            r.keys.append(contentsOf: VimKey.keys(from: text))
            recording = r
        }
        failed = false
        switch mode {
        case .insert, .replace:
            typeText(text)
        case .commandLine:
            for c in text { commandLineKey(VimKey(c)) }
        default:
            for k in VimKey.keys(from: text) { process(k) }
        }
        renumberLists()
        notifyHost()
    }

    /// Back to Normal mode with nothing pending, as when Vim mode is switched on or the
    /// buffer is replaced underneath.
    public func reset() {
        if insert != nil { buffer.endUndoGroup() }
        insert = nil
        cmdline = nil
        pending = []
        dotPending = nil
        mode = .normal
        cursor = clampNormal(min(buffer.selection.head, rope.byteCount))
        syncSelection()
        notifyHost()
    }

    /// Takes the cursor (and a selection, as Visual mode) from the buffer after the view
    /// changed it, for example with a mouse click or drag.
    public func syncFromBuffer() {
        let sel = buffer.selection
        if mode == .insert || mode == .replace {
            cursor = sel.head
            insert?.start = cursor
            return
        }
        pending = []
        if sel.isEmpty {
            if mode.isVisual { endVisual() }
            cursor = clampNormal(sel.head)
            updateCurswant()
            syncSelection()
        } else {
            if !mode.isVisual { mode = .visual }
            visualAnchor = sel.anchor
            cursor = sel.head > sel.anchor ? rope.previousGraphemeBoundary(before: sel.head) : sel.head
            updateCurswant()
            syncSelection()
        }
        notifyHost()
    }

    /// Shows a message in the status bar, as a command would (`"a.txt" 3L, 20B written`).
    public func showMessage(_ text: String, error: Bool = false) {
        show(text, error: error)
        notifyHost()
    }

    /// Undo or redo from the Edit menu. Leaves Insert, Visual or Command-line mode first,
    /// then moves the cursor as `u` and `⌃R` do.
    public func undoFromMenu(redo: Bool) {
        failed = false
        if mode != .normal { process(.escape) }
        pending = []
        undo(count: 1, redo: redo)
        notifyHost()
    }

    func process(_ key: VimKey) {
        switch mode {
        case .insert, .replace: insertKey(key)
        case .commandLine: commandLineKey(key)
        default: normalKey(key)
        }
    }

    /// Runs keys as if typed, without recording them. With `stopOnFailure`, stops at the
    /// first failing command (as a macro does). Returns false if a key failed.
    @discardableResult
    func run(_ keys: [VimKey], stopOnFailure: Bool) -> Bool {
        var ok = true
        for k in keys {
            failed = false
            process(k)
            if failed {
                ok = false
                if stopOnFailure { break }
            }
        }
        return ok
    }

    func notifyHost() { host?.vimStateDidChange() }

    func beep() {
        failed = true
        pending = []
        host?.vimBeep()
    }

    func show(_ text: String, error: Bool = false) {
        message = text
        messageIsError = error
    }

    func fail(_ text: String) {
        show(text, error: true)
        beep()
    }

    // MARK: - Normal mode

    func normalKey(_ key: VimKey) {
        if pending.isEmpty && message != nil && !replayingOrMacro { message = nil }
        pending.append(key)
        switch parse(pending, visual: mode.isVisual) {
        case .incomplete:
            return
        case .invalid:
            pending = []
            // Esc cancels a half-typed command quietly. On its own it doesn't beep either (Vim
            // does): it's the key that hides search highlighting, as in Neovim and LazyVim.
            if key.isEscape { return }
            beep()
        case .command(let c):
            pending = []
            execute(c)
        }
    }

    var replayingOrMacro: Bool { replaying > 0 || macroDepth > 0 }

    /// The keys typed after Space ("" right after it, "f" after Space f) while a Space command
    /// waits for its next key in Normal mode; nil when none is waiting. It waits as long as it
    /// takes, as LazyVim's leader keys do with which-key: a lone Space doesn't move right.
    public var spacePrefix: String? {
        guard mode == .normal, let i = pending.lastIndex(where: { $0.character == " " }) else { return nil }
        let rest = String(pending[(i + 1)...].map(\.character))
        return rest.isEmpty || Self.spaceGroups.contains(rest) ? rest : nil
    }

    /// What can follow the Space keys typed so far, for the host's hint (LazyVim's which-key):
    /// commands, then groups, each in key order. Nil when no Space command is waiting.
    public var spaceHint: [VimSpaceItem]? {
        guard let prefix = spacePrefix else { return nil }
        return Self.spaceMenu
            .filter { $0.keys.count == prefix.count + 1 && $0.keys.hasPrefix(prefix) }
            .map { VimSpaceItem(key: $0.keys.last!, title: $0.title, isGroup: $0.command == nil) }
            .sorted { ($0.isGroup ? 1 : 0, $0.key) < ($1.isGroup ? 1 : 0, $1.key) }
    }

    /// At the end of keys fed all at once (`:normal`, tests), a Space still waiting for its
    /// second key is Vim's Space (move right), as when Vim's 'timeout' runs out; a Space
    /// command left half typed (Space f) is dropped.
    public func timeoutPending() {
        guard let prefix = spacePrefix else { return }
        guard prefix.isEmpty else {
            pending = []
            return
        }
        let keys = pending
        pending = []
        if case .command(let c) = parse(keys, visual: false, spaceIsMotion: true) { execute(c) }
    }

    func execute(_ c: ParsedCommand) {
        let change = c.isChange
        if change && replaying == 0 {
            var rec = DotRecord(keys: c.keys, count: c.count, register: c.register)
            if mode.isVisual { rec.visual = visualRepeat() }
            dotPending = rec
        }
        if let op = c.op {
            switch c.action {
            case .motion(let m): operatorWithMotion(op, m, c)
            case .object(let o, let inner): operatorWithObject(op, o, inner: inner, c)
            case .doubled: operatorDoubled(op, c)
            case .command: break
            }
        } else {
            switch c.action {
            case .motion(let m): moveCursor(m, c)
            case .object(let o, let inner): visualSelectObject(o, inner: inner, c)
            case .command(let cmd): runCommand(cmd, c)
            case .doubled: break
            }
        }
        if change { finishChangeIfComplete() }
    }

    /// Commits the pending dot record once its command is over (not still typing in Insert
    /// mode or on the command line).
    func finishChangeIfComplete() {
        guard replaying == 0, mode != .insert, mode != .replace, mode != .commandLine else { return }
        if failed {
            dotPending = nil
            return
        }
        if let d = dotPending { dot = d }
        dotPending = nil
    }

    // MARK: - Text access

    var rope: Rope { buffer.rope }
    var lastLine: Int { rope.lineCount - 1 }

    func text(_ line: Int) -> [UInt8] { lineCache.bytes(buffer, line) }
    func lineStart(_ line: Int) -> Int { rope.offset(ofLine: line) }
    func lineLength(_ line: Int) -> Int { rope.lineEnd(line) - rope.offset(ofLine: line) }
    func isEmptyLine(_ line: Int) -> Bool { lineLength(line) == 0 }

    func pos(_ offset: Int) -> Pos {
        let off = min(max(offset, 0), rope.byteCount)
        let line = rope.line(at: off)
        return Pos(line, off - rope.offset(ofLine: line))
    }

    func offset(_ p: Pos) -> Int {
        let line = min(max(p.line, 0), lastLine)
        return rope.offset(ofLine: line) + min(p.col, lineLength(line))
    }

    var cursorPos: Pos {
        get { pos(cursor) }
        set { cursor = offset(newValue) }
    }

    /// Column of the first non-blank (Vim's beginline with BL_WHITE | BL_FIX: on an all-blank
    /// line, the last blank rather than the end).
    func firstNonBlank(_ line: Int) -> Int {
        let b = text(line)
        var i = 0
        while i < b.count && isBlank(b[i]) && i + 1 < b.count { i += 1 }
        if i < b.count && !isBlank(b[i]) { return i }
        return i
    }

    /// Vim's beginline(BL_SOL | BL_FIX): the first non-blank with 'startofline', else the
    /// remembered column.
    func startOfLineCol(_ line: Int) -> Int {
        options.startofline ? firstNonBlank(line) : colForVcol(text(line), curswant, tabstop: options.tabstop, oneMore: false)
    }

    /// Normal-mode cursor rule: not on the end of a non-empty line.
    /// Normal mode's cursor can't be past the last character. (Works on the rope, not a copy
    /// of the line: it runs after every edit made outside the engine.)
    func clampNormal(_ offset: Int) -> Int {
        let line = rope.line(at: min(max(offset, 0), rope.byteCount))
        let start = lineStart(line), end = rope.lineEnd(line)
        if offset >= end { return end > start ? rope.previousGraphemeBoundary(before: end) : start }
        return offset
    }

    func clampNormal(_ p: Pos) -> Pos { pos(clampNormal(offset(p))) }

    /// The display column Vim's cursor is at (for Tab in Normal mode, its last cell). Reads
    /// the line only up to the cursor.
    func cursorVcol(_ p: Pos) -> Int {
        let start = lineStart(p.line)
        let b = rope.bytes(in: start..<min(start + p.col + 1, rope.lineEnd(p.line)))
        let v = vcolOf(b, p.col, tabstop: options.tabstop)
        if p.col < b.count && b[p.col] == 0x09 {
            let tabEnd = mode == .normal || (mode.isVisual && pos(visualAnchor) < p)
            if tabEnd { return v + cellsAt(b, p.col, vcol: v, tabstop: options.tabstop) - 1 }
        }
        return v
    }

    func updateCurswant() { storedCurswant = nil }

    /// Moves the buffer's selection to match the cursor (and Visual selection).
    func syncSelection() {
        if mode.isVisual {
            buffer.selection = visualSelection()
        } else {
            buffer.selection = Selection(cursor)
        }
    }

    func setCursor(_ offset: Int) {
        cursor = offset
        syncSelection()
    }

    // MARK: - Editing

    /// Applies changes as part of the current command's undo step and moves the cursor.
    func edit(_ changes: [Change], cursor newCursor: Int) {
        let changes = changes.sorted { $0.range.lowerBound < $1.range.lowerBound }
        var renumber: [Int] = []
        if let lists = markdownLists, insert?.block == nil, let first = changes.first, lists(first.range.lowerBound) {
            renumber = MarkdownList.linesToRenumber(rope, changes: changes)
        }
        applyingEdit = true
        buffer.edit(changes, selection: Selection(newCursor))
        applyingEdit = false
        cursor = min(newCursor, rope.byteCount)
        for line in renumber where line < rope.lineCount { renumberAt.append(rope.offset(ofLine: line)) }
    }

    /// Renumbers the Markdown lists the command just changed (see `renumberAt`), as part of
    /// its undo step. The `.` mark stays on the command's own change.
    func renumberLists() {
        guard !renumberAt.isEmpty else { return }
        let lines = renumberAt.map { rope.line(at: min($0, rope.byteCount)) }
        renumberAt = []
        let fix = MarkdownList.renumber(rope, around: lines)
        guard !fix.isEmpty else { return }
        let lastChange = marks["."].map { Change.map($0, through: fix) }
        let c = Change.map(cursor, through: fix)
        applyingEdit = true
        buffer.amend(fix, selection: Selection(c))
        applyingEdit = false
        marks["."] = lastChange
        cursor = c
        syncSelection()
    }

    func replace(_ range: Range<Int>, with text: [UInt8], cursor newCursor: Int) {
        edit([Change(range, text)], cursor: newCursor)
    }

    /// Runs `body` as one undo step whose "cursor before" is `cursorBefore`.
    func change(at cursorBefore: Int, _ body: () -> Void) {
        setCursor(cursorBefore)
        buffer.selection = Selection(cursorBefore)
        buffer.beginUndoGroup()
        body()
        buffer.endUndoGroup()
    }

    func bufferDidChange(_ change: BufferChange) {
        func map(_ p: Int) -> Int { VimEngine.map(p, through: change.edits) }
        for (k, v) in marks { marks[k] = map(v) }
        if let last = change.edits.last { marks["."] = last.range.lowerBound }
        if trackEdits > 0 { editLog += change.edits }
        visualAnchor = map(visualAnchor)
        renumberAt = renumberAt.map(map)
        if var lv = lastVisual {
            lv.anchor = map(lv.anchor)
            lv.cursor = map(lv.cursor)
            lastVisual = lv
        }
        if !applyingEdit {
            // Someone else edited (undo in the view, paste from a menu, reload).
            cursor = min(buffer.selection.head, rope.byteCount)
            if mode == .normal { cursor = clampNormal(cursor) }
            if mode.isVisual { mode = .normal; cursor = clampNormal(cursor) }
            if let start = insert?.start { insert?.start = min(map(start), rope.byteCount) }
        }
    }

    /// Where a position moves through edits. A position at an insertion point stays before
    /// the new text unless that text contains a line break (Vim shifts marks to the next line
    /// when lines are opened above them).
    static func map(_ p: Int, through edits: [TextEdit]) -> Int {
        var p = p
        for e in edits {
            if p < e.range.lowerBound { continue }
            if e.range.isEmpty {
                if p > e.range.lowerBound || e.insertsNewline { p += e.newLength }
                continue
            }
            if p >= e.range.upperBound { p += e.newLength - e.range.count; continue }
            p = e.range.lowerBound + min(p - e.range.lowerBound, e.newLength)
        }
        return p
    }

    // MARK: - Undo

    func undo(count: Int, redo: Bool) {
        for i in 0..<count {
            applyingEdit = true
            let r = redo ? buffer.performRedo() : buffer.performUndo()
            applyingEdit = false
            guard let r else {
                if i == 0 { fail(redo ? "Already at newest change" : "Already at oldest change") }
                return
            }
            cursor = cursorAfterUndo(r)
        }
        cursor = clampNormal(cursor)
        updateCurswant()
        syncSelection()
    }

    /// Vim puts the cursor back where the change started when that's near the changed
    /// lines, else on the first non-blank of the first changed line.
    func cursorAfterUndo(_ r: UndoResult) -> Int {
        let before = min(r.selectionBefore.head, rope.byteCount)
        let line = rope.line(at: before)
        let top = min(r.change.firstLine, lastLine)
        let bottom = r.change.lastLine == .max ? Int.max : r.change.lastLine + 1
        if line >= top - 1 && line <= bottom { return before }
        return lineStart(top) + firstNonBlank(top)
    }
}

/// Copies of recently used lines, valid for one buffer version.
@MainActor
final class LineCache {
    private var version = -1
    private var entries: [(line: Int, bytes: [UInt8])] = []

    func bytes(_ buffer: Buffer, _ line: Int) -> [UInt8] {
        if buffer.version != version {
            entries.removeAll(keepingCapacity: true)
            version = buffer.version
        }
        if let e = entries.first(where: { $0.line == line }) { return e.bytes }
        let rope = buffer.rope
        let line = min(max(line, 0), rope.lineCount - 1)
        let b = rope.bytes(in: rope.offset(ofLine: line)..<rope.lineEnd(line))
        if entries.count >= 8 { entries.removeFirst() }
        entries.append((line, b))
        return b
    }
}

// MARK: - Commands and parsing

enum Operator: Equatable {
    case delete, change, yank, shiftRight, shiftLeft, reindent, toggleCase, lowerCase, upperCase
}

enum Motion: Equatable {
    case left(wrap: Bool), right(wrap: Bool), up, down
    case upFirstNonBlank, downFirstNonBlank, firstNonBlankCount
    case wordForward(big: Bool), wordBackward(big: Bool), wordEnd(big: Bool), wordEndBackward(big: Bool)
    case lineStart, firstNonBlank, lineEnd, lastNonBlank, column
    case gotoLine(last: Bool)
    case find(Character, forward: Bool, till: Bool)
    case repeatFind(reverse: Bool)
    case matchPair
    case paragraph(forward: Bool)
    case screenTop, screenMiddle, screenBottom
    case searchNext(reverse: Bool)
    case searchWord(forward: Bool, whole: Bool)
    case searchPrompt(forward: Bool)
    case mark(Character, exact: Bool)
}

enum TextObject: Equatable {
    case word(big: Bool), quote(UInt8), block(open: UInt8, close: UInt8), paragraph, tag
}

enum InsertKind: Equatable {
    case before, after, lineStart, lineEnd, column0, openBelow, openAbove, lastInsert, change
}

enum ScrollKind: Equatable {
    case halfDown, halfUp, pageDown, pageUp, lineDown, lineUp, cursorTop, cursorMiddle, cursorBottom
}

enum Command: Equatable {
    case deleteChar(forward: Bool)
    case deleteToEnd, changeToEnd, substituteChar, substituteLine, yankLine
    case put(before: Bool, cursorAfter: Bool)
    case join(spaces: Bool)
    case replaceChar(Character)
    case toggleCaseChar
    case insert(InsertKind)
    case replaceMode
    case visual(VimMode)
    case reselect
    case undo, redo, dot
    case record(Character?)
    case playMacro(Character)
    case setMark(Character)
    case commandLine(Character)
    case repeatSubstitute(global: Bool)
    case increment(Int)
    case scroll(ScrollKind)
    case escape
    case writeQuit(force: Bool)
    case fileInfo
    /// `gt` and `gT`: the next or previous buffer (tab).
    case switchBuffer(next: Bool)
    /// ⇧H and ⇧L: the previous or next buffer, `count` away (LazyVim's mapping).
    case cycleBuffer(forward: Bool)
    /// A Space command (Space e, Space f f…), which the host carries out.
    case host(VimFileCommand)
    /// ⌃H: into the host's file tree.
    case focusFileTree
    // Visual mode
    case visualSwap(horizontal: Bool)
    case visualOperator(Operator)
    case visualLineOperator(Operator)
    case visualReplace(Character)
    case visualJoin(spaces: Bool)
    case visualPut(before: Bool)
    case visualInsert(append: Bool)
}

enum Action: Equatable {
    case motion(Motion)
    case object(TextObject, inner: Bool)
    case doubled
    case command(Command)
}

struct ParsedCommand {
    var register: Character?
    /// The counts multiplied together, nil when none was typed.
    var count: Int?
    var op: Operator?
    var action: Action
    /// The command's keys without counts or register, for `.`.
    var keys: [VimKey]

    var count1: Int { max(count ?? 1, 1) }

    var isChange: Bool {
        if let op { return op != .yank }
        guard case .command(let c) = action else { return false }
        switch c {
        case .deleteChar, .deleteToEnd, .changeToEnd, .substituteChar, .substituteLine, .put, .join, .replaceChar,
             .toggleCaseChar, .insert, .replaceMode, .increment, .repeatSubstitute, .visualReplace, .visualJoin,
             .visualPut, .visualInsert:
            return true
        case .visualOperator(let op), .visualLineOperator(let op):
            return op != .yank
        default:
            return false
        }
    }
}

enum ParseResult {
    case incomplete, invalid, command(ParsedCommand)
}

/// An entry of the menu Space opens, for the host's hint: its key, what it does, and whether
/// it leads to more keys (a group, such as LazyVim's "+file/find").
public struct VimSpaceItem: Equatable, Sendable {
    public let key: Character
    public let title: String
    public let isGroup: Bool

    public init(key: Character, title: String, isGroup: Bool) {
        self.key = key
        self.title = title
        self.isGroup = isGroup
    }
}

extension VimEngine {
    /// Vie's Space commands: LazyVim's leader keys for what Vie does. Each is the keys after
    /// Space, a title for the hint, and the command; a group (no command) leads to more keys.
    static let spaceMenu: [(keys: String, title: String, command: VimFileCommand?)] = [
        (" ", "Find file", .findFile),
        ("e", "File tree", .toggleSidebar),
        ("b", "+buffer", nil),
        ("bd", "Close tab", .closeTab),
        ("f", "+file/find", nil),
        ("fe", "File tree", .toggleSidebar),
        ("ff", "Find file", .findFile),
        ("fn", "New file", .newFile),
        ("q", "+quit", nil),
        ("qq", "Quit Vie", .quitApp),
        ("u", "+ui", nil),
        ("uw", "Wrap lines", .toggleWrap),
    ]

    static let spaceCommands: [String: VimFileCommand] = Dictionary(
        uniqueKeysWithValues: spaceMenu.compactMap { item in item.command.map { (item.keys, $0) } })

    static let spaceGroups = Set(spaceMenu.filter { $0.command == nil }.map(\.keys))
}

struct DotRecord {
    var keys: [VimKey]
    var count: Int?
    var register: Character?
    var visual: VisualRepeat?
}

/// The size of the Visual area a change was made on, so `.` can apply it to the same
/// amount of text.
struct VisualRepeat {
    var mode: VimMode
    var lines: Int
    /// Characters (single line), end column (several lines), or block width in cells.
    var cols: Int
    var toEnd: Bool
}

extension VimEngine {
    /// Parses the keys of a Normal or Visual mode command. `spaceIsMotion` parses a leading
    /// Space as Vim's motion instead of the start of a two-key command.
    func parse(_ keys: [VimKey], visual: Bool, spaceIsMotion: Bool = false) -> ParseResult {
        var i = 0
        var register: Character?
        var count1: Int?
        while true {
            guard i < keys.count else { return .incomplete }
            let k = keys[i]
            if k.character == "\"" {
                guard i + 1 < keys.count else { return .incomplete }
                let r = keys[i + 1].character
                guard Registers.isValid(r) else { return .invalid }
                register = r
                i += 2
                continue
            }
            if let d = k.digit, d != 0 || count1 != nil {
                count1 = min((count1 ?? 0) * 10 + d, 99_999_999)
                i += 1
                continue
            }
            break
        }
        let start = i
        func result(_ action: Action, op: Operator? = nil, count2: Int? = nil, keys stripped: [VimKey]) -> ParseResult {
            var count = count1
            if let count2 { count = (count ?? 1) * count2 }
            return .command(ParsedCommand(register: register, count: count, op: op, action: action, keys: stripped))
        }

        let k = keys[i]
        i += 1
        var op: Operator?
        switch k.character {
        case "d": op = .delete
        case "c": op = .change
        case "y": op = .yank
        case ">": op = .shiftRight
        case "<": op = .shiftLeft
        case "=": op = .reindent
        case "g":
            guard i < keys.count else { return .incomplete }
            switch keys[i].character {
            case "~": op = .toggleCase
            case "u": op = .lowerCase
            case "U": op = .upperCase
            default: break
            }
            if op != nil { i += 1 }
        default: break
        }

        if let op {
            let opKeys = Array(keys[start..<i])
            if visual { return result(.command(.visualOperator(op)), keys: opKeys) }
            var count2: Int?
            while i < keys.count, let d = keys[i].digit, d != 0 || count2 != nil {
                count2 = min((count2 ?? 0) * 10 + d, 99_999_999)
                i += 1
            }
            guard i < keys.count else { return .incomplete }
            let rest = i
            // Doubled: dd, cc, yy, >>, <<, ==, g~~, g~g~, guu, gugu, gUU, gUgU.
            let last = opKeys.last!.character
            if keys[i].character == last && (opKeys.count == 1 || last != "g") {
                return result(.doubled, op: op, count2: count2, keys: opKeys + [keys[i]])
            }
            if opKeys.count == 2 && keys[i].character == "g" {
                guard i + 1 < keys.count else { return .incomplete }
                if keys[i + 1].character == last { return result(.doubled, op: op, count2: count2, keys: opKeys + [keys[i], keys[i + 1]]) }
            }
            if keys[i].character == "i" || keys[i].character == "a" {
                guard i + 1 < keys.count else { return .incomplete }
                guard let obj = textObject(keys[i + 1].character) else { return .invalid }
                return result(.object(obj, inner: keys[i].character == "i"), op: op, count2: count2, keys: opKeys + [keys[i], keys[i + 1]])
            }
            switch parseMotion(keys, &i) {
            case .incomplete: return .incomplete
            case .invalid: return .invalid
            case .motion(let m): return result(.motion(m), op: op, count2: count2, keys: opKeys + Array(keys[rest..<i]))
            }
        }

        i = start
        let ch = k.character
        func cmd(_ c: Command, _ n: Int = 1) -> ParseResult {
            result(.command(c), keys: Array(keys[start..<(start + n)]))
        }
        func needChar(_ make: (Character) -> Command?) -> ParseResult {
            guard start + 1 < keys.count else { return .incomplete }
            let c = keys[start + 1]
            if c.isEscape { return .invalid }
            guard let command = make(c.character) else { return .invalid }
            return cmd(command, 2)
        }

        if visual {
            switch ch {
            case "o": return cmd(.visualSwap(horizontal: false))
            case "O": return cmd(.visualSwap(horizontal: mode == .visualBlock))
            case "x", "\u{F728}": return cmd(.visualOperator(.delete))
            case "s": return cmd(.visualOperator(.change))
            case "~": return cmd(.visualOperator(.toggleCase))
            case "u": return cmd(.visualOperator(.lowerCase))
            case "U": return cmd(.visualOperator(.upperCase))
            case "X", "D": return cmd(.visualLineOperator(.delete))
            case "Y": return cmd(.visualLineOperator(.yank))
            case "C", "S", "R": return cmd(.visualLineOperator(.change))
            case "r": return needChar { .visualReplace($0) }
            case "J": return cmd(.visualJoin(spaces: true))
            case "p": return cmd(.visualPut(before: false))
            case "P": return cmd(.visualPut(before: true))
            case "I": return cmd(.visualInsert(append: false))
            case "A": return cmd(.visualInsert(append: true))
            case "v": return cmd(.visual(.visual))
            case "V": return cmd(.visual(.visualLine))
            case "\u{16}": return cmd(.visual(.visualBlock))
            case ":": return cmd(.commandLine(":"))
            case "\u{1B}", "\u{03}": return cmd(.escape)
            case "i", "a":
                guard start + 1 < keys.count else { return .incomplete }
                guard let obj = textObject(keys[start + 1].character) else { return .invalid }
                return result(.object(obj, inner: ch == "i"), keys: Array(keys[start...(start + 1)]))
            case "g":
                guard start + 1 < keys.count else { return .incomplete }
                switch keys[start + 1].character {
                case "v": return cmd(.reselect, 2)
                case "J": return cmd(.visualJoin(spaces: false), 2)
                default: break
                }
            default: break
            }
        } else {
            switch ch {
            case "x", "\u{F728}": return cmd(.deleteChar(forward: true))
            case "X": return cmd(.deleteChar(forward: false))
            case "D": return cmd(.deleteToEnd)
            case "C": return cmd(.changeToEnd)
            case "s": return cmd(.substituteChar)
            case "S": return cmd(.substituteLine)
            case "Y": return cmd(.yankLine)
            case "p": return cmd(.put(before: false, cursorAfter: false))
            case "P": return cmd(.put(before: true, cursorAfter: false))
            case "J": return cmd(.join(spaces: true))
            case "r": return needChar { .replaceChar($0) }
            case "~": return cmd(.toggleCaseChar)
            case "i", "\u{F727}": return cmd(.insert(.before))
            case "a": return cmd(.insert(.after))
            case "I": return cmd(.insert(.lineStart))
            case "A": return cmd(.insert(.lineEnd))
            case "o": return cmd(.insert(.openBelow))
            case "O": return cmd(.insert(.openAbove))
            case "R": return cmd(.replaceMode)
            case "v": return cmd(.visual(.visual))
            case "V": return cmd(.visual(.visualLine))
            case "\u{16}": return cmd(.visual(.visualBlock))
            case "u": return cmd(.undo)
            case "\u{12}": return cmd(.redo)
            case ".": return cmd(.dot)
            case "q":
                if recording != nil { return cmd(.record(nil)) }
                return needChar { c in c.isASCII && (c.isLetter || c.isNumber) || c == "\"" ? .record(c) : nil }
            case "@": return needChar { c in c.isASCII && (c.isLetter || c.isNumber) || "@:\".".contains(c) ? .playMacro(c) : nil }
            case "m": return needChar { c in c.isASCII && c.isLetter || "'`[]<>".contains(c) ? .setMark(c) : nil }
            case ":": return cmd(.commandLine(":"))
            case "&": return cmd(.repeatSubstitute(global: false))
            case "\u{01}": return cmd(.increment(1))
            case "\u{18}": return cmd(.increment(-1))
            case "\u{04}": return cmd(.scroll(.halfDown))
            case "\u{15}": return cmd(.scroll(.halfUp))
            case "\u{06}", "\u{F72D}": return cmd(.scroll(.pageDown))
            case "\u{02}", "\u{F72C}": return cmd(.scroll(.pageUp))
            case "\u{05}": return cmd(.scroll(.lineDown))
            case "\u{19}": return cmd(.scroll(.lineUp))
            case "\u{07}": return cmd(.fileInfo)
            case " " where !spaceIsMotion:
                // Space starts Vie's Space commands (Space e, Space f f: `spaceMenu`), as a
                // leader does in LazyVim. Esc cancels; a key that isn't in the menu beeps.
                var typed = ""
                for key in keys[(start + 1)...] {
                    if key.isEscape { return .invalid }
                    typed.append(key.character)
                    if let command = Self.spaceCommands[typed] { return cmd(.host(command), typed.count + 1) }
                    guard Self.spaceGroups.contains(typed) else { return .invalid }
                }
                return .incomplete
            case "\u{0C}": return cmd(.escape)
            // ⌃H goes to the file tree, as LazyVim maps it (Backspace, DEL, still moves left).
            case "\u{08}": return cmd(.focusFileTree)
            // ⇧H and ⇧L switch tabs, as LazyVim maps them; after an operator and in Visual
            // mode they're still the top and bottom lines on screen.
            case "H": return cmd(.cycleBuffer(forward: false))
            case "L": return cmd(.cycleBuffer(forward: true))
            case "\u{1B}", "\u{03}": return .invalid
            case "Z":
                guard start + 1 < keys.count else { return .incomplete }
                switch keys[start + 1].character {
                case "Z": return cmd(.writeQuit(force: false), 2)
                case "Q": return cmd(.writeQuit(force: true), 2)
                default: return .invalid
                }
            case "z":
                guard start + 1 < keys.count else { return .incomplete }
                switch keys[start + 1].character {
                case "t", "\r": return cmd(.scroll(.cursorTop), 2)
                case "z", ".": return cmd(.scroll(.cursorMiddle), 2)
                case "b", "-": return cmd(.scroll(.cursorBottom), 2)
                default: return .invalid
                }
            case "g":
                guard start + 1 < keys.count else { return .incomplete }
                switch keys[start + 1].character {
                case "v": return cmd(.reselect, 2)
                case "J": return cmd(.join(spaces: false), 2)
                case "p": return cmd(.put(before: false, cursorAfter: true), 2)
                case "P": return cmd(.put(before: true, cursorAfter: true), 2)
                case "i": return cmd(.insert(.lastInsert), 2)
                case "I": return cmd(.insert(.column0), 2)
                case "&": return cmd(.repeatSubstitute(global: true), 2)
                case "t": return cmd(.switchBuffer(next: true), 2)
                case "T": return cmd(.switchBuffer(next: false), 2)
                default: break
                }
            default: break
            }
        }

        i = start
        switch parseMotion(keys, &i) {
        case .incomplete: return .incomplete
        case .invalid: return .invalid
        case .motion(let m): return result(.motion(m), keys: Array(keys[start..<i]))
        }
    }

    enum MotionParse { case incomplete, invalid, motion(Motion) }

    func parseMotion(_ keys: [VimKey], _ i: inout Int) -> MotionParse {
        guard i < keys.count else { return .incomplete }
        let k = keys[i]
        i += 1
        func needChar(_ make: (Character) -> Motion) -> MotionParse {
            guard i < keys.count else { return .incomplete }
            let c = keys[i]
            i += 1
            if c.isEscape { return .invalid }
            return .motion(make(c.character))
        }
        switch k.character {
        case "h", "\u{F702}": return .motion(.left(wrap: false))
        case "\u{08}", "\u{7F}": return .motion(.left(wrap: true))
        case "l", "\u{F703}": return .motion(.right(wrap: false))
        case " ": return .motion(.right(wrap: true))
        case "j", "\u{F701}", "\n", "\u{0E}": return .motion(.down)
        case "k", "\u{F700}", "\u{10}": return .motion(.up)
        case "+", "\r": return .motion(.downFirstNonBlank)
        case "-": return .motion(.upFirstNonBlank)
        case "_": return .motion(.firstNonBlankCount)
        case "w": return .motion(.wordForward(big: false))
        case "W": return .motion(.wordForward(big: true))
        case "b": return .motion(.wordBackward(big: false))
        case "B": return .motion(.wordBackward(big: true))
        case "e": return .motion(.wordEnd(big: false))
        case "E": return .motion(.wordEnd(big: true))
        case "0", "\u{F729}": return .motion(.lineStart)
        case "^": return .motion(.firstNonBlank)
        case "$", "\u{F72B}": return .motion(.lineEnd)
        case "|": return .motion(.column)
        case "G": return .motion(.gotoLine(last: true))
        case "f": return needChar { .find($0, forward: true, till: false) }
        case "F": return needChar { .find($0, forward: false, till: false) }
        case "t": return needChar { .find($0, forward: true, till: true) }
        case "T": return needChar { .find($0, forward: false, till: true) }
        case ";": return .motion(.repeatFind(reverse: false))
        case ",": return .motion(.repeatFind(reverse: true))
        case "%": return .motion(.matchPair)
        case "}": return .motion(.paragraph(forward: true))
        case "{": return .motion(.paragraph(forward: false))
        case "H": return .motion(.screenTop)
        case "M": return .motion(.screenMiddle)
        case "L": return .motion(.screenBottom)
        case "n": return .motion(.searchNext(reverse: false))
        case "N": return .motion(.searchNext(reverse: true))
        case "*": return .motion(.searchWord(forward: true, whole: true))
        case "#": return .motion(.searchWord(forward: false, whole: true))
        case "/": return .motion(.searchPrompt(forward: true))
        case "?": return .motion(.searchPrompt(forward: false))
        case "`": return needChar { .mark($0, exact: true) }
        case "'": return needChar { .mark($0, exact: false) }
        case "g":
            guard i < keys.count else { return .incomplete }
            let g = keys[i].character
            i += 1
            switch g {
            case "g": return .motion(.gotoLine(last: false))
            case "e": return .motion(.wordEndBackward(big: false))
            case "E": return .motion(.wordEndBackward(big: true))
            case "_": return .motion(.lastNonBlank)
            case "j", "\u{F701}": return .motion(.down)
            case "k", "\u{F700}": return .motion(.up)
            case "0", "\u{F729}": return .motion(.lineStart)
            case "^": return .motion(.firstNonBlank)
            case "$", "\u{F72B}": return .motion(.lineEnd)
            case "*": return .motion(.searchWord(forward: true, whole: false))
            case "#": return .motion(.searchWord(forward: false, whole: false))
            case "'", "`":
                guard i < keys.count else { return .incomplete }
                let c = keys[i].character
                i += 1
                return .motion(.mark(c, exact: g == "`"))
            default: return .invalid
            }
        default:
            return .invalid
        }
    }

    func textObject(_ c: Character) -> TextObject? {
        switch c {
        case "w": .word(big: false)
        case "W": .word(big: true)
        case "p": .paragraph
        case "\"", "'", "`": .quote(c.asciiValue!)
        case "(", ")", "b": .block(open: UInt8(ascii: "("), close: UInt8(ascii: ")"))
        case "[", "]": .block(open: UInt8(ascii: "["), close: UInt8(ascii: "]"))
        case "{", "}", "B": .block(open: UInt8(ascii: "{"), close: UInt8(ascii: "}"))
        case "<", ">": .block(open: UInt8(ascii: "<"), close: UInt8(ascii: ">"))
        case "t": .tag
        default: nil
        }
    }
}
