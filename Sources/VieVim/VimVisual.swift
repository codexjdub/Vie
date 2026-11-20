import VieText

extension VimEngine {
    // MARK: - Entering and leaving

    func enterVisual(_ m: VimMode) {
        if mode == m {
            endVisual()
            return
        }
        if !mode.isVisual { visualAnchor = cursor }
        mode = m
        syncSelection()
    }

    /// Back to Normal mode, remembering the area for `gv` and the `'<` `'>` marks.
    func endVisual() {
        guard mode.isVisual else { return }
        lastVisual = (mode, visualAnchor, cursor, curswant)
        let a = pos(visualAnchor), c = cursorPos
        var s = min(a, c), e = max(a, c)
        if mode == .visualLine {
            s.col = 0
            e.col = max(lineLength(e.line) - 1, 0)
        }
        marks["<"] = offset(s)
        marks[">"] = offset(e)
        mode = .normal
        cursor = clampNormal(cursor)
        syncSelection()
    }

    func reselectVisual() {
        guard let lv = lastVisual else { return beep() }
        if mode.isVisual {
            let current = (mode, visualAnchor, cursor, curswant)
            lastVisual = current
        }
        mode = lv.mode
        visualAnchor = min(lv.anchor, rope.byteCount)
        cursor = min(lv.cursor, rope.byteCount)
        curswant = lv.curswant
        syncSelection()
    }

    /// The buffer selection that shows the Visual area.
    func visualSelection() -> Selection {
        let a = pos(visualAnchor), c = cursorPos
        switch mode {
        case .visualLine:
            let first = min(a.line, c.line), last = max(a.line, c.line)
            let s = lineStart(first)
            let e = last < lastLine ? lineStart(last + 1) : rope.byteCount
            return c.line >= a.line ? Selection(anchor: s, head: e) : Selection(anchor: e, head: s)
        case .visualBlock:
            return Selection(cursor)
        default:
            func after(_ p: Pos) -> Int {
                let b = text(p.line)
                if p.col < b.count { return offset(p) + nextCharCol(b, p.col) - p.col }
                return min(offset(p) + 1, rope.byteCount)
            }
            if c >= a { return Selection(anchor: offset(a), head: after(c)) }
            return Selection(anchor: after(a), head: offset(c))
        }
    }

    /// Left and right display columns of the block, both included.
    func blockBounds() -> (top: Int, bottom: Int, left: Int, right: Int, toEOL: Bool) {
        let a = pos(visualAnchor), c = cursorPos
        func span(_ p: Pos) -> (Int, Int) {
            let b = text(p.line)
            let v = vcolOf(b, p.col, tabstop: options.tabstop)
            return (v, v + cellsAt(b, p.col, vcol: v, tabstop: options.tabstop) - 1)
        }
        let sa = span(a), sc = span(c)
        return (min(a.line, c.line), max(a.line, c.line), min(sa.0, sc.0), max(sa.1, sc.1), curswant == .max)
    }

    func blockCols(_ line: Int, _ b: (top: Int, bottom: Int, left: Int, right: Int, toEOL: Bool)) -> Range<Int> {
        blockCols(line, (b.left, b.right, b.toEOL))
    }

    /// The Visual area as an operator range.
    func visualRange(linewise: Bool = false) -> OpRange {
        let a = pos(visualAnchor), c = cursorPos
        var s = min(a, c), e = max(a, c)
        if linewise || mode == .visualLine {
            s.col = mode == .visualLine || linewise ? 0 : s.col
            var r = OpRange(start: s, end: e, kind: .line, inclusive: true)
            r.isVisual = true
            return r
        }
        if mode == .visualBlock {
            let b = blockBounds()
            var r = OpRange(start: Pos(b.top, 0), end: Pos(b.bottom, 0), kind: .block, inclusive: true)
            r.leftVcol = b.left
            r.rightVcol = b.right
            r.toEOL = b.toEOL
            r.isVisual = true
            return r
        }
        var r = OpRange(start: s, end: e, kind: .char, inclusive: true)
        r.isVisual = true
        if e.col >= lineLength(e.line) {
            // On the end of a line: include the line break, unless it's the last line.
            r.inclusive = false
            if e.line < lastLine { r.end = Pos(e.line + 1, 0) }
        }
        return r
    }

