import AppKit
import CoreText
import VieText

/// A row of text on screen: a line, and which of its rows (always 0 without wrapping).
struct RowPosition: Comparable, Hashable {
    var line: Int
    var row: Int

    static func < (a: RowPosition, b: RowPosition) -> Bool {
        a.line != b.line ? a.line < b.line : a.row < b.row
    }
}

/// Soft wrap and the vertical scroll position.
///
/// The view's scroll position is a row (`top`) and how far it's scrolled out of sight
/// (`topOffset`), not a y in points. Rows are counted only for lines that are drawn or walked
/// past, so wrapping a 100 MB file costs no more than wrapping a screenful, and an edit above
/// the view doesn't move what's on screen. Lines up to `exactLimit` units wrap at word
/// boundaries (Core Text picks the breaks), with rows after the first indented like the line;
/// longer ones are cut into rows of a fixed number of columns, laid out one at a time.
extension EditorView {
    /// Width rows wrap at: the text area, less a cell for the caret after the last character.
    var wrapWidth: CGFloat { max(charWidth * 10, textWidth - charWidth) }

    /// Columns per row of a line too long to wrap word by word.
    var wrapColumns: Int { max(1, Int(wrapWidth / charWidth)) }

    /// Lays out again when the wrap width changed (a resize, or a wider gutter), keeping the
    /// same text at the top.
    func followWrapWidth() {
        guard wrapsLines, wrapWidth != wrappedWidth else { return }
        let unit = lines[top.line]?.rows.map { $0[min(top.row, $0.count - 1)].u0 }
        wrappedWidth = wrapWidth
        dropLayouts { _ in true }
        if let unit { top.row = rowIndex(top.line, unit: unit) }
    }

    // MARK: - Rows

    func rowCount(_ line: Int) -> Int {
        guard wrapsLines else { return 1 }
        let length = info(line).u16Length
        if length > Self.exactLimit { return (length + wrapColumns - 1) / wrapColumns }
        return wrappedRows(line).count
    }

    /// The row of `line` holding unit `u`; a unit at a break starts the next row.
    func rowIndex(_ line: Int, unit u: Int) -> Int {
        guard wrapsLines else { return 0 }
        let length = info(line).u16Length
        if length > Self.exactLimit { return min(u / wrapColumns, rowCount(line) - 1) }
        let rows = wrappedRows(line)
        return rows.lastIndex { $0.u0 <= u } ?? 0
    }

    /// The row holding byte offset `off`.
    func rowPosition(of off: Int) -> RowPosition {
        let line = rope.line(at: off)
        guard wrapsLines else { return RowPosition(line: line, row: 0) }
        let info = info(line)
        let u = off <= info.start ? 0 : rope.utf16Offset(at: min(off, info.end)) - info.u16Start
        return RowPosition(line: line, row: rowIndex(line, unit: u))
    }

    /// A row, laid out.
    func rowFragment(_ p: RowPosition) -> Fragment {
        let info = info(p.line)
        guard info.u16Length > Self.exactLimit else {
            let rows = wrappedRows(p.line)
            return rows[min(p.row, rows.count - 1)]
        }
        if let f = lines[p.line]?.longRows[p.row] { return f }
        let cols = wrapColumns
        let u0 = min(p.row * cols, info.u16Length)
        let f = makeFragment(info, u0: u0, u1: min(info.u16Length, u0 + cols), x0: 0)
        lines[p.line]?.longRows[p.row] = f
        return f
    }

    /// The rows of a line short enough to wrap at word boundaries.
    func wrappedRows(_ line: Int) -> [Fragment] {
        if let rows = lines[line]?.rows { return rows }
        let info = info(line)
        let typesetter = CTTypesetterCreateWithAttributedString(styledText(info.start..<info.end) as CFAttributedString)
        let length = info.u16Length, width = Double(wrapWidth)
        var rows: [Fragment] = []
        var start = 0, indent: CGFloat = 0
        repeat {
            let x0 = rows.isEmpty ? 0 : indent
            var count = CTTypesetterSuggestLineBreak(typesetter, start, width - Double(x0))
            if count <= 0 { count = length - start }
            let ct = CTTypesetterCreateLine(typesetter, CFRange(location: start, length: count))
            rows.append(Fragment(ct: ct, u0: start, u1: start + count, x0: x0,
                                 width: CGFloat(CTLineGetTypographicBounds(ct, nil, nil, nil)), ctStart: start))
            if rows.count == 1 { indent = continuationIndent(info, firstRow: rows[0]) }
            start += count
        } while start < length
        lines[line]?.rows = rows
        return rows
    }

