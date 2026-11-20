import AppKit
import QuartzCore
import VieText

/// Keyboard commands (the standard Cocoa key bindings), editing, clipboard and undo.
extension EditorView {
    // MARK: - API for the app and the benchmark

    /// Types `text` at the selection, as the keyboard would.
    public func insert(_ text: String) {
        replaceSelection(with: Array(text.utf8), kind: .typing)
    }

    public func deleteBackward() { perform(command: "deleteBackward:") }

    public func moveCursor(lines delta: Int) { moveVertically(delta, extend: false) }

    public func moveCursor(toLine line: Int) {
        setSelection(Selection(rope.offset(ofLine: min(max(line, 0), rope.lineCount - 1))))
    }

    public func scroll(by dy: CGFloat) {
        scrollY += dy
        clampScroll()
        needsDisplay = true
    }

    public func scroll(toLine line: Int) {
        scrollY = CGFloat(line) * lineHeight
        clampScroll()
        needsDisplay = true
    }

    /// The duration of the most recent edit in ms, if one happened since the last call.
    public func takeLastEditMs() -> Double? {
        defer { lastEditMs = nil }
        return lastEditMs
    }

    // MARK: - Selection and scrolling helpers

    var head: Int { buffer.selection.head }

    func setSelection(_ s: Selection, keepGoal: Bool = false, reveal: Bool = true) {
        buffer.selection = s
        if !keepGoal { goalX = nil }
        if reveal { revealCursor() }
        needsDisplay = true
    }

    /// Moves the cursor to `off`, or extends the selection to it.
    func move(to off: Int, extend: Bool, keepGoal: Bool = false) {
        let s = buffer.selection
        setSelection(extend ? Selection(anchor: s.anchor, head: off) : Selection(off), keepGoal: keepGoal)
    }

    /// Scrolls just enough to show the caret.
    func revealCursor() {
        let top = CGFloat(rope.line(at: head)) * lineHeight
        if top < scrollY {
            scrollY = top
        } else if top + lineHeight > scrollY + bounds.height {
            scrollY = top + lineHeight - bounds.height
        }
        let x = caretX(), margin = charWidth * 3
        widestLine = max(widestLine, x)
        if x < scrollX + margin {
            scrollX = max(0, x - margin)
        } else if x > scrollX + textWidth - margin {
            scrollX = x - textWidth + margin
        }
        clampScroll()
        needsDisplay = true
    }

    // MARK: - Editing helpers

    /// Applies one transaction to the buffer, timing it for the benchmark and HUD.
    func applyEdit(_ changes: [Change], selection: Selection, kind: EditKind) {
        let t0 = CACurrentMediaTime()
        buffer.edit(changes, selection: selection, kind: kind)
        let ms = (CACurrentMediaTime() - t0) * 1000
        editStats.record(ms * 1000)
        lastEditMs = ms
        goalX = nil
        revealCursor()
    }

    func replaceSelection(with bytes: [UInt8], kind: EditKind) {
        let r = buffer.selection.range
        applyEdit([Change(r, bytes)], selection: Selection(r.lowerBound + bytes.count), kind: kind)
    }

    /// Deletes the selection if there is one, otherwise `range()`.
    func deleteSelection(or range: () -> Range<Int>) {
        let s = buffer.selection
        let r = s.isEmpty ? range() : s.range
        guard !r.isEmpty else { return }
        applyEdit([Change(r, [])], selection: Selection(r.lowerBound), kind: s.isEmpty ? .deleting : .other)
    }

    // MARK: - Commands

    public override func doCommand(by selector: Selector) {
        if !perform(command: NSStringFromSelector(selector)) { super.doCommand(by: selector) }
    }