    /// The size of the Visual area, for `.`.
    func visualRepeat() -> VisualRepeat {
        let a = pos(visualAnchor), c = cursorPos
        let s = min(a, c), e = max(a, c)
        switch mode {
        case .visualLine:
            return VisualRepeat(mode: mode, lines: e.line - s.line + 1, cols: 0, toEnd: false)
        case .visualBlock:
            let b = blockBounds()
            return VisualRepeat(mode: mode, lines: b.bottom - b.top + 1, cols: b.right - b.left + 1, toEnd: b.toEOL)
        default:
            if s.line == e.line {
                var n = 0, col = s.col
                let t = text(s.line)
                while col <= e.col && col < t.count { col = nextCharCol(t, col); n += 1 }
                return VisualRepeat(mode: .visual, lines: 1, cols: max(n, 1), toEnd: false)
            }
            return VisualRepeat(mode: .visual, lines: e.line - s.line + 1, cols: e.col, toEnd: false)
        }
    }

    /// Selects an area the size of `v` at the cursor, for `.` after a Visual change.
    func selectForRepeat(_ v: VisualRepeat) {
        let p = cursorPos
        visualAnchor = cursor
        mode = v.mode
        let line = min(p.line + v.lines - 1, lastLine)
        switch v.mode {
        case .visualLine:
            cursor = offset(Pos(line, p.col))
        case .visualBlock:
            let start = vcolOf(text(p.line), p.col, tabstop: options.tabstop)
            curswant = v.toEnd ? .max : start + v.cols - 1
            cursor = offset(Pos(line, colFor(line, vcol: curswant)))
        default:
            if v.lines == 1 {
                let b = text(p.line)
                var col = p.col
                for _ in 1..<max(v.cols, 1) where col < b.count { col = nextCharCol(b, col) }
                cursor = offset(Pos(p.line, min(col, b.count)))
            } else {
                cursor = offset(Pos(line, min(v.cols, lineLength(line))))
            }
        }
        syncSelection()
    }

    // MARK: - Commands

    func runVisualCommand(_ cmd: Command, _ c: ParsedCommand) {
        switch cmd {
        case .visualSwap(let horizontal):
            if horizontal {
                let a = pos(visualAnchor), p = cursorPos
                let va = vcolOf(text(a.line), a.col, tabstop: options.tabstop)
                let vc = vcolOf(text(p.line), p.col, tabstop: options.tabstop)
                visualAnchor = offset(Pos(a.line, colFor(a.line, vcol: vc)))
                cursor = offset(Pos(p.line, colFor(p.line, vcol: va)))
            } else {
                swap(&visualAnchor, &cursor)
            }
            updateCurswant()
            syncSelection()
        case .visualOperator(let op):
            let r = visualRange()
            endVisual()
            if op == .change && r.kind == .block {
                blockChange(r, register: c.register)
            } else {
                applyOperator(op, r, register: c.register, count: c.count)
            }
        case .visualLineOperator(let op):
            var r: OpRange
            if mode == .visualBlock && (op == .delete || op == .change) && c.keys.first?.character != "X" && c.keys.first?.character != "S" && c.keys.first?.character != "R" {
                r = visualRange()
                r.toEOL = true
            } else {
                r = visualRange(linewise: true)
            }
            endVisual()
            if op == .change && r.kind == .block {
                blockChange(r, register: c.register)
            } else {
                applyOperator(op, r, register: c.register, count: c.count)
            }
        case .visualReplace(let ch):
            let r = visualRange()
            endVisual()
            visualReplace(r, with: ch)
        case .visualJoin(let spaces):
            let r = visualRange()
            endVisual()
            let count = max(r.end.line - r.start.line + 1, 2)
            if r.start.line + count - 1 > lastLine { return beep() }
            cursor = offset(Pos(r.start.line, 0))
            join(first: r.start.line, count: count, spaces: spaces)
        case .visualPut(let before):
            visualPut(register: c.register, keepRegisters: before, count: c.count1)
        case .visualInsert(let append):
            visualInsert(append: append)
        default:
            break
        }
    }

