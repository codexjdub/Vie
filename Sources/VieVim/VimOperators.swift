import VieText

extension VimEngine {
    // MARK: - Operator entry points

    func operatorWithMotion(_ op: Operator, _ m: Motion, _ c: ParsedCommand) {
        if case .searchPrompt(let forward) = m {
            let pendingOp = PendingOperator(op: op, register: c.register, count: c.count, start: cursor)
            startCommandLine(forward ? "/" : "?", pendingOp: pendingOp, count: nil)
            return
        }
        let start = cursorPos
        guard let r = evaluate(m, count: c.count, from: start, op: op) else { return beep() }
        if r.jump { marks["'"] = cursor }
        applyMotionOperator(op, from: start, r, register: c.register, count: c.count)
    }

    func applyMotionOperator(_ op: Operator, from start: Pos, _ r: MotionResult, register: Character?, count: Int?) {
        var a = start, b = r.pos
        if b < a { swap(&a, &b) }
        var range = OpRange(start: a, end: b, kind: r.kind == .linewise ? .line : .char, inclusive: r.kind == .inclusive,
                            useRegOne: r.useRegOne)
        if !r.noAdjust { adjustExclusiveEnd(&range) }
        applyOperator(op, range, register: register, count: count)
    }

    func operatorWithObject(_ op: Operator, _ obj: TextObject, inner: Bool, _ c: ParsedCommand) {
        guard var r = textObjectRange(obj, inner: inner, count: c.count1, from: cursorPos) else { return beep() }
        if r.end < r.start { swap(&r.start, &r.end) }
        adjustExclusiveEnd(&r)
        applyOperator(op, r, register: c.register, count: c.count)
    }

    /// `dd`, `cc`, `yy`, `>>`, `g~~` and friends: count lines from the cursor.
    func operatorDoubled(_ op: Operator, _ c: ParsedCommand) {
        let p = cursorPos
        let n = c.count1
        if n > 1 && p.line >= lastLine { return beep() }
        let line = min(p.line + n - 1, lastLine)
        let col: Int
        switch op {
        case .delete, .shiftLeft, .shiftRight: col = startOfLineCol(line)
        case .yank: col = colFor(line, vcol: curswant)
        default: col = firstNonBlank(line)
        }
        var a = p, b = Pos(line, col)
        if b < a { swap(&a, &b) }
        applyOperator(op, OpRange(start: a, end: b, kind: .line, inclusive: true), register: c.register, count: c.count)
    }

    func applyOperator(_ op: Operator, _ r: OpRange, register: Character?, count: Int?) {
        if let reg = register, [.delete, .change, .yank].contains(op), !Registers.isWritable(reg) {
            return beep()
        }
        switch op {
        case .delete: opDelete(r, register: register)
        case .yank: opYank(r, register: register)
        case .change: opChange(r, register: register)
        case .shiftRight, .shiftLeft: opShift(r, left: op == .shiftLeft, amount: r.isVisual ? max(count ?? 1, 1) : 1)
        case .reindent: opReindent(r)
        case .toggleCase: opCase(r, .toggle)
        case .lowerCase: opCase(r, .lower)
        case .upperCase: opCase(r, .upper)
        }
        updateCurswant()
        syncSelection()
    }

    // MARK: - Ranges as bytes

    func charLen(_ p: Pos) -> Int {
        let b = text(p.line)
        return p.col < b.count ? nextCharCol(b, p.col) - p.col : 0
    }

    func charRange(_ r: OpRange) -> Range<Int> {
        let s = offset(r.start)
        let e = offset(r.end) + (r.inclusive ? charLen(r.end) : 0)
        return s..<max(s, e)
    }

    /// Whole lines, including the line break after them (or before them at the end).
    func lineRange(_ first: Int, _ last: Int, forDeletion: Bool) -> Range<Int> {
        let s = lineStart(first)
        if last < lastLine { return s..<lineStart(last + 1) }
        if forDeletion && first > 0 { return (s - 1)..<rope.byteCount }
        return s..<rope.byteCount
    }

    /// Byte columns of `line` inside a block (characters overlapping its cells).
    func blockCols(_ line: Int, _ r: (left: Int, right: Int, toEOL: Bool)) -> Range<Int> {
        let b = text(line)
        var v = 0, i = 0
        var start: Int?
        var end = b.count
        while i < b.count {
            let w = cellsAt(b, i, vcol: v, tabstop: options.tabstop)
            let n = nextCharCol(b, i)
            if start == nil && v + w > r.left { start = i }
            if !r.toEOL && v > r.right { end = i; break }
            v += w
            i = n
        }
        let s = start ?? b.count
        return s..<max(s, end)
    }