    /// Runs a standard Cocoa text command such as "moveWordLeft:" (what `interpretKeyEvents`
    /// produces from the system key bindings). Returns false for commands it doesn't know.
    @discardableResult
    public func perform(command: String) -> Bool {
        let extend = command.hasSuffix("AndModifySelection:")
        let name = extend ? String(command.dropLast("AndModifySelection:".count)) + ":" : command
        let s = buffer.selection
        switch name {
        // Character and line movement
        case "moveLeft:", "moveBackward:": moveHorizontally(-1, extend: extend)
        case "moveRight:", "moveForward:": moveHorizontally(1, extend: extend)
        case "moveUp:": moveVertically(-1, extend: extend)
        case "moveDown:": moveVertically(1, extend: extend)
        case "moveWordLeft:", "moveWordBackward:":
            move(to: rope.wordStart(before: extend || s.isEmpty ? s.head : s.lowerBound), extend: extend)
        case "moveWordRight:", "moveWordForward:":
            move(to: rope.wordEnd(after: extend || s.isEmpty ? s.head : s.upperBound), extend: extend)
        case "moveToBeginningOfLine:", "moveToLeftEndOfLine:", "moveToBeginningOfParagraph:":
            move(to: rope.lineStart(containing: extend || s.isEmpty ? s.head : s.lowerBound), extend: extend)
        case "moveToEndOfLine:", "moveToRightEndOfLine:", "moveToEndOfParagraph:":
            move(to: rope.lineEnd(containing: extend || s.isEmpty ? s.head : s.upperBound), extend: extend)
        case "moveParagraphBackward:": moveParagraph(-1, extend: extend)
        case "moveParagraphForward:": moveParagraph(1, extend: extend)
        case "moveToBeginningOfDocument:": move(to: 0, extend: extend)
        case "moveToEndOfDocument:": move(to: rope.byteCount, extend: extend)
        case "pageUp:": page(-1, extend: extend)
        case "pageDown:": page(1, extend: extend)

        // Scrolling without moving the cursor
        case "scrollPageUp:": scroll(by: -pageHeight)
        case "scrollPageDown:": scroll(by: pageHeight)
        case "scrollLineUp:": scroll(by: -lineHeight)
        case "scrollLineDown:": scroll(by: lineHeight)
        case "scrollToBeginningOfDocument:": scroll(toLine: 0)
        case "scrollToEndOfDocument:": scroll(toLine: rope.lineCount)
        case "centerSelectionInVisibleArea:":
            scrollY = CGFloat(rope.line(at: s.head)) * lineHeight - (bounds.height - lineHeight) / 2
            clampScroll()
            needsDisplay = true

        // Deleting
        case "deleteBackward:": deleteSelection { rope.previousGraphemeBoundary(before: s.head)..<s.head }
        case "deleteForward:": deleteSelection { s.head..<rope.nextGraphemeBoundary(after: s.head) }
        case "deleteBackwardByDecomposingPreviousCharacter:": deleteSelection { rope.previousCharStart(s.head)..<s.head }
        case "deleteWordBackward:": deleteSelection { rope.wordStart(before: s.head)..<s.head }
        case "deleteWordForward:": deleteSelection { s.head..<rope.wordEnd(after: s.head) }
        case "deleteToBeginningOfLine:", "deleteToBeginningOfParagraph:":
            deleteSelection {
                let start = rope.lineStart(containing: s.head)
                return start < s.head ? start..<s.head : rope.previousGraphemeBoundary(before: s.head)..<s.head
            }
        case "deleteToEndOfLine:", "deleteToEndOfParagraph:":
            let end = rope.lineEnd(containing: s.head)
            let r = s.isEmpty ? (end > s.head ? s.head..<end : s.head..<min(s.head + 1, rope.byteCount)) : s.range
            if !r.isEmpty { killBuffer = rope.bytes(in: r) }
            deleteSelection { r }
        case "yank:": if !killBuffer.isEmpty { replaceSelection(with: killBuffer, kind: .other) }

        // Inserting
        case "insertNewline:", "insertNewlineIgnoringFieldEditor:", "insertParagraphSeparator:": insertNewline(indent: true)
        case "insertLineBreak:": insertNewline(indent: false)
        case "insertTab:": insertTab()
        case "insertTabIgnoringFieldEditor:": replaceSelection(with: [0x09], kind: .typing)
        case "insertBacktab:": shiftLines(right: false)

        // Selecting
        case "selectAll:": selectAll(nil)
        case "selectLine:", "selectParagraph:": setSelection(lineSelection(rope.lineRange(at: s.head)))
        case "selectWord:": setSelection(lineSelection(rope.wordRange(at: s.head)))
        case "cancelOperation:": if !s.isEmpty { setSelection(Selection(s.head)) }

        default: return false
        }
        return true
    }