    /// Rows after the first start under the line's text (its leading spaces and tabs), unless
    /// that's past half the width.
    private func continuationIndent(_ info: LineInfo, firstRow: Fragment) -> CGFloat {
        let lead = rope.bytes(from: info.start, maxBytes: 256).prefix { $0 == 0x20 || $0 == 0x09 }.count
        guard lead > 0, lead < firstRow.u1 else { return 0 }
        let x = firstRow.offset(ofUnit: lead)
        return x <= wrapWidth / 2 ? x : 0
    }

    func row(after p: RowPosition) -> RowPosition? {
        if p.row + 1 < rowCount(p.line) { return RowPosition(line: p.line, row: p.row + 1) }
        return p.line + 1 < rope.lineCount ? RowPosition(line: p.line + 1, row: 0) : nil
    }

    func row(before p: RowPosition) -> RowPosition? {
        if p.row > 0 { return RowPosition(line: p.line, row: p.row - 1) }
        return p.line > 0 ? RowPosition(line: p.line - 1, row: rowCount(p.line - 1) - 1) : nil
    }

    /// The bytes of a row: up to the next row's start, or to the line's end for its last row.
    func byteRange(of p: RowPosition) -> Range<Int> {
        let info = info(p.line)
        guard wrapsLines else { return info.start..<info.end }
        let f = rowFragment(p)
        let lo = f.u0 == 0 ? info.start : rope.offset(atUTF16: info.u16Start + f.u0)
        let hi = f.u1 >= info.u16Length ? info.end : rope.offset(atUTF16: info.u16Start + f.u1)
        return lo..<max(lo, hi)
    }

    // MARK: - Positions

    /// Where byte offset `off` of `line` is drawn: its row, and the content x in that row.
    func place(_ off: Int, line: Int) -> (row: Int, x: CGFloat) {
        guard wrapsLines else { return (0, x(of: off, line: line)) }
        let info = info(line)
        let u = off <= info.start ? 0 : rope.utf16Offset(at: min(off, info.end)) - info.u16Start
        let row = rowIndex(line, unit: u)
        let f = rowFragment(RowPosition(line: line, row: row))
        return (row, f.x0 + f.offset(ofUnit: u))
    }

    /// Width of the character at `off`, measured in its row.
    func cellWidth(at off: Int, line: Int) -> CGFloat {
        let info = info(line)
        guard off < info.end else { return charWidth }
        let next = min(rope.nextGraphemeBoundary(after: off), info.end)
        guard wrapsLines else { return max(2, x(of: next, line: line) - x(of: off, line: line)) }
        let u = rope.utf16Offset(at: off) - info.u16Start, v = rope.utf16Offset(at: next) - info.u16Start
        let f = rowFragment(RowPosition(line: line, row: rowIndex(line, unit: u)))
        return max(2, f.offset(ofUnit: v) - f.offset(ofUnit: u))
    }

    /// The character boundary nearest content x `x` in row `p`. Past the end of a row that
    /// wraps, it's before the row's last character, so the caret stays on that row.
    func offset(atX x: CGFloat, in p: RowPosition) -> Int {
        guard wrapsLines else { return offset(atX: x, line: p.line) }
        let info = info(p.line)
        let f = rowFragment(p)
        let u = f.unit(atX: x)
        if u >= f.u1 && f.u1 < info.u16Length {
            let start = rope.offset(atUTF16: info.u16Start + f.u0)
            return max(start, rope.previousGraphemeBoundary(before: rope.offset(atUTF16: info.u16Start + f.u1)))
        }
        return u >= info.u16Length ? info.end : rope.offset(atUTF16: info.u16Start + u)
    }

    /// The rows on screen, top to bottom, with each one's y (at least one row).
    func visibleRows() -> [(pos: RowPosition, y: CGFloat)] {
        var out: [(pos: RowPosition, y: CGFloat)] = []
        var next: RowPosition? = top, y = -topOffset
        while let p = next, y < bounds.height || out.isEmpty {
            out.append((p, y))
            y += lineHeight
            next = row(after: p)
        }
        return out
    }

    /// The y of row `p` in the view, if it's within about a screen of the top.
    func y(of p: RowPosition) -> CGFloat? {
        guard wrapsLines else { return CGFloat(p.line) * lineHeight - scrollY }
        let limit = Int(bounds.height / lineHeight) + 2
        var q = top, y = -topOffset, n = 0
        if p >= top {
            guard p.line - top.line <= limit else { return nil }
            while q < p, n < limit, let next = row(after: q) { q = next; y += lineHeight; n += 1 }
        } else {
            guard top.line - p.line <= limit else { return nil }
            while q > p, n < limit, let previous = row(before: q) { q = previous; y -= lineHeight; n += 1 }
        }
        return q == p ? y : nil
    }