    func blockCols(_ line: Int, _ r: OpRange) -> Range<Int> {
        blockCols(line, (r.leftVcol, r.rightVcol, r.toEOL))
    }

    func registerContent(_ r: OpRange) -> Register {
        switch r.kind {
        case .char:
            return Register(text: rope.string(in: charRange(r)), kind: .charwise)
        case .line:
            return Register(text: rope.string(in: lineStart(r.start.line)..<rope.lineEnd(r.end.line)) + "\n", kind: .linewise)
        case .block:
            var parts: [String] = []
            var width = r.rightVcol - r.leftVcol + 1
            for line in r.start.line...r.end.line {
                let cols = blockCols(line, r)
                let b = text(line)
                parts.append(String(decoding: b[cols], as: UTF8.self))
                if r.toEOL { width = max(width, vcolOf(b, cols.upperBound, tabstop: options.tabstop) - r.leftVcol) }
            }
            return Register(text: parts.joined(separator: "\n"), kind: .blockwise(width: max(width, 0)))
        }
    }

    // MARK: - Registers

    func register(named name: Character?) -> Register? {
        let n = name ?? "\""
        switch n {
        case "\"":
            let u = registers.unnamed
            return u == "+" || u == "*" ? clipboardRegister(u) : registers.get(u)
        case "+", "*": return clipboardRegister(n)
        case ".": return lastInserted.isEmpty ? nil : Register(text: lastInserted, kind: .charwise)
        case ":": return lastCommandLine.isEmpty ? nil : Register(text: lastCommandLine, kind: .charwise)
        case "/": return lastSearch.map { Register(text: $0.pattern, kind: .charwise) }
        case "_": return nil
        default: return registers.get(n)
        }
    }

    private func clipboardRegister(_ name: Character) -> Register? {
        let stored = registers.get(name)
        guard let text = host?.vimReadClipboard() else { return stored }
        if let stored, stored.text == text { return stored }
        return Register(text: text, kind: text.hasSuffix("\n") ? .linewise : .charwise)
    }

    func storeYank(_ r: Register, _ name: Character?) {
        if name == "+" || name == "*" { host?.vimWriteClipboard(r.text) }
        registers.yank(r, into: name)
    }

    func storeDelete(_ r: Register, _ name: Character?, multiLine: Bool, useRegOne: Bool) {
        if name == "+" || name == "*" { host?.vimWriteClipboard(r.text) }
        registers.delete(r, into: name, multiLine: multiLine, useRegOne: useRegOne)
    }

    // MARK: - d y c

    func opDelete(_ r0: OpRange, register: Character?) {
        var r = r0
        // Vi: a multi-line character-wise delete that ends at trailing blanks and starts in
        // the indent deletes whole lines.
        if r.kind == .char && !r.isVisual && r.end.line > r.start.line {
            let b = text(r.end.line)
            var c = r.end.col
            if c < b.count && r.inclusive { c = nextCharCol(b, c) }
            while c < b.count && isBlank(b[c]) { c += 1 }
            if c >= b.count && inIndent(r.start) { r.kind = .line }
        }
        if r.kind == .char && charRange(r).isEmpty { return }
        if register != "_" {
            storeDelete(registerContent(r), register, multiLine: r.end.line > r.start.line, useRegOne: r.useRegOne)
        }
        switch r.kind {
        case .line:
            let count = r.end.line - r.start.line + 1
            let range = lineRange(r.start.line, r.end.line, forDeletion: true)
            change(at: offset(r.start)) {
                replace(range, with: [], cursor: range.lowerBound)
            }
            let line = min(r.start.line, lastLine)
            cursor = lineStart(line) + firstNonBlank(line)
            setChangeMarks(lineStart(line), lineStart(line))
            if count > 2 { show("\(count) fewer lines") }
        case .char:
            let range = charRange(r)
            change(at: range.lowerBound) {
                replace(range, with: [], cursor: range.lowerBound)
            }
            setChangeMarks(range.lowerBound, range.lowerBound)
            cursor = clampNormal(cursor)
        case .block:
            var changes: [Change] = []
            for line in r.start.line...r.end.line {
                let cols = blockCols(line, r)
                if !cols.isEmpty { changes.append(Change((lineStart(line) + cols.lowerBound)..<(lineStart(line) + cols.upperBound), [])) }
            }
            let top = Pos(r.start.line, blockCols(r.start.line, r).lowerBound)
            change(at: offset(top)) {
                edit(changes, cursor: offset(top))
            }
            cursor = clampNormal(offset(top))
        }
    }