    private var pageHeight: CGFloat { max(lineHeight, bounds.height - 2 * lineHeight) }

    private func lineSelection(_ r: Range<Int>) -> Selection { Selection(anchor: r.lowerBound, head: r.upperBound) }

    func moveHorizontally(_ direction: Int, extend: Bool) {
        let s = buffer.selection
        if !extend && !s.isEmpty {
            move(to: direction < 0 ? s.lowerBound : s.upperBound, extend: false)
            return
        }
        let target = direction < 0 ? rope.previousGraphemeBoundary(before: s.head) : rope.nextGraphemeBoundary(after: s.head)
        move(to: target, extend: extend)
    }

    /// Up and down keep a goal x, so the cursor returns to its column after a short line.
    /// Moving up from the first line goes to the start of the text, down from the last to its end.
    func moveVertically(_ delta: Int, extend: Bool) {
        let s = buffer.selection
        let from = extend || s.isEmpty ? s.head : (delta < 0 ? s.lowerBound : s.upperBound)
        let x = goalX ?? self.x(of: from)
        let line = rope.line(at: from) + delta
        let target = line < 0 ? 0 : line >= rope.lineCount ? rope.byteCount : offset(atX: x, line: line)
        move(to: target, extend: extend, keepGoal: true)
        goalX = x
    }

    /// ⌥↑ and ⌥↓: to the start (end) of the line, or of the previous (next) line if already there.
    private func moveParagraph(_ direction: Int, extend: Bool) {
        let h = head
        if direction < 0 {
            let start = rope.lineStart(containing: h)
            move(to: h == start && h > 0 ? rope.lineStart(containing: h - 1) : start, extend: extend)
        } else {
            let end = rope.lineEnd(containing: h)
            move(to: h == end && h < rope.byteCount ? rope.lineEnd(containing: h + 1) : end, extend: extend)
        }
    }

    private func page(_ direction: Int, extend: Bool) {
        let n = max(1, Int(bounds.height / lineHeight) - 2) * direction
        scrollY += CGFloat(n) * lineHeight
        clampScroll()
        moveVertically(n, extend: extend)
    }

    /// Newline, copying the current line's indentation (up to the cursor).
    private func insertNewline(indent: Bool) {
        var text: [UInt8] = [0x0A]
        if indent {
            let lo = buffer.selection.lowerBound
            let lineStart = rope.lineStart(containing: lo)
            text += rope.indentation(ofLineContaining: lo).prefix(lo - lineStart)
        }
        replaceSelection(with: text, kind: .typing)
    }

    /// Tab: indents the selected lines if the selection spans lines, otherwise inserts a tab
    /// or spaces up to the next tab stop.
    private func insertTab() {
        let s = buffer.selection
        if !s.isEmpty && rope.line(at: s.lowerBound) != rope.line(at: s.upperBound) {
            shiftLines(right: true)
            return
        }
        guard case .spaces(let width) = indentation else {
            replaceSelection(with: [0x09], kind: .typing)
            return
        }
        let lineStart = rope.lineStart(containing: s.lowerBound)
        let column = s.lowerBound - lineStart < 1000 ? scalarCount(rope.bytes(in: lineStart..<s.lowerBound)) : 0
        replaceSelection(with: Array(repeating: 0x20, count: width - column % width), kind: .typing)
    }

