import VieText

enum MotionKind { case exclusive, inclusive, linewise }

enum CurswantRule { case set, keep, end, value(Int) }

struct MotionResult {
    var pos: Pos
    var kind: MotionKind
    var curswant: CurswantRule = .set
    /// Sets the previous context mark (`''`) first.
    var jump = false
    /// Deletes with this motion always go to register 1.
    var useRegOne = false
    /// Skips the "exclusive motion ending in column 0" adjustment.
    var noAdjust = false
    /// The motion moved but fell short (`3w` with two words left): move, then beep.
    var beep = false
}

extension VimEngine {
    // MARK: - Moving the cursor

    func moveCursor(_ m: Motion, _ c: ParsedCommand) {
        if case .searchPrompt(let forward) = m {
            startCommandLine(forward ? "/" : "?", pendingOp: nil, count: c.count)
            return
        }
        guard let r = evaluate(m, count: c.count, from: cursorPos, op: nil) else { return beep() }
        if r.jump { marks["'"] = cursor }
        defer { if r.beep { beep() } }
        var p = r.pos
        if !mode.isVisual { p = clampNormal(p) }
        cursor = offset(p)
        switch r.curswant {
        case .set: updateCurswant()
        case .keep: break
        case .end: curswant = .max
        case .value(let v): curswant = v
        }
        syncSelection()
    }

    // MARK: - Low-level steps (Vim's inc, dec, cls)

    /// Moves forward one character, crossing lines. Returns 1 when it moved to the next line,
    /// 2 when it moved onto the end of a line, -1 at the end of the text, else 0.
    func inc(_ p: inout Pos) -> Int {
        let b = text(p.line)
        if p.col < b.count {
            p.col = nextCharCol(b, p.col)
            return p.col < b.count ? 0 : 2
        }
        if p.line < lastLine {
            p.line += 1
            p.col = 0
            return 1
        }
        return -1
    }

    /// Moves back one character, crossing lines (onto the end of the previous line). Returns
    /// 1 when it crossed a line, -1 at the start of the text, else 0.
    func dec(_ p: inout Pos) -> Int {
        if p.col > 0 {
            p.col = prevCharCol(text(p.line), p.col)
            return 0
        }
        if p.line > 0 {
            p.line -= 1
            p.col = lineLength(p.line)
            return 1
        }
        return -1
    }

    /// `inc` that doesn't stop on the end of a line.
    func incl(_ p: inout Pos) -> Int {
        var r = inc(&p)
        if r >= 1 && p.col > 0 { r = inc(&p) }
        return r
    }

    /// `dec` that doesn't stop on the end of a line.
    func decl(_ p: inout Pos) -> Int {
        var r = dec(&p)
        if r == 1 && p.col > 0 { r = dec(&p) }
        return r
    }

    /// Vim's cls(): 0 for blanks and line ends, else the character class (1 for any
    /// non-blank in WORD motions).
    func cls(_ p: Pos, _ big: Bool) -> Int {
        let b = text(p.line)
        guard p.col < b.count, !isBlank(b[p.col]) else { return 0 }
        let c = vimClass(scalarAt(b, p.col))
        return c != 0 && big ? 1 : c
    }

    func isLineStartEmpty(_ p: Pos) -> Bool { p.col == 0 && isEmptyLine(p.line) }

    /// Number of leading blank bytes is at least `p.col` (Vim's inindent(0)).
    func inIndent(_ p: Pos, extra: Int = 0) -> Bool {
        indentOf(text(p.line), tabstop: options.tabstop).bytes >= p.col + extra
    }

    // MARK: - Words (ported from Vim's search.c / textobject.c)

    /// `w`: forward to the start of the next word. With `eol` (an operator is pending), stops
    /// at the end of the line for the last word.
    func fwdWord(_ count: Int, _ big: Bool, eol: Bool, _ p: inout Pos) -> Bool {
        var count = count
        while count > 0 {
            count -= 1
            let sclass = cls(p, big)
            let lastLineStart = p.line == lastLine
            var i = inc(&p)
            if i == -1 || (i >= 1 && lastLineStart) { return false }
            if i >= 1 && eol && count == 0 { return true }
            if sclass != 0 {
                while cls(p, big) == sclass {
                    i = inc(&p)
                    if i == -1 || (i >= 1 && eol && count == 0) { return true }
                }
            }
            while cls(p, big) == 0 {
                if isLineStartEmpty(p) { break }
                i = inc(&p)
                if i == -1 || (i >= 1 && eol && count == 0) { return true }
            }
        }
        return true
    }