    func visualReplace(_ r: OpRange, with ch: Character) {
        let one = Array(String(ch).utf8)
        var changes: [Change] = []
        func replaceChars(_ range: Range<Int>) {
            let bytes = rope.bytes(in: range)
            var out: [UInt8] = []
            var i = 0
            while i < bytes.count {
                if bytes[i] == 0x0A { out.append(0x0A); i += 1; continue }
                let lineEnd = bytes[i...].firstIndex(of: 0x0A) ?? bytes.count
                let piece = Array(bytes[i..<lineEnd])
                var k = 0
                while k < piece.count { k = nextCharCol(piece, k); out += one }
                i = lineEnd
            }
            if out != bytes { changes.append(Change(range, out)) }
        }
        switch r.kind {
        case .char: replaceChars(charRange(r))
        case .line: replaceChars(lineStart(r.start.line)..<rope.lineEnd(r.end.line))
        case .block:
            for line in r.start.line...r.end.line {
                let cols = blockCols(line, r)
                replaceChars((lineStart(line) + cols.lowerBound)..<(lineStart(line) + cols.upperBound))
            }
        }
        var p = r.start
        if r.kind == .block { p.col = blockCols(r.start.line, r).lowerBound }
        change(at: offset(p)) {
            if !changes.isEmpty { edit(changes, cursor: offset(p)) }
        }
        cursor = clampNormal(offset(p))
        updateCurswant()
        syncSelection()
    }

    /// Visual `p` and `P`: the put text replaces the selection. `P` leaves the registers
    /// alone; `p` puts the replaced text in them, as a delete would.
    func visualPut(register name: Character?, keepRegisters: Bool, count: Int) {
        let wasMode = mode
        guard let saved = register(named: name) else {
            endVisual()
            return fail("E353: Nothing in register \(name ?? "\"")")
        }
        let r = visualRange()
        endVisual()
        buffer.selection = Selection(offset(r.start))
        buffer.beginUndoGroup()
        defer { buffer.endUndoGroup() }
        let wasWhole = r.kind == .line && r.start.line == 0 && r.end.line == lastLine
        applyOperator(.delete, r, register: keepRegisters ? "_" : nil, count: nil)
        // Put what the register held before the delete overwrote it.
        let temp: Character = "\u{1}"
        registers.setRaw(temp, saved)
        let opStart = r.kind == .line ? Pos(r.start.line, 0) : r.start
        var before = true
        let p = cursorPos
        if wasMode != .visualLine && p.col < opStart.col { before = false }
        if wasMode == .visualLine && p.line < opStart.line { before = false }
        if wasMode != .visualLine && saved.kind == .linewise {
            // Put the lines in a line break at the deletion point.
            let at = offset(opStart)
            let insertText = Array(("\n" + saved.text).utf8)
            replace(at..<at, with: insertText, cursor: at + 1)
            let line = pos(at + 1).line
            cursor = lineStart(line) + firstNonBlank(line)
        } else {
            put(temp, before: before, cursorAfter: false, count: count, forceLinewise: wasMode == .visualLine)
        }
        registers.removeRaw(temp)
        if wasWhole && lastLine > 0 && isEmptyLine(lastLine) {
            let e = rope.byteCount
            replace((e - 1)..<e, with: [], cursor: min(cursor, e - 1))
            cursor = clampNormal(cursor)
        }
        updateCurswant()
        syncSelection()
    }