    /// Indents (or outdents) every line the selection touches by one level, as one undo step.
    func shiftLines(right: Bool) {
        let s = buffer.selection
        let firstLine = rope.line(at: s.lowerBound)
        var lastLine = rope.line(at: s.upperBound)
        if lastLine > firstLine && s.upperBound == rope.offset(ofLine: lastLine) { lastLine -= 1 }
        let unit = Array(indentation.text.utf8)
        let width = unit.count == 1 && unit[0] == 0x09 ? 4 : unit.count
        var changes: [Change] = []
        for line in firstLine...lastLine {
            let start = rope.offset(ofLine: line), end = rope.lineEnd(line)
            if right {
                if end > start { changes.append(Change(start..<start, unit)) }
            } else {
                var n = 0
                if start < end && rope.byte(at: start) == 0x09 {
                    n = 1
                } else {
                    while n < width && start + n < end && rope.byte(at: start + n) == 0x20 { n += 1 }
                }
                if n > 0 { changes.append(Change(start..<start + n, [])) }
            }
        }
        guard !changes.isEmpty else { return }
        func map(_ p: Int, isStart: Bool) -> Int {
            var delta = 0
            for c in changes {
                if c.range.upperBound < p || (c.range.upperBound == p && !(isStart && c.range.isEmpty)) {
                    delta += c.text.count - c.range.count
                } else if c.range.lowerBound < p {
                    return c.range.lowerBound + delta
                } else {
                    break
                }
            }
            return p + delta
        }
        let anchorIsStart = s.anchor <= s.head
        let newSelection = Selection(anchor: map(s.anchor, isStart: anchorIsStart), head: map(s.head, isStart: !anchorIsStart || s.isEmpty))
        buffer.breakUndoCoalescing()
        applyEdit(changes, selection: newSelection, kind: .other)
    }

    // MARK: - Menu actions

    @objc public func copy(_ sender: Any?) {
        let s = buffer.selection
        guard !s.isEmpty else { return }
        pasteboard.clearContents()
        pasteboard.setString(rope.string(in: s.range), forType: .string)
    }

    @objc public func cut(_ sender: Any?) {
        let s = buffer.selection
        guard !s.isEmpty else { return }
        copy(sender)
        buffer.breakUndoCoalescing()
        applyEdit([Change(s.range, [])], selection: Selection(s.lowerBound), kind: .other)
    }

    @objc public func paste(_ sender: Any?) {
        guard var text = pasteboard.string(forType: .string) else { return }
        if text.contains("\r") {
            text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        }
        if marked != nil { unmarkText() }
        buffer.breakUndoCoalescing()
        replaceSelection(with: Array(text.utf8), kind: .other)
    }

    public override func selectAll(_ sender: Any?) {
        setSelection(Selection(anchor: 0, head: rope.byteCount), reveal: false)
    }

    @objc public func undo(_ sender: Any?) {
        if marked != nil { unmarkText() }
        guard buffer.undo() else { return NSSound.beep() }
        goalX = nil
        revealCursor()
    }

    @objc public func redo(_ sender: Any?) {
        guard buffer.redo() else { return NSSound.beep() }
        goalX = nil
        revealCursor()
    }

    @objc public func shiftRight(_ sender: Any?) { shiftLines(right: true) }
    @objc public func shiftLeft(_ sender: Any?) { shiftLines(right: false) }

    public func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)), #selector(cut(_:)): !buffer.selection.isEmpty
        case #selector(paste(_:)): pasteboard.availableType(from: [.string]) != nil
        case #selector(undo(_:)): buffer.canUndo
        case #selector(redo(_:)): buffer.canRedo
        default: true
        }
    }

    // MARK: - Keyboard

    public override func keyDown(with event: NSEvent) {
        pendingKeyTime = event.timestamp
        NSCursor.setHiddenUntilMouseMoves(true)
        interpretKeyEvents([event])
    }
}