    /// `b`: back to the start of a word.
    func bckWord(_ count: Int, _ big: Bool, stop: Bool, _ p: inout Pos) -> Bool {
        var count = count
        var stop = stop
        while count > 0 {
            count -= 1
            let sclass = cls(p, big)
            if dec(&p) == -1 { return false }
            var finished = false
            if !stop || sclass == cls(p, big) || sclass == 0 {
                while cls(p, big) == 0 {
                    if isLineStartEmpty(p) { finished = true; break }
                    if dec(&p) == -1 { return true }
                }
                if !finished && skipChars(cls(p, big), forward: false, big, &p) { return true }
            }
            if !finished { _ = inc(&p) }
            stop = false
        }
        return true
    }

    /// `e`: forward to the end of a word. With `empty`, an empty line counts as a word.
    func endWord(_ count: Int, _ big: Bool, stop: Bool, empty: Bool, _ p: inout Pos) -> Bool {
        var count = count
        var stop = stop
        while count > 0 {
            count -= 1
            let sclass = cls(p, big)
            if inc(&p) == -1 { return false }
            var finished = false
            if cls(p, big) == sclass && sclass != 0 {
                if skipChars(sclass, forward: true, big, &p) { return false }
            } else if !stop || sclass == 0 {
                while cls(p, big) == 0 {
                    if empty && isLineStartEmpty(p) { finished = true; break }
                    if inc(&p) == -1 { return false }
                }
                if !finished && skipChars(cls(p, big), forward: true, big, &p) { return false }
            }
            if !finished { _ = dec(&p) }
            stop = false
        }
        return true
    }

    /// `ge`: back to the end of the previous word. With `eol`, stops at a line break.
    func bckendWord(_ count: Int, _ big: Bool, eol: Bool, _ p: inout Pos) -> Bool {
        var count = count
        while count > 0 {
            count -= 1
            let sclass = cls(p, big)
            var i = dec(&p)
            if i == -1 { return false }
            if eol && i == 1 { return true }
            if sclass != 0 {
                while cls(p, big) == sclass {
                    i = dec(&p)
                    if i == -1 || (eol && i == 1) { return true }
                }
            }
            while cls(p, big) == 0 {
                if isLineStartEmpty(p) { break }
                i = dec(&p)
                if i == -1 || (eol && i == 1) { return true }
            }
        }
        return true
    }

    /// Skips characters of class `c`. Returns true when it hit the start or end of the text.
    func skipChars(_ c: Int, forward: Bool, _ big: Bool, _ p: inout Pos) -> Bool {
        while cls(p, big) == c {
            if (forward ? inc(&p) : dec(&p)) == -1 { return true }
        }
        return false
    }

    // MARK: - Evaluating motions

    func endCol(_ line: Int, oneMore: Bool) -> Int {
        colForVcol(text(line), .max, tabstop: options.tabstop, oneMore: oneMore)
    }

    func colFor(_ line: Int, vcol: Int) -> Int {
        colForVcol(text(line), vcol, tabstop: options.tabstop, oneMore: mode.isVisual || mode == .insert)
    }

