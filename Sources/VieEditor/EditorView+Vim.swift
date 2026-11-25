import AppKit
import Carbon.HIToolbox
import QuartzCore
import VieSyntax
import VieText
import VieVim

/// Vim mode: the engine's host (scrolling, clipboard, file commands), key translation, and
/// keeping the engine in step when the mouse or a menu command moves the selection.
extension EditorView: VimHost {
    /// Turns Vim mode on (in Normal mode, at the cursor) or off.
    public var vimEnabled: Bool {
        get { vim != nil }
        set {
            guard newValue != (vim != nil) else { return }
            if marked != nil {
                inputContext?.discardMarkedText()
                unmarkText()
            }
            if newValue {
                let engine = VimEngine(buffer: buffer, session: vimSession)
                applyIndentation(to: engine)
                engine.options.wrap = wrapsLines
                engine.options.relativenumber = relativeLineNumbers
                engine.host = self
                engine.markdownLists = { [weak self] in self?.markdownLists(at: $0) ?? false }
                engine.commentMarker = { [weak self] in self?.syntaxLanguage?.comment }
                vim = engine
            } else if let engine = vim {
                vimRun { engine.reset() }
                buffer.removeObserver(engine)
                vim = nil
                applyTabColumns(4)
                updateSpaceHint()
            }
            goalX = nil
            revealCursor()
        }
    }

    /// Vim's indent options follow the document's indentation; tabs always display as 4 columns
    /// until `:set tabstop` changes it.
    func applyIndentation(to engine: VimEngine) {
        switch indentation {
        case .tabs:
            engine.options.expandtab = false
            engine.options.shiftwidth = engine.options.tabstop
        case .spaces(let n):
            engine.options.expandtab = true
            engine.options.shiftwidth = n
        }
    }

    /// Lays text out with tab stops every `columns` columns.
    func applyTabColumns(_ columns: Int) {
        guard columns != tabColumns else { return }
        tabColumns = columns
        paragraph = Highlighter.paragraphStyle(tabWidth: charWidth * CGFloat(columns))
        lines.removeAll()
        widestLine = 0
    }

    // MARK: - VimHost

    /// Lines fully on screen (all their rows); at least the top line.
    public var visibleLines: Range<Int> {
        let first = top.row == 0 && topOffset == 0 ? top.line : top.line + 1
        var last = first - 1
        for (pos, y) in visibleRows() where y + lineHeight <= bounds.height + 0.5 && pos.line >= first {
            if row(after: pos)?.line != pos.line { last = pos.line }
        }
        return last < first ? top.line..<top.line + 1 : first..<last + 1
    }

    public func vimScroll(toTopLine line: Int) {
        scroll(toLine: line)
    }

    public func vimReadClipboard() -> String? {
        guard let text = pasteboard.string(forType: .string) else { return nil }
        guard text.contains("\r") else { return text }
        return text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    public func vimWriteClipboard(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    public func vimBeep() { NSSound.beep() }

    public func vimPerform(_ command: VimFileCommand) -> String? {
        switch command {
        case .setFiletype(let name):
            guard let language = Self.language(forFiletype: name) else { return "Unknown filetype: \(name)" }
            chooseLanguage(language)
            return nil
        case .showFiletype:
            vim?.showMessage("  filetype=\(syntaxLanguage?.name ?? "")")
            return nil
        default:
            guard let handler = vimFileHandler else { return "E32: No file name" }
            return handler(command)
        }
    }

    /// A language by a `:set ft=` name: a grammar's name or one of its aliases ("swift",
    /// "sh", "typescriptreact"). "", "text" or "plaintext" give `.some(nil)`, plain text;
    /// an unknown name gives nil.
    static func language(forFiletype name: String) -> SyntaxLanguage?? {
        let key = name.lowercased()
        if ["", "text", "txt", "plaintext"].contains(key) { return .some(nil) }
        guard let language = SyntaxLanguage.named(key), language.name != "markdown_inline" else { return nil }
        return .some(language)
    }

    public func vimStateDidChange() {
        vimStateChanged = true
        needsDisplay = true
        if vimCallDepth == 0 { vimCatchUp() }
    }

    /// Runs an engine call: times it as an edit (for the benchmark and HUD) when it changed
    /// the text, then shows the cursor.
    func vimRun(_ body: () -> Void) {
        vimCallDepth += 1
        let version = buffer.version, t0 = CACurrentMediaTime()
        body()
        let ms = (CACurrentMediaTime() - t0) * 1000
        vimCallDepth -= 1
        if buffer.version != version {
            editStats.record(ms * 1000)
            lastEditMs = ms
        }
        if vimCallDepth == 0 { vimCatchUp() }
    }

    /// Follows the engine's state: tab stops, then scrolling to the cursor (except while a
    /// search is typed, when the engine scrolls to the match itself).
    private func vimCatchUp() {
        guard vimStateChanged, let vim else { return }
        vimStateChanged = false
        updateSpaceHint()
        applyTabColumns(vim.options.tabstop)
        if vim.options.wrap != wrapsLines { wrapsLines = vim.options.wrap }
        if vim.options.relativenumber != relativeLineNumbers { relativeLineNumbers = vim.options.relativenumber }
        goalX = nil
        if vim.mode != .commandLine { revealCursor() }
    }

    /// Leaving Insert mode switches to an ASCII-capable input source (from, say, Japanese
    /// or Russian), so Normal-mode keys are commands, not composed text.
    public func vimSwitchToASCIIInput() {
        guard let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return }
        if let p = TISGetInputSourceProperty(current, kTISPropertyInputSourceIsASCIICapable),
           CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(p).takeUnretainedValue()) {
            return
        }
        guard let ascii = TISCopyCurrentASCIICapableKeyboardInputSource()?.takeRetainedValue() else { return }
        TISSelectInputSource(ascii)
    }