    /// Sets the `[` and `]` marks (start and end of the last changed or yanked text).
    func setChangeMarks(_ start: Int, _ end: Int) {
        marks["["] = min(start, rope.byteCount)
        marks["]"] = min(max(end, start), rope.byteCount)
    }

    /// Offset of the last character of a range (its start when empty).
    func lastChar(_ range: Range<Int>) -> Int {
        range.isEmpty ? range.lowerBound : rope.previousGraphemeBoundary(before: range.upperBound)
    }

    func opYank(_ r: OpRange, register: Character?) {
        let content = registerContent(r)
        storeYank(content, register)
        switch r.kind {
        case .char: setChangeMarks(offset(r.start), lastChar(charRange(r)))
        case .line: setChangeMarks(lineStart(r.start.line), lastChar(lineStart(r.end.line)..<rope.lineEnd(r.end.line)))
        case .block:
            let e = blockCols(r.end.line, r)
            setChangeMarks(lineStart(r.start.line) + blockCols(r.start.line, r).lowerBound, lineStart(r.end.line) + max(e.upperBound - 1, e.lowerBound))
        }
        var p = r.start
        if r.kind == .block { p.col = blockCols(r.start.line, r).lowerBound }
        cursor = clampNormal(offset(p))
        let lines = r.end.line - r.start.line + 1
        if lines > 2 { show(r.kind == .block ? "block of \(lines) lines yanked" : "\(lines) lines yanked") }
    }

    func opChange(_ r: OpRange, register: Character?) {
        if register != "_" {
            storeDelete(registerContent(r), register, multiLine: r.end.line > r.start.line, useRegOne: r.useRegOne)
        }
        var autoIndentLine: Int?
        var block: BlockInsert?
        setCursor(offset(r.start))
        buffer.beginUndoGroup()
        switch r.kind {
        case .line:
            let first = r.start.line
            let keep = options.autoindent ? indentOf(text(first), tabstop: options.tabstop).bytes : 0
            let s = lineStart(first) + keep
            replace(s..<rope.lineEnd(r.end.line), with: [], cursor: s)
            if options.autoindent { autoIndentLine = first }
        case .char:
            let range = charRange(r)
            replace(range, with: [], cursor: range.lowerBound)
        case .block:
            var changes: [Change] = []
            for line in r.start.line...r.end.line {
                let cols = blockCols(line, r)
                if !cols.isEmpty { changes.append(Change((lineStart(line) + cols.lowerBound)..<(lineStart(line) + cols.upperBound), [])) }
            }
            let topCol = blockCols(r.start.line, r).lowerBound
            edit(changes, cursor: lineStart(r.start.line) + topCol)
            block = BlockInsert(firstLine: r.start.line, lastLine: r.end.line, vcol: r.leftVcol, append: false, toEOL: false,
                                startCol: topCol, lineLength: lineLength(r.start.line), lineCount: rope.lineCount)
        }
        beginInsert(.change, count: 1, undoBegun: true)
        insert?.autoIndentLine = autoIndentLine
        insert?.block = block
    }

    // MARK: - > < =

    func opShift(_ r: OpRange, left: Bool, amount: Int) {
        let sw = options.shiftwidth
        var changes: [Change] = []
        for line in r.start.line...r.end.line {
            let b = text(line)
            if b.isEmpty { continue }
            let ind = indentOf(b, tabstop: options.tabstop)
            let width = left ? max(0, ind.width - sw * amount) : ind.width + sw * amount
            let new = indentText(width: width, options: options)
            if new != Array(b[0..<ind.bytes]) {
                changes.append(Change(lineStart(line)..<(lineStart(line) + ind.bytes), new))
            }
        }
        let first = r.start.line
        change(at: offset(r.start)) {
            if !changes.isEmpty { edit(changes, cursor: lineStart(first)) }
        }
        cursor = lineStart(first) + startOfLineCol(first)
        let lines = r.end.line - first + 1
        if lines > 2 { show("\(lines) lines \(left ? "<" : ">")ed \(amount) time\(amount == 1 ? "" : "s")") }
    }