    func visualInsert(append: Bool) {
        let r = visualRange()
        if mode == .visualBlock {
            endVisual()
            let line = r.start.line
            let b = text(line)
            var col: Int
            var vcol: Int
            if append {
                if r.toEOL {
                    col = b.count
                    vcol = displayWidth(b, tabstop: options.tabstop)
                } else {
                    vcol = r.rightVcol + 1
                    let cols = blockCols(line, r)
                    col = cols.upperBound
                    let w = displayWidth(b, tabstop: options.tabstop)
                    if w < vcol {
                        // Pad a short first line out to the block's edge.
                        let pad = [UInt8](repeating: 0x20, count: vcol - w)
                        buffer.selection = Selection(lineStart(line) + col)
                        buffer.beginUndoGroup()
                        replace((lineStart(line) + b.count)..<(lineStart(line) + b.count), with: pad, cursor: lineStart(line) + b.count + pad.count)
                        col = b.count + pad.count
                        startBlockInsert(r, col: col, vcol: vcol, append: true, undoBegun: true)
                        return
                    }
                }
            } else {
                vcol = r.leftVcol
                col = blockCols(line, r).lowerBound
            }
            cursor = lineStart(line) + col
            startBlockInsert(r, col: col, vcol: vcol, append: append, undoBegun: false)
            return
        }
        let linewise = mode == .visualLine
        endVisual()
        if append {
            if linewise {
                cursor = rope.lineEnd(r.end.line)
            } else {
                let e = charRange(r).upperBound
                cursor = min(e, rope.lineEnd(pos(max(e - 1, 0)).line))
            }
        } else {
            cursor = linewise ? lineStart(r.start.line) + indentOf(text(r.start.line), tabstop: options.tabstop).bytes : offset(r.start)
        }
        beginInsert(append ? .after : .before, count: 1, undoBegun: false)
    }

    private func startBlockInsert(_ r: OpRange, col: Int, vcol: Int, append: Bool, undoBegun: Bool) {
        beginInsert(append ? .after : .before, count: 1, undoBegun: undoBegun)
        insert?.block = BlockInsert(firstLine: r.start.line, lastLine: r.end.line, vcol: vcol, append: append,
                                    toEOL: append && r.toEOL, startCol: col, lineLength: lineLength(r.start.line),
                                    lineCount: rope.lineCount)
    }

    func blockChange(_ r: OpRange, register: Character?) {
        opChange(r, register: register)
    }

    // MARK: - Text objects in Visual mode

    func visualSelectObject(_ obj: TextObject, inner: Bool, _ c: ParsedCommand) {
        let single = visualAnchor == cursor
        var count = c.count1
        let a = pos(visualAnchor), p = cursorPos
        let selStart = min(a, p), selEnd = max(a, p)
        for _ in 0..<4 {
            guard let r0 = textObjectRange(obj, inner: inner, count: count, from: single ? p : selStart) else { return beep() }
            var r = r0
            if r.end < r.start { swap(&r.start, &r.end) }
            if r.kind == .char && !r.inclusive {
                // Visual areas are inclusive: end on the character before.
                if r.end > r.start {
                    var e = r.end
                    _ = dec(&e)
                    r.end = e
                } else if r.end == r.start {
                    return beep()
                }
            }
            let grows = r.start < selStart || r.end > selEnd
            if single || grows {
                if r.kind == .line {
                    mode = .visualLine
                } else if mode == .visualLine {
                    mode = .visual
                }
                visualAnchor = offset(r.start)
                cursor = offset(r.end)
                updateCurswant()
                syncSelection()
                return
            }
            count += 1
        }
        beep()
    }
}

extension Registers {
    /// Stores a register without touching `""` (for temporary use).
    mutating func setRaw(_ name: Character, _ r: Register) {
        let keep = unnamed
        set(name, r)
        restoreUnnamed(keep)
    }

    mutating func removeRaw(_ name: Character) {
        let keep = unnamed
        clear(name)
        restoreUnnamed(keep)
    }
}