    // MARK: - Input

    /// The key to send the engine for a key press, or nil to let the text system have it:
    /// text typed in Insert mode and on the command line (so input methods and dead keys
    /// work), ⌘ shortcuts, and arrows with ⌥ or ⇧ (Mac movement, which the engine then
    /// picks up as a cursor move or a Visual selection).
    func vimKey(for event: NSEvent, mode: VimMode) -> VimKey? {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let typing = mode == .insert || mode == .replace || mode == .commandLine
        let plain = flags.isDisjoint(with: [.command, .control, .option])
        switch event.keyCode {
        case UInt16(kVK_Escape): return .escape
        case UInt16(kVK_Return), UInt16(kVK_ANSI_KeypadEnter): return flags.contains(.command) ? nil : .enter
        case UInt16(kVK_Tab):
            guard plain else { return nil }
            return flags.contains(.shift) && (mode == .insert || mode == .replace) ? .backtab : .tab
        case UInt16(kVK_Delete):
            // In Insert mode ⌥⌫ deletes a word and ⌘⌫ to the start of the line, as ⌃W and ⌃U do.
            if typing && flags.contains(.option) { return .ctrl("w") }
            if typing && flags.contains(.command) { return .ctrl("u") }
            return plain ? .backspace : nil
        case UInt16(kVK_ForwardDelete): return plain ? .delete : nil
        case UInt16(kVK_LeftArrow): return plain && !flags.contains(.shift) ? .left : nil
        case UInt16(kVK_RightArrow): return plain && !flags.contains(.shift) ? .right : nil
        case UInt16(kVK_UpArrow): return plain && !flags.contains(.shift) ? .up : nil
        case UInt16(kVK_DownArrow): return plain && !flags.contains(.shift) ? .down : nil
        case UInt16(kVK_Home): return plain ? .home : nil
        case UInt16(kVK_End): return plain ? .end : nil
        case UInt16(kVK_PageUp): return plain && !typing ? .pageUp : nil
        case UInt16(kVK_PageDown): return plain && !typing ? .pageDown : nil
        default: break
        }
        if flags.contains(.command) { return nil }
        if flags.contains(.control) {
            guard !flags.contains(.option), let c = event.charactersIgnoringModifiers?.lowercased().first,
                  c.isASCII, c.isLetter || "@[\\]^_6".contains(c) else { return nil }
            return .ctrl(c == "6" ? "^" : c)
        }
        // ⌥J and ⌥K move lines in Normal and Visual mode, as LazyVim maps them (in Insert mode
        // they still type ∆ and ˚).
        if flags == [.option], !typing, let c = event.charactersIgnoringModifiers?.lowercased() {
            if c == "j" { return .altJ }
            if c == "k" { return .altK }
        }
        // Normal and Visual mode take the character the key types on the current layout, so
        // commands work whatever the input source.
        guard !typing, let chars = event.characters, chars.count == 1, let c = chars.first else { return nil }
        let v = c.unicodeScalars.first!.value
        return v >= 0x20 && !(0xF700...0xF8FF).contains(v) ? VimKey(c) : nil
    }

    /// Text from the input method, a paste or a finished composition. `replacing` is a range
    /// the accent menu replaces (the character typed before it).
    func vimInsert(_ text: String, replacing: Range<Int>?, _ vim: VimEngine) {
        vimRun {
            if let r = replacing, !r.isEmpty, r.upperBound == vim.cursor, vim.mode == .insert || vim.mode == .replace {
                for _ in 0..<rope.string(in: r).count { vim.handle(.backspace) }
            }
            vim.insertText(text)
        }
    }

    /// ⌘V in Insert mode or on the command line types the text, so it's part of the insert
    /// (and of `.`). Returns false when the view should paste as usual.
    func vimPaste(_ text: String) -> Bool {
        guard let vim else { return false }
        switch vim.mode {
        case .insert, .replace:
            vimRun { vim.insertText(text) }
        case .commandLine:
            vimRun { vim.insertText(String(text.prefix { $0 != "\n" })) }
        default:
            return false
        }
        return true
    }

    /// After the mouse or a Mac command moved the selection, the engine takes it: a cursor
    /// move, or Visual mode for a selection (leaving Insert mode first).
    func vimSelectionChanged() {
        guard let vim else { return }
        let s = buffer.selection
        vimRun {
            if !s.isEmpty && (vim.mode == .insert || vim.mode == .replace) {
                vim.handle(.escape)
                buffer.selection = s
            }
            vim.syncFromBuffer()
        }
    }
}