    /// `=`: a simple indenter. Each line gets the indent of the line above, one level more
    /// after a line ending in an opening bracket and one less for a line starting with a
    /// closing one.
    func opReindent(_ r: OpRange) {
        let sw = options.shiftwidth
        var changes: [Change] = []
        var prev: (width: Int, opens: Bool)?
        var l = r.start.line - 1
        while l >= 0 {
            let b = text(l)
            if !lineWhite(l) {
                prev = (indentOf(b, tabstop: options.tabstop).width, endsWithOpener(b))
                break
            }
            l -= 1
        }
        for line in r.start.line...r.end.line {
            let b = text(line)
            if lineWhite(line) {
                if !b.isEmpty { changes.append(Change(lineStart(line)..<(lineStart(line) + b.count), [])) }
                continue
            }
            let ind = indentOf(b, tabstop: options.tabstop)
            var width = prev.map { $0.width + ($0.opens ? sw : 0) } ?? 0
            if ind.bytes < b.count, [UInt8(ascii: "}"), UInt8(ascii: ")"), UInt8(ascii: "]")].contains(b[ind.bytes]) {
                width = max(0, width - sw)
            }
            let new = indentText(width: width, options: options)
            if new != Array(b[0..<ind.bytes]) { changes.append(Change(lineStart(line)..<(lineStart(line) + ind.bytes), new)) }
            prev = (width, endsWithOpener(b))
        }
        let first = r.start.line
        change(at: offset(r.start)) {
            if !changes.isEmpty { edit(changes, cursor: lineStart(first)) }
        }
        cursor = lineStart(first) + startOfLineCol(first)
        let lines = r.end.line - first + 1
        if lines > 2 { show("\(lines) lines indented ") }
    }

    private func endsWithOpener(_ b: [UInt8]) -> Bool {
        var i = b.count
        while i > 0 && isBlank(b[i - 1]) { i -= 1 }
        guard i > 0 else { return false }
        return [UInt8(ascii: "{"), UInt8(ascii: "("), UInt8(ascii: "[")].contains(b[i - 1])
    }

    // MARK: - ~ g~ gu gU

    func opCase(_ r: OpRange, _ how: CaseChange) {
        var ranges: [Range<Int>] = []
        switch r.kind {
        case .char: ranges = [charRange(r)]
        case .line: ranges = [lineStart(r.start.line)..<rope.lineEnd(r.end.line)]
        case .block:
            for line in r.start.line...r.end.line {
                let cols = blockCols(line, r)
                ranges.append((lineStart(line) + cols.lowerBound)..<(lineStart(line) + cols.upperBound))
            }
        }
        var changes: [Change] = []
        for range in ranges where !range.isEmpty {
            let old = rope.bytes(in: range)
            let new = changeCase(old, how)
            if new != old { changes.append(Change(range, new)) }
        }
        var p = r.start
        if r.kind == .block { p.col = blockCols(r.start.line, r).lowerBound }
        change(at: offset(p)) {
            if !changes.isEmpty { edit(changes, cursor: offset(p)) }
        }
        cursor = clampNormal(offset(p))
    }

    // MARK: - p P gp gP

    /// Puts register `name` before or after the cursor `count` times. `forceLinewise` puts
    /// character-wise text as lines (after a line-wise Visual delete).
    @discardableResult
    func put(_ name: Character?, before: Bool, cursorAfter: Bool, count: Int, forceLinewise: Bool = false) -> Bool {
        guard var reg = register(named: name), !reg.text.isEmpty else {
            fail("E353: Nothing in register \(name ?? "\"")")
            return false
        }
        if forceLinewise && reg.kind != .linewise {
            reg = Register(text: reg.text.hasSuffix("\n") ? reg.text : reg.text + "\n", kind: .linewise)
        }
        let p = cursorPos
        switch reg.kind {
        case .charwise:
            let b = text(p.line)
            var col = p.col
            if !before && col < b.count { col = nextCharCol(b, col) }
            let at = lineStart(p.line) + col
            let one = Array(reg.text.utf8)
            var ins: [UInt8] = []
            ins.reserveCapacity(one.count * count)
            for _ in 0..<count { ins += one }
            change(at: cursor) {
                replace(at..<at, with: ins, cursor: at)
            }
            setChangeMarks(at, lastChar(at..<(at + ins.count)))
            if cursorAfter {
                cursor = clampNormal(at + ins.count)
            } else if ins.contains(0x0A) {
                cursor = at
            } else {
                cursor = at + prevCharCol(ins, ins.count)
            }
        case .linewise:
            var lines: [UInt8] = []
            let one = Array(reg.text.utf8)
            for _ in 0..<count { lines += one }
            let first: Int
            let at: Int
            var ins = lines
            if before {
                at = lineStart(p.line)
                first = p.line
            } else if p.line < lastLine {
                at = lineStart(p.line + 1)
                first = p.line + 1
            } else {
                at = rope.byteCount
                first = p.line + 1
                ins = [0x0A] + lines.dropLast()
            }
            let added = lines.filter { $0 == 0x0A }.count
            change(at: cursor) {
                replace(at..<at, with: ins, cursor: at)
            }
            let lastPut = min(first + added - 1, lastLine)
            setChangeMarks(lineStart(first), lastChar(lineStart(lastPut)..<rope.lineEnd(lastPut)))
            if cursorAfter {
                let line = min(first + added, lastLine)
                cursor = lineStart(line)
            } else {
                cursor = lineStart(first) + firstNonBlank(first)
            }
            if added > 2 { show("\(added) more lines") }
        case .blockwise(let width):
            putBlock(reg, width: width, before: before, count: count, cursorAfter: cursorAfter)
        }
        updateCurswant()
        syncSelection()
        return true
    }

