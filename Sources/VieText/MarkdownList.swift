/// Markdown lists and quotes, for typing in them: the markers a line starts with, what Return
/// carries to the next line, indenting an item with the lines under it, and keeping numbered
/// lists in order. Shared by the Mac editing commands and Vim's Insert mode.
public enum MarkdownList {
    /// The markers at the start of a line, as byte ranges in it.
    public struct Prefix: Equatable, Sendable {
        /// Leading whitespace and quote markers (`> > `); empty without a quote.
        public var lead: Range<Int>
        /// The item's indentation (after the quote markers, if any).
        public var indent: Range<Int>
        /// `-`, `*`, `+`, or a number and `.` or `)`; empty on a quote line that isn't an item.
        public var marker: Range<Int>
        public var number: Int?
        /// The spaces after the marker.
        public var gap: Range<Int>
        /// `[ ]` or `[x]` and the space after it.
        public var task: Range<Int>?
        public var checked: Bool
        /// Where the text starts.
        public var content: Int

        public var isItem: Bool { !marker.isEmpty }
        public var isQuote: Bool { !lead.isEmpty }
    }

    /// The markers `line` starts with: a list item, a quote, or both (`> - x`); nil for
    /// anything else, a thematic break (`- - -`) included.
    public static func prefix(of line: [UInt8]) -> Prefix? {
        let n = line.count
        var i = 0
        while i < n && isBlank(line[i]) { i += 1 }
        var leadEnd = 0
        if i < n && line[i] == UInt8(ascii: ">") {
            while i < n && line[i] == UInt8(ascii: ">") {
                i += 1
                if i < n && line[i] == 0x20 { i += 1 }
                leadEnd = i
                var j = i
                while j < n && line[j] == 0x20 { j += 1 }
                if j < n && line[j] == UInt8(ascii: ">") { i = j }
            }
        }
        var k = leadEnd
        while k < n && isBlank(line[k]) { k += 1 }
        var markerEnd = k
        var number: Int?
        if k < n, line[k] == UInt8(ascii: "-") || line[k] == UInt8(ascii: "*") || line[k] == UInt8(ascii: "+") {
            markerEnd = k + 1
        } else {
            var d = k
            while d < n && d - k < 9 && line[d] >= 0x30 && line[d] <= 0x39 { d += 1 }
            if d > k && d < n && (line[d] == UInt8(ascii: ".") || line[d] == UInt8(ascii: ")")) {
                number = Int(String(decoding: line[k..<d], as: UTF8.self))
                markerEnd = d + 1
            }
        }
        // A marker needs a space after it, and `- - -` or `***` is a rule, not a list.
        let isMarker = markerEnd > k && markerEnd < n && isBlank(line[markerEnd]) && !isRule(line[k...])
        guard isMarker else {
            guard leadEnd > 0 else { return nil }
            return Prefix(lead: 0..<leadEnd, indent: leadEnd..<leadEnd, marker: leadEnd..<leadEnd, number: nil,
                          gap: leadEnd..<leadEnd, task: nil, checked: false, content: leadEnd)
        }
        var g = markerEnd
        while g < n && isBlank(line[g]) && g - markerEnd < 4 { g += 1 }
        var task: Range<Int>?
        var checked = false
        var content = g
        if g + 3 <= n, line[g] == UInt8(ascii: "["), line[g + 2] == UInt8(ascii: "]"),
           line[g + 1] == 0x20 || line[g + 1] == UInt8(ascii: "x") || line[g + 1] == UInt8(ascii: "X"),
           g + 3 == n || isBlank(line[g + 3]) {
            content = min(g + 4, n)
            task = g..<content
            checked = line[g + 1] != 0x20
        }
        return Prefix(lead: 0..<leadEnd, indent: leadEnd..<k, marker: k..<markerEnd, number: number,
                      gap: markerEnd..<g, task: task, checked: checked, content: content)
    }

    // MARK: - Return

    /// What Return does in a list item or quote, with the cursor at `column`.
    public enum ReturnAction: Equatable, Sendable {
        /// A line break, then these markers for the next item (`- `, `3. `, `- [ ] `, `> `).
        case newItem([UInt8])
        /// The item is empty: replace `range` of the line with `text` (ending the list or
        /// the quote), without a line break.
        case end(range: Range<Int>, text: [UInt8])
        /// The item is empty and nested: outdent it instead (`shift`).
        case outdent
    }

    /// Return at `column` in `line`: nil if the line isn't an item or quote, or the cursor is
    /// before its text (Return is then a plain line break).
    public static func returnAction(line: [UInt8], column: Int) -> ReturnAction? {
        guard let p = prefix(of: line), column >= p.content else { return nil }
        guard line[p.content...].allSatisfy(isBlank) else { return .newItem(continuation(of: p, in: line)) }
        if p.isItem {
            return p.indent.isEmpty ? .end(range: p.indent.lowerBound..<line.count, text: []) : .outdent
        }
        // An empty quote line leaves one level of quote.
        let last = line[p.lead].lastIndex(of: UInt8(ascii: ">")) ?? 0
        return .end(range: 0..<line.count, text: Array(line[0..<last]))
    }

