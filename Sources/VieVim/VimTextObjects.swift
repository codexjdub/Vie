import VieText

/// A range an operator works on.
struct OpRange {
    enum Kind { case char, line, block }

    var start: Pos
    /// The last position (included when `inclusive`, else the first position after).
    var end: Pos
    var kind: Kind
    var inclusive: Bool
    var useRegOne = false
    var isVisual = false
    // Block selections: display columns, both ends included.
    var leftVcol = 0
    var rightVcol = 0
    var toEOL = false
}

extension VimEngine {
    /// The range a text object covers around `p`, as op-pending mode would see it.
    func textObjectRange(_ obj: TextObject, inner: Bool, count: Int, from p: Pos) -> OpRange? {
        switch obj {
        case .word(let big): return wordObject(count: count, include: !inner, big: big, from: p)
        case .quote(let q): return quoteObject(q, include: !inner, count: count, from: p)
        case .block(let open, let close): return blockObject(open: open, close: close, include: !inner, count: count, from: p)
        case .paragraph: return paragraphObject(count: count, include: !inner, from: p)
        case .tag: return tagObject(include: !inner, count: count, from: p)
        }
    }

    // MARK: - iw aw iW aW (Vim's current_word)

    func backInLine(_ p: inout Pos, _ big: Bool) {
        let sclass = cls(p, big)
        while p.col > 0 {
            var q = p
            _ = dec(&q)
            if cls(q, big) != sclass { break }
            p = q
        }
    }

    func wordObject(count: Int, include: Bool, big: Bool, from start: Pos) -> OpRange? {
        var p = start
        var inclusive = true
        var includeWhite = false
        backInLine(&p, big)
        let startPos = p
        if (cls(p, big) == 0) == include {
            guard endWord(1, big, stop: true, empty: true, &p) else { return nil }
        } else {
            _ = fwdWord(1, big, eol: true, &p)
            if p.col == 0 {
                _ = decl(&p)
            } else if p.col > 0 {
                p.col = prevCharCol(text(p.line), p.col)
            }
            if include { includeWhite = true }
        }
        var count = count - 1
        var objStart = startPos
        while count > 0 {
            inclusive = true
            if incl(&p) == -1 { return nil }
            if include != (cls(p, big) == 0) {
                if !fwdWord(1, big, eol: true, &p) && count > 1 { return nil }
                if p.col > 0 { p.col = prevCharCol(text(p.line), p.col) } else { inclusive = false }
            } else {
                guard endWord(1, big, stop: true, empty: true, &p) else { return nil }
            }
            count -= 1
        }
        if includeWhite && (cls(p, big) != 0 || (p.col == 0 && !inclusive)) {
            // No white space after the word: take the white space before it instead (but
            // not indent).
            var q = startPos
            if q.col > 0 {
                q.col = prevCharCol(text(q.line), q.col)
                backInLine(&q, big)
                if cls(q, big) == 0 && q.col > 0 { objStart = q }
            }
        }
        return OpRange(start: objStart, end: p, kind: .char, inclusive: inclusive)
    }

    // MARK: - i" a" (Vim's current_quote)

    private func findNextQuote(_ b: [UInt8], _ col: Int, _ q: UInt8, escape: Bool) -> Int? {
        var col = col
        while col < b.count {
            let c = b[col]
            if escape && c == 0x5C {
                col += 1
                if col >= b.count { return nil }
            } else if c == q {
                return col
            }
            col = nextCharCol(b, col)
        }
        return nil
    }

    private func findPrevQuote(_ b: [UInt8], _ col: Int, _ q: UInt8, escape: Bool) -> Int {
        var col = col
        while col > 0 {
            col = prevCharCol(b, col)
            var n = 0
            if escape { while col - n > 0 && b[col - n - 1] == 0x5C { n += 1 } }
            if n % 2 == 1 { col -= n } else if b[col] == q { break }
        }
        return col
    }