    /// Where motion `m` goes from `start`, or nil when it fails. `op` is the pending
    /// operator, which changes some motions (`cw`, `dw` at a line end, `dl` at the last
    /// character).
    func evaluate(_ m: Motion, count: Int?, from start: Pos, op: Operator?) -> MotionResult? {
        let n = max(count ?? 1, 1)
        var p = start
        let visual = mode.isVisual
        switch m {
        case .left(let wrap):
            var noAdjust = false
            for k in 0..<n {
                if p.col > 0 {
                    p.col = prevCharCol(text(p.line), p.col)
                } else if wrap && p.line > 0 {
                    p.line -= 1
                    p.col = endCol(p.line, oneMore: visual)
                    if (op == .delete || op == .change) && !isEmptyLine(p.line) {
                        if p.col < lineLength(p.line) { p.col = nextCharCol(text(p.line), p.col) }
                        noAdjust = true
                    }
                } else {
                    if op == nil && k == 0 { return nil }
                    break
                }
            }
            return MotionResult(pos: p, kind: .exclusive, noAdjust: noAdjust)

        case .right(let wrap):
            var kind = MotionKind.exclusive
            for k in 0..<n {
                let b = text(p.line)
                let atEnd = visual ? p.col >= b.count : (p.col >= b.count || nextCharCol(b, p.col) >= b.count)
                if !atEnd {
                    p.col = nextCharCol(b, p.col)
                    continue
                }
                if wrap && p.line < lastLine {
                    if op != nil && kind != .inclusive && !b.isEmpty {
                        kind = .inclusive
                    } else {
                        p.line += 1
                        p.col = 0
                        kind = .exclusive
                    }
                    continue
                }
                if op == nil {
                    if k == 0 { return nil }
                } else if !b.isEmpty {
                    kind = .inclusive
                }
                break
            }
            return MotionResult(pos: p, kind: kind)

        case .down, .up:
            let down = m == .down
            if down ? p.line >= lastLine : p.line <= 0 { return nil }
            p.line = down ? min(p.line + n, lastLine) : max(p.line - n, 0)
            p.col = colFor(p.line, vcol: curswant)
            return MotionResult(pos: p, kind: .linewise, curswant: .keep)

        case .downFirstNonBlank, .upFirstNonBlank, .firstNonBlankCount:
            let steps = m == .firstNonBlankCount ? n - 1 : n
            if m == .upFirstNonBlank {
                if steps > 0 && p.line <= 0 { return nil }
                p.line = max(p.line - steps, 0)
            } else {
                if steps > 0 && p.line >= lastLine { return nil }
                p.line = min(p.line + steps, lastLine)
            }
            p.col = firstNonBlank(p.line)
            return MotionResult(pos: p, kind: .linewise)

        case .wordForward(let big):
            if op == .change {
                let b = text(p.line)
                if p.col < b.count && !isBlank(b[p.col]) {
                    // "cw" is "ce" (but "cw" on blanks is "dw").
                    _ = endWord(n, big, stop: true, empty: false, &p)
                    return MotionResult(pos: adjustedWordEnd(start, p, op: op), kind: .inclusive)
                }
            }
            let ok = fwdWord(n, big, eol: op != nil, &p)
            var kind = MotionKind.exclusive
            if start < p {
                let b = text(p.line)
                if p.col > 0 && p.col >= b.count && !visual {
                    p.col = prevCharCol(b, b.count)
                    kind = .inclusive
                }
            }
            return MotionResult(pos: p, kind: kind, beep: !ok && op == nil)

        case .wordEnd(let big):
            let ok = endWord(n, big, stop: false, empty: false, &p)
            p = adjustedWordEnd(start, p, op: op)
            return MotionResult(pos: p, kind: .inclusive, beep: !ok && op == nil)

        case .wordBackward(let big):
            guard bckWord(n, big, stop: false, &p) else { return nil }
            return MotionResult(pos: p, kind: .exclusive)

        case .wordEndBackward(let big):
            guard bckendWord(n, big, eol: false, &p) else { return nil }
            return MotionResult(pos: p, kind: .inclusive)

        case .lineStart:
            return MotionResult(pos: Pos(p.line, 0), kind: .exclusive)

        case .firstNonBlank:
            return MotionResult(pos: Pos(p.line, firstNonBlank(p.line)), kind: .exclusive)

        case .lineEnd:
            if n > 1 && p.line >= lastLine { return nil }
            p.line = min(p.line + n - 1, lastLine)
            p.col = endCol(p.line, oneMore: visual)
            return MotionResult(pos: p, kind: .inclusive, curswant: .end)

        case .lastNonBlank:
            if n > 1 && p.line >= lastLine { return nil }
            p.line = min(p.line + n - 1, lastLine)
            let b = text(p.line)
            var c = b.count
            if c > 0 { c = prevCharCol(b, c) }
            while c > 0 && isBlank(b[c]) { c = prevCharCol(b, c) }
            return MotionResult(pos: Pos(p.line, c), kind: .inclusive)

        case .column:
            let want = n - 1
            p.col = colForVcol(text(p.line), want, tabstop: options.tabstop, oneMore: visual)
            return MotionResult(pos: p, kind: .exclusive, curswant: .value(want))

        case .gotoLine(let last):
            var line = last ? lastLine : 0
            if let count { line = count - 1 }
            line = min(max(line, 0), lastLine)
            return MotionResult(pos: Pos(line, startOfLineCol(line)), kind: .linewise, jump: true)

        case .find(let target, let forward, let till):
            lastFind = (target, forward, till)
            guard let col = findChar(target, forward: forward, till: till, count: n, from: p, stop: true) else { return nil }
            return MotionResult(pos: Pos(p.line, col), kind: forward ? .inclusive : .exclusive)

        case .repeatFind(let reverse):
            guard let last = lastFind else { return nil }
            let forward = reverse ? !last.forward : last.forward
            let stop = !(n == 1 && last.till)
            guard let col = findChar(last.target, forward: forward, till: last.till, count: n, from: p, stop: stop) else { return nil }
            return MotionResult(pos: Pos(p.line, col), kind: forward ? .inclusive : .exclusive)

        case .matchPair:
            if let count {
                guard count <= 100 else { return nil }
                let lines = lastLine + 1
                let line = min(max((lines * count + 99) / 100 - 1, 0), lastLine)
                return MotionResult(pos: Pos(line, startOfLineCol(line)), kind: .linewise, jump: true)
            }
            guard let target = matchPair(from: p) else { return nil }
            return MotionResult(pos: target, kind: .inclusive, jump: true, useRegOne: true)

        case .paragraph(let forward):
            var inclusive = false
            guard let target = findParagraph(forward: forward, count: n, from: p, inclusive: &inclusive) else { return nil }
            return MotionResult(pos: target, kind: inclusive ? .inclusive : .exclusive, jump: true, useRegOne: true)

        case .screenTop, .screenMiddle, .screenBottom:
            let visible = host?.visibleLines ?? 0..<(lastLine + 1)
            let top = min(max(visible.lowerBound, 0), lastLine)
            let bottom = min(max(visible.upperBound - 1, top), lastLine)
            var line: Int
            switch m {
            case .screenTop: line = min(top + n - 1, bottom)
            case .screenBottom: line = max(bottom - (n - 1), top)
            default: line = top + (bottom - top) / 2
            }
            line = min(max(line, 0), lastLine)
            return MotionResult(pos: Pos(line, startOfLineCol(line)), kind: .linewise, jump: true)

        case .searchNext(let reverse):
            guard let last = lastSearch else { fail("E35: No previous regular expression"); return nil }
            let forward = reverse ? !last.forward : last.forward
            guard let r = searchMotion(last.pattern, forward: forward, offset: last.offset, count: n, from: offset(p)) else { return nil }
            highlightSearch = true
            return r

        case .searchWord(let forward, let whole):
            guard let (pattern, wordStart) = wordUnderCursor(p, whole: whole) else {
                fail("E348: No string under cursor")
                return nil
            }
            lastSearch = (pattern, forward, SearchOffset())
            addHistory("/", pattern)
            highlightSearch = true
            // Searching backward starts from the start of the word, as Vim does.
            let from = forward ? offset(p) : offset(Pos(p.line, wordStart))
            return searchMotion(pattern, forward: forward, offset: SearchOffset(), count: n, from: from, smartCase: false)

        case .searchPrompt:
            return nil

        case .mark(let name, let exact):
            guard let target = markOffset(name) else {
                fail(name.isASCII && (name.isLetter || "'`[]<>.^\"".contains(name)) ? "E20: Mark not set" : "E78: Unknown mark")
                return nil
            }
            let t = pos(target)
            if exact {
                return MotionResult(pos: clampForMode(t), kind: .exclusive, jump: true, useRegOne: true)
            }
            return MotionResult(pos: Pos(t.line, firstNonBlank(t.line)), kind: .linewise, jump: true)
        }
    }