    /// The markers for the item after one with prefix `p` (or before it, `above`): the same
    /// quote, indentation and bullet, the next number (or the same one, as the items after
    /// get renumbered), and an unchecked box for a task.
    public static func continuation(of p: Prefix, in line: [UInt8], above: Bool = false) -> [UInt8] {
        var out = Array(line[p.lead]) + Array(line[p.indent])
        guard p.isItem else { return out }
        if let n = p.number {
            out += Array(String(above ? n : n + 1).utf8) + [line[p.marker.upperBound - 1]]
        } else {
            out.append(line[p.marker.lowerBound])
        }
        out += Array(line[p.gap])
        if p.task != nil { out += Array("[ ] ".utf8) }
        return out
    }

    // MARK: - Backspace

    /// What Backspace at `column` removes when it's where an item's text starts: the task
    /// box, else the marker (keeping the indentation). Nil elsewhere.
    public static func backspaceRange(line: [UInt8], column: Int) -> Range<Int>? {
        guard let p = prefix(of: line), p.isItem, column == p.content else { return nil }
        return p.task ?? p.marker.lowerBound..<p.content
    }

    // MARK: - Indenting

    /// Indents (`right`) or outdents the item on `line`, with the lines under it (sub-items
    /// and continued text). Indenting lines it up under the text of the item above, so it
    /// nests there; outdenting puts it at the level of the item it was in. `unit` is the
    /// indentation used when there's no such item. Nil if `line` isn't an item, or can't go
    /// further left.
    public static func shift(_ rope: Rope, line: Int, right: Bool, unit: [UInt8]) -> [Change]? {
        let text = rope.bytes(in: rope.offset(ofLine: line)..<rope.lineEnd(line))
        guard let p = prefix(of: text), p.isItem else { return nil }
        let level = width(text[p.indent])
        let unitWidth = max(1, width(unit[...]))
        var target: Int?
        var insert: [UInt8]?
        // The item above at this level (indenting) or a shallower one (outdenting).
        var j = line - 1
        while j >= 0 {
            let t = lineBytes(rope, j)
            j -= 1
            if t.allSatisfy(isBlank) { continue }
            let q = prefix(of: t)
            guard let q, q.isItem, t[q.lead] == text[p.lead] else {
                if nestWidth(t, leadCount: p.lead.count) <= level { break }
                continue
            }
            let w = width(t[q.indent])
            if right {
                if w == level { target = w + width(t[q.marker]) + width(t[q.gap]) }
                if w <= level { break }
            } else if w < level {
                target = w
                break
            }
        }
        if right && target == nil {
            target = level + unitWidth
            insert = unit
        }
        let goal = target ?? max(0, level - unitWidth)
        guard goal != level else { return nil }
        let delta = goal - level
        // The lines under the item: deeper than it, with blank lines between them.
        var lines = [line]
        var k = line + 1
        var pendingBlank: [Int] = []
        while k < rope.lineCount {
            let t = lineBytes(rope, k)
            if t.allSatisfy(isBlank) {
                pendingBlank.append(k)
            } else if nestWidth(t, leadCount: p.lead.count) > level {
                lines += pendingBlank + [k]
                pendingBlank = []
            } else {
                break
            }
            k += 1
        }
        var changes: [Change] = []
        for l in lines {
            let start = rope.offset(ofLine: l)
            let t = lineBytes(rope, l)
            if t.allSatisfy(isBlank) { continue }
            let at = start + min(p.lead.count, t.count)
            if delta > 0 {
                changes.append(Change(at..<at, insert ?? Array(repeating: 0x20, count: delta)))
            } else {
                // Take away up to -delta columns of the whitespace there.
                var e = at, w = 0
                while e < start + t.count && w < -delta && isBlank(rope.byte(at: e)) {
                    w += rope.byte(at: e) == 0x09 ? 4 - w % 4 : 1
                    e += 1
                }
                if e > at { changes.append(Change(at..<e, [])) }
            }
        }
        return changes.isEmpty ? nil : changes
    }

    // MARK: - Numbering