    func quoteObject(_ q: UInt8, include: Bool, count: Int, from p: Pos) -> OpRange? {
        let b = text(p.line)
        var colStart = p.col
        var colEnd: Int
        if colStart < b.count && b[colStart] == q {
            // On a quote: find out from the line start whether it opens or closes.
            let first = colStart
            colStart = 0
            while true {
                guard let s = findNextQuote(b, colStart, q, escape: false), s <= first else { return nil }
                guard let e = findNextQuote(b, s + 1, q, escape: true) else { return nil }
                if s <= first && first <= e {
                    colStart = s
                    colEnd = e
                    break
                }
                colStart = e + 1
            }
        } else {
            colStart = findPrevQuote(b, colStart, q, escape: true)
            if colStart >= b.count || b[colStart] != q {
                guard let s = findNextQuote(b, colStart, q, escape: false) else { return nil }
                colStart = s
            }
            guard let e = findNextQuote(b, colStart + 1, q, escape: true) else { return nil }
            colEnd = e
        }
        if include {
            if colEnd + 1 < b.count && isBlank(b[colEnd + 1]) {
                while colEnd + 1 < b.count && isBlank(b[colEnd + 1]) { colEnd += 1 }
            } else {
                while colStart > 0 && isBlank(b[colStart - 1]) { colStart -= 1 }
            }
        }
        if !include && count < 2 { colStart += 1 }
        var end = Pos(p.line, colEnd)
        var inclusive = false
        if include || count > 1 {
            if inc(&end) == 2 { inclusive = true }
        }
        return OpRange(start: Pos(p.line, colStart), end: end, kind: .char, inclusive: inclusive)
    }

    // MARK: - i( a( (Vim's current_block)

    func blockObject(open: UInt8, close: UInt8, include: Bool, count: Int, from start: Pos) -> OpRange? {
        var p = start
        if open == UInt8(ascii: "{") {
            while inIndent(p, extra: 1) { if inc(&p) != 0 { break } }
        }
        let b = text(p.line)
        if p.col < b.count && b[p.col] == open { p.col += 1 }

        var startPos: Pos?
        if let first = findUnmatched(open, other: close, from: p, forward: false) {
            var at = first
            startPos = first
            for _ in 1..<max(count, 1) {
                guard let next = findUnmatched(open, other: close, from: at, forward: false) else { break }
                at = next
                startPos = next
            }
        } else {
            // Not inside a block: use the next one (Vim 9.1).
            var at = p
            for _ in 0..<max(count, 1) {
                guard let next = findForward(open, from: at) else { break }
                at = next
                startPos = next
            }
        }
        guard let s = startPos, var e = findUnmatched(close, other: open, from: s, forward: true) else { return nil }
        var sp = s
        var sol = false
        if !include {
            _ = incl(&sp)
            sol = e.col == 0
            _ = decl(&e)
            while inIndent(e, extra: 1) {
                sol = true
                if decl(&e) != 0 { break }
            }
        }
        var r = OpRange(start: sp, end: e, kind: .char, inclusive: false)
        if sol {
            _ = incl(&r.end)
        } else if sp <= e {
            r.inclusive = true
        } else {
            r.end = sp
        }
        return r
    }

    /// The next `c` at or after `p`, scanning forward over lines.
    private func findForward(_ c: UInt8, from p: Pos) -> Pos? {
        var line = p.line
        var col = p.col + 1
        while line <= lastLine {
            let b = text(line)
            while col < b.count {
                if b[col] == c { return Pos(line, col) }
                col += 1
            }
            line += 1
            col = 0
        }
        return nil
    }

    // MARK: - ip ap (Vim's current_par)

    func lineWhite(_ line: Int) -> Bool { text(line).allSatisfy(isBlank) }

    func paragraphObject(count: Int, include: Bool, from p: Pos) -> OpRange? {
        var startLine = p.line
        let whiteInFront = lineWhite(startLine)
        while startLine > 0 {
            if whiteInFront {
                if !lineWhite(startLine - 1) { break }
            } else if lineWhite(startLine - 1) {
                break
            }
            startLine -= 1
        }
        var endLine = startLine
        while endLine <= lastLine && lineWhite(endLine) { endLine += 1 }
        endLine -= 1
        var i = count
        if !include && whiteInFront { i -= 1 }
        while i > 0 {
            i -= 1
            if endLine == lastLine { return nil }
            var doWhite = false
            if !include { doWhite = lineWhite(endLine + 1) }
            if include || !doWhite {
                endLine += 1
                while endLine < lastLine && !lineWhite(endLine + 1) { endLine += 1 }
            }
            if i == 0 && whiteInFront && include { break }
            if include || doWhite {
                while endLine < lastLine && lineWhite(endLine + 1) { endLine += 1 }
            }
        }
        if !whiteInFront && !lineWhite(endLine) && include {
            while startLine > 0 && lineWhite(startLine - 1) { startLine -= 1 }
        }
        return OpRange(start: Pos(startLine, 0), end: Pos(endLine, 0), kind: .line, inclusive: true)
    }