    /// After a forward word motion that overshot onto a line end, back onto the last
    /// character (Vim's adjust_cursor), unless in Visual mode.
    func adjustedWordEnd(_ start: Pos, _ p: Pos, op: Operator?) -> Pos {
        var p = p
        if start < p && !mode.isVisual {
            let b = text(p.line)
            if p.col > 0 && p.col >= b.count { p.col = prevCharCol(b, b.count) }
        }
        return p
    }

    func clampForMode(_ p: Pos) -> Pos {
        let b = text(min(p.line, lastLine))
        let p = Pos(min(p.line, lastLine), min(p.col, b.count))
        return mode.isVisual ? p : clampNormal(p)
    }

    /// `f`, `F`, `t`, `T` within the line. `stop` false skips a match right next to the
    /// cursor (so `;` after `t` moves).
    func findChar(_ target: Character, forward: Bool, till: Bool, count: Int, from p: Pos, stop: Bool) -> Int? {
        let b = text(p.line)
        let t = Array(String(target).utf8)
        var col = p.col
        var stop = stop
        for _ in 0..<count {
            while true {
                if forward {
                    col = nextCharCol(b, col)
                    if col >= b.count { return nil }
                } else {
                    if col == 0 { return nil }
                    col = prevCharCol(b, col)
                }
                if col + t.count <= b.count && Array(b[col..<(col + t.count)]) == t && stop { break }
                stop = true
            }
        }
        if till {
            col = forward ? prevCharCol(b, col) : nextCharCol(b, col)
        }
        return col
    }