    /// Changes that put in order the numbered lists holding the items on `lines` (or, for a
    /// blank line, the next line that isn't; lines that aren't numbered items are skipped).
    /// A list counts only items at its own level; it goes on from its first item's number, or
    /// from 1 if it's nested in an item.
    public static func renumber(_ rope: Rope, around lines: [Int]) -> [Change] {
        var done = Set<Int>()
        var changes: [Change] = []
        for var line in lines where line >= 0 {
            while line < rope.lineCount && lineBytes(rope, line).allSatisfy(isBlank) { line += 1 }
            guard line < rope.lineCount, !done.contains(line) else { continue }
            changes += renumber(rope, list: line, done: &done)
        }
        return changes.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    /// The lines whose numbered lists `changes` may put out of order, numbered as in the text
    /// after them: where they add or remove lines, or change a line's indentation. None for
    /// other edits, such as typing in an item's text or in its number (left as typed).
    public static func linesToRenumber(_ rope: Rope, changes: [Change]) -> [Int] {
        var lines: [Int] = []
        var lineShift = 0
        for c in changes {
            let first = rope.line(at: c.range.lowerBound)
            let removed = rope.line(at: c.range.upperBound) - first
            let added = c.text.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
            defer { lineShift += added - removed }
            if removed == 0 && added == 0 {
                // Indentation: whitespace for whitespace, with only indentation or quote
                // markers before it.
                let start = rope.offset(ofLine: first)
                guard c.text.allSatisfy(isBlank), c.range.count <= 256, c.range.lowerBound - start <= 256,
                      rope.bytes(in: c.range).allSatisfy(isBlank),
                      rope.bytes(in: start..<c.range.lowerBound).allSatisfy({ isBlank($0) || $0 == UInt8(ascii: ">") })
                else { continue }
            }
            lines += [first + lineShift, first + lineShift + added + 1]
        }
        return lines
    }

    private static func renumber(_ rope: Rope, list line: Int, done: inout Set<Int>) -> [Change] {
        let text = lineBytes(rope, line)
        guard let p = prefix(of: text), p.number != nil else { return [] }
        let lead = Array(text[p.lead]), level = width(text[p.indent])
        /// Whether line `j` is a numbered item at this level (true), part of the list but not
        /// one (nil: blank, or deeper), or outside it (false).
        func item(_ j: Int) -> Bool? {
            let t = lineBytes(rope, j)
            if t.allSatisfy(isBlank) { return nil }
            if let q = prefix(of: t), q.isItem, Array(t[q.lead]) == lead {
                let w = width(t[q.indent])
                if w == level { return q.number != nil }
                return w > level ? nil : false
            }
            return nestWidth(t, leadCount: lead.count) > level ? nil : false
        }
        var first = line
        var j = line - 1
        while j >= 0 {
            let it = item(j)
            if it == false { break }
            if it == true { first = j }
            j -= 1
        }
        // Nested in an item when the line above the list (past blank ones) is a shallower item.
        var above = first - 1
        while above >= 0 && lineBytes(rope, above).allSatisfy(isBlank) { above -= 1 }
        var nested = false
        if above >= 0, level > 0 {
            let t = lineBytes(rope, above)
            if let q = prefix(of: t), q.isItem, Array(t[q.lead]) == lead, width(t[q.indent]) < level { nested = true }
        }
        var items: [Int] = []
        j = first
        while j < rope.lineCount {
            let it = item(j)
            if it == true { items.append(j) } else if it == false { break }
            j += 1
        }
        done.formUnion(items)
        guard let start = nested ? 1 : prefix(of: lineBytes(rope, first))?.number else { return [] }
        var changes: [Change] = []
        for (i, l) in items.enumerated() {
            let t = lineBytes(rope, l)
            guard let q = prefix(of: t), let n = q.number, n != start + i else { continue }
            let s = rope.offset(ofLine: l)
            changes.append(Change(s + q.marker.lowerBound..<s + q.marker.upperBound - 1, Array(String(start + i).utf8)))
        }
        return changes
    }

    // MARK: - Helpers

    private static func isBlank(_ b: UInt8) -> Bool { b == 0x20 || b == 0x09 }

    private static func lineBytes(_ rope: Rope, _ line: Int) -> [UInt8] {
        rope.bytes(in: rope.offset(ofLine: line)..<rope.lineEnd(line))
    }

    /// Columns of whitespace, tabs to the next multiple of 4.
    private static func width(_ bytes: ArraySlice<UInt8>) -> Int {
        bytes.reduce(0) { w, b in b == 0x09 ? w + 4 - w % 4 : w + 1 }
    }

    /// The indentation of a line after its first `leadCount` bytes (its quote markers).
    private static func nestWidth(_ line: [UInt8], leadCount: Int) -> Int {
        var w = 0
        for b in line.dropFirst(leadCount) {
            guard isBlank(b) else { break }
            w += b == 0x09 ? 4 - w % 4 : 1
        }
        return w
    }

    /// `- - -`, `***`, `* * *`: three or more of one of them, with only spaces between.
    private static func isRule(_ rest: ArraySlice<UInt8>) -> Bool {
        guard let c = rest.first, c == UInt8(ascii: "-") || c == UInt8(ascii: "*") else { return false }
        var count = 0
        for b in rest {
            if b == c { count += 1 } else if !isBlank(b) { return false }
        }
        return count >= 3
    }
}