    // MARK: - Scrolling

    /// The top of the view in points, counting each line as one row: exact without wrapping,
    /// a line-based estimate with it.
    public var scrollY: CGFloat {
        let rows = top.row == 0 && topOffset == 0 ? 1 : rowCount(top.line)
        return (CGFloat(top.line) + (CGFloat(top.row) + topOffset / lineHeight) / CGFloat(rows)) * lineHeight
    }

    /// Scrolls by `dy` points, down if positive.
    func scrollRows(by dy: CGFloat) {
        if wrapsLines {
            topOffset += dy
            while topOffset >= lineHeight, let next = row(after: top) {
                top = next
                topOffset -= lineHeight
            }
            while topOffset < 0 {
                guard let previous = row(before: top) else { topOffset = 0; break }
                top = previous
                topOffset += lineHeight
            }
        } else {
            setScrollY(scrollY + dy)
        }
        clampScroll()
    }

    /// Without wrapping: scrolls to `y` points from the top of the text.
    func setScrollY(_ y: CGFloat) {
        let y = max(0, y)
        let line = min(Int(y / lineHeight), rope.lineCount - 1)
        top = RowPosition(line: line, row: 0)
        topOffset = y - CGFloat(line) * lineHeight
    }

    /// Puts row `p` at the top.
    func scroll(toRow p: RowPosition) {
        top = p
        topOffset = 0
        clampScroll()
        needsDisplay = true
    }

    /// Keeps the scroll position inside the text: the end no higher than the bottom of the view.
    func clampScroll() {
        let count = rope.lineCount
        if top.line >= count { top = RowPosition(line: count - 1, row: 0); topOffset = 0 }
        if top.line < 0 { top = RowPosition(line: 0, row: 0); topOffset = 0 }
        if top.row > 0 { top.row = min(top.row, rowCount(top.line) - 1) }
        if topOffset < 0 { topOffset = 0 }
        // Each line takes at least a row, so only a top within a screenful of the end can be past it.
        if top.line >= count - 1 - Int(ceil(bounds.height / lineHeight)) {
            let (last, offset) = bottomAnchor()
            if top > last || (top == last && topOffset > offset) {
                top = last
                topOffset = offset
            }
        }
        scrollX = wrapsLines ? 0 : min(max(scrollX, 0), maxScrollX)
    }

    /// The scroll position that puts the end of the text at the bottom of the view (or the
    /// start at the top, if it all fits).
    private func bottomAnchor() -> (RowPosition, CGFloat) {
        let lastLine = rope.lineCount - 1
        var p = RowPosition(line: lastLine, row: rowCount(lastLine) - 1)
        let above = Int(ceil(bounds.height / lineHeight)) - 1
        for _ in 0..<max(above, 0) {
            guard let previous = row(before: p) else { return (p, 0) }
            p = previous
        }
        return (p, max(0, CGFloat(above + 1) * lineHeight - bounds.height))
    }

    /// Scrolls just enough to show row `p` whole.
    func reveal(_ p: RowPosition) {
        if p < top || (p == top && topOffset > 0) {
            top = p
            topOffset = 0
            return
        }
        if let y = y(of: p), y + lineHeight <= bounds.height { return }
        // Below: put it at the bottom.
        let above = Int(ceil(bounds.height / lineHeight)) - 1
        var t = p, walked = 0
        while walked < above, let previous = row(before: t) {
            t = previous
            walked += 1
        }
        top = t
        topOffset = walked == above ? max(0, CGFloat(above + 1) * lineHeight - bounds.height) : 0
    }

    /// Scrolls so row `p` is in the middle of the view.
    func center(_ p: RowPosition) {
        let rise = (bounds.height - lineHeight) / 2
        let above = Int(ceil(rise / lineHeight))
        var t = p, walked = 0
        while walked < above, let previous = row(before: t) {
            t = previous
            walked += 1
        }
        top = t
        topOffset = walked == above ? max(0, CGFloat(above) * lineHeight - rise) : 0
        clampScroll()
        needsDisplay = true
    }

    /// Keeps the same text on screen when lines above it are added or removed.
    func followEdit(_ change: BufferChange) {
        guard change.lineDelta != 0, change.lastLine != .max, top.line > change.firstLine else { return }
        let oldLast = change.lastLine - change.lineDelta
        if top.line > oldLast {
            top.line += change.lineDelta
        } else {
            top = RowPosition(line: min(top.line, change.lastLine), row: 0)
            topOffset = 0
        }
    }
}