    // MARK: - %

    static let pairs: [(UInt8, UInt8)] = [(0x28, 0x29), (0x7B, 0x7D), (0x5B, 0x5D)]

    /// `%`: the bracket matching the first bracket at or after the cursor on its line.
    func matchPair(from p: Pos) -> Pos? {
        let b = text(p.line)
        var col = p.col
        while col < b.count {
            let c = b[col]
            if let pair = VimEngine.pairs.first(where: { $0.0 == c || $0.1 == c }) {
                let forward = pair.0 == c
                return findUnmatched(forward ? pair.1 : pair.0, other: c, from: Pos(p.line, col), forward: forward)
            }
            col += 1
        }
        return nil
    }

    /// Searches from `p` (not including it) for `target` that isn't balanced by `other`,
    /// skipping characters escaped with a backslash.
    func findUnmatched(_ target: UInt8, other: UInt8, from p: Pos, forward: Bool) -> Pos? {
        var depth = 0
        var line = p.line
        var b = text(line)
        var col = p.col
        while true {
            if forward {
                col += 1
                while col >= b.count {
                    guard line < lastLine else { return nil }
                    line += 1
                    b = text(line)
                    col = 0
                    if !b.isEmpty { break }
                }
            } else {
                col -= 1
                while col < 0 {
                    guard line > 0 else { return nil }
                    line -= 1
                    b = text(line)
                    col = b.count - 1
                }
            }
            let c = b[col]
            guard c == target || c == other else { continue }
            var slashes = 0
            while col - slashes - 1 >= 0 && b[col - slashes - 1] == 0x5C { slashes += 1 }
            if slashes % 2 == 1 { continue }
            if c == other {
                depth += 1
            } else {
                if depth == 0 { return Pos(line, col) }
                depth -= 1
            }
        }
    }

    // MARK: - { }

    func isParagraphBoundary(_ line: Int) -> Bool { isEmptyLine(line) }

    /// Vim's findpar: the next (or previous) empty line, `count` paragraphs away. At the end
    /// of the text it goes to the last character instead, inclusively.
    func findParagraph(forward: Bool, count: Int, from p: Pos, inclusive: inout Bool) -> Pos? {
        var curr = p.line
        let dir = forward ? 1 : -1
        var count = count
        while count > 0 {
            count -= 1
            var didSkip = false
            var first = true
            while true {
                if !isEmptyLine(curr) { didSkip = true }
                if !first && didSkip && isParagraphBoundary(curr) { break }
                curr += dir
                if curr < 0 || curr > lastLine {
                    if count > 0 { return nil }
                    curr -= dir
                    break
                }
                first = false
            }
        }
        if curr == lastLine && forward {
            let b = text(curr)
            if !b.isEmpty {
                inclusive = true
                return Pos(curr, prevCharCol(b, b.count))
            }
        }
        return Pos(curr, 0)
    }

    // MARK: - Marks

    func markOffset(_ name: Character) -> Int? {
        let key: Character = name == "`" ? "'" : Character(name.lowercased())
        guard let v = marks[key] else { return nil }
        return min(v, rope.byteCount)
    }
}