    private func putBlock(_ reg: Register, width: Int, before: Bool, count: Int, cursorAfter: Bool) {
        let p = cursorPos
        let b = text(p.line)
        var vcol = vcolOf(b, p.col, tabstop: options.tabstop)
        if !before && p.col < b.count { vcol += cellsAt(b, p.col, vcol: vcol, tabstop: options.tabstop) }
        var changes: [Change] = []
        var firstCol = 0
        var lastEnd = 0
        let pieces = reg.lines
        for (k, piece) in pieces.enumerated() {
            let line = p.line + k
            let bytes = Array(piece.utf8)
            let pieceWidth = displayWidth(bytes, tabstop: options.tabstop)
            var one = bytes + [UInt8](repeating: 0x20, count: max(0, width - pieceWidth))
            var ins: [UInt8] = []
            for _ in 0..<count { ins += one }
            if line > lastLine {
                while ins.last == 0x20 { ins.removeLast() }
                let text = [0x0A] + [UInt8](repeating: 0x20, count: vcol) + ins
                changes.append(Change(rope.byteCount..<rope.byteCount, text))
                continue
            }
            let lb = text(line)
            let lw = displayWidth(lb, tabstop: options.tabstop)
            let ls = lineStart(line)
            if lw < vcol {
                while ins.last == 0x20 { ins.removeLast() }
                changes.append(Change((ls + lb.count)..<(ls + lb.count), [UInt8](repeating: 0x20, count: vcol - lw) + ins))
                if k == 0 { firstCol = lb.count + vcol - lw }
            } else {
                var col = 0
                var v = 0
                while col < lb.count && v < vcol {
                    v += cellsAt(lb, col, vcol: v, tabstop: options.tabstop)
                    col = nextCharCol(lb, col)
                }
                if col >= lb.count { while ins.last == 0x20 { ins.removeLast() } }
                one = ins
                changes.append(Change((ls + col)..<(ls + col), one))
                if k == 0 { firstCol = col }
                if k == pieces.count - 1 { lastEnd = col + one.count }
            }
        }
        change(at: cursor) {
            edit(changes, cursor: lineStart(p.line) + firstCol)
        }
        if cursorAfter {
            let line = min(p.line + pieces.count - 1, lastLine)
            cursor = lineStart(line) + min(lastEnd, lineLength(line))
        } else {
            cursor = clampNormal(lineStart(p.line) + firstCol)
        }
    }

    // MARK: - J gJ

    /// Joins `count` lines starting at `first` (Vim's do_join).
    func join(first: Int, count: Int, spaces: Bool) {
        var result = text(first)
        var col = 0
        var end1: Unicode.Scalar? = result.isEmpty ? nil : scalarAt(result, prevCharCol(result, result.count))
        var end2: Unicode.Scalar? = result.count > 1 ? scalarAt(result, prevCharCol(result, prevCharCol(result, result.count))) : nil
        for t in 1..<count {
            var cur = text(first + t)
            var add = 0
            if spaces {
                var k = 0
                while k < cur.count && isBlank(cur[k]) { k += 1 }
                cur = Array(cur[k...])
                if !cur.isEmpty && cur[0] != UInt8(ascii: ")") && !result.isEmpty && end1 != "\t" {
                    if end1 == " " { end1 = end2 } else { add = 1 }
                    if options.joinspaces && (end1 == "." || end1 == "?" || end1 == "!") { add += 1 }
                }
            }
            if t == count - 1 { col = result.count }
            result += [UInt8](repeating: 0x20, count: add) + cur
            end1 = nil
            end2 = nil
            if spaces && !cur.isEmpty {
                let last = prevCharCol(cur, cur.count)
                end1 = scalarAt(cur, last)
                if last > 0 { end2 = scalarAt(cur, prevCharCol(cur, last)) }
            }
        }
        let range = lineStart(first)..<rope.lineEnd(first + count - 1)
        change(at: cursor) {
            replace(range, with: result, cursor: lineStart(first) + col)
        }
        cursor = clampNormal(lineStart(first) + col)
        updateCurswant()
        syncSelection()
    }
}