    // MARK: - it at

    private struct Tag {
        var name: [UInt8]
        var closing: Bool
        var start: Int   // offset of '<'
        var end: Int     // offset after '>'
    }

    /// Tags in the text around `center` (a window, so huge files stay fast).
    private func tags(around center: Int) -> [Tag] {
        let lo = rope.lineStart(containing: max(0, center - 256 * 1024))
        let hi = min(rope.byteCount, center + 256 * 1024)
        let b = rope.bytes(in: lo..<hi)
        var out: [Tag] = []
        var i = 0
        while i < b.count {
            guard b[i] == UInt8(ascii: "<") else { i += 1; continue }
            var j = i + 1
            let closing = j < b.count && b[j] == UInt8(ascii: "/")
            if closing { j += 1 }
            let nameStart = j
            while j < b.count, !isBlank(b[j]), b[j] != UInt8(ascii: ">"), b[j] != UInt8(ascii: "/"), b[j] != 0x0A, b[j] != UInt8(ascii: "<") { j += 1 }
            if j == nameStart || b[nameStart] == UInt8(ascii: "!") || b[nameStart] == UInt8(ascii: "?") { i += 1; continue }
            let name = Array(b[nameStart..<j])
            while j < b.count && b[j] != UInt8(ascii: ">") && b[j] != UInt8(ascii: "<") { j += 1 }
            guard j < b.count, b[j] == UInt8(ascii: ">") else { i += 1; continue }
            let selfClosing = b[j - 1] == UInt8(ascii: "/")
            if !selfClosing { out.append(Tag(name: name, closing: closing, start: lo + i, end: lo + j + 1)) }
            i = j + 1
        }
        return out
    }

    func tagObject(include: Bool, count: Int, from p: Pos) -> OpRange? {
        var at = offset(p)
        let all = tags(around: at)
        // On a tag: a start tag counts as inside its block, an end tag as just before it.
        if let t = all.first(where: { $0.start <= at && at < $0.end }) {
            at = t.closing ? t.start - 1 : t.end
        }
        var level = 0
        var openIndex: Int?
        var closeIndex: Int?
        var searchFrom = all.lastIndex(where: { $0.start <= at }) ?? -1
        while level < count {
            // Backward to an unmatched start tag.
            var stack: [[UInt8]] = []
            var found: Int?
            var i = searchFrom
            while i >= 0 {
                let t = all[i]
                if t.end > at && t.closing { i -= 1; continue }
                if t.closing {
                    stack.append(t.name)
                } else if let top = stack.last, top == t.name {
                    stack.removeLast()
                } else if stack.isEmpty {
                    // Its end tag must come after the cursor.
                    var depth = 0
                    var j = i + 1
                    var close: Int?
                    while j < all.count {
                        let u = all[j]
                        if u.name == t.name {
                            if !u.closing { depth += 1 } else if depth == 0 { close = j; break } else { depth -= 1 }
                        }
                        j += 1
                    }
                    if let close, all[close].end > at {
                        found = i
                        closeIndex = close
                        break
                    }
                }
                i -= 1
            }
            guard let f = found else { return nil }
            openIndex = f
            level += 1
            searchFrom = f - 1
            at = all[f].start
        }
        guard let o = openIndex, let c = closeIndex else { return nil }
        let open = all[o], close = all[c]
        if include {
            return OpRange(start: pos(open.start), end: pos(close.end - 1), kind: .char, inclusive: true)
        }
        if open.end >= close.start {
            return OpRange(start: pos(open.end), end: pos(open.end), kind: .char, inclusive: false)
        }
        return OpRange(start: pos(open.end), end: pos(close.start), kind: .char, inclusive: false)
    }

    // MARK: - Shared

    /// Vim's rule for exclusive motions that end in column 0 of a later line: the end moves
    /// to the end of the previous line (inclusive), or the motion becomes line-wise when it
    /// starts in the indent.
    func adjustExclusiveEnd(_ r: inout OpRange) {
        guard r.kind == .char, !r.inclusive, r.end.col == 0, r.end.line > r.start.line else { return }
        r.end.line -= 1
        if inIndent(r.start) {
            r.kind = .line
        } else {
            let b = text(r.end.line)
            r.end.col = b.count
            if !b.isEmpty {
                r.end.col = prevCharCol(b, b.count)
                r.inclusive = true
            }
        }
    }
}
