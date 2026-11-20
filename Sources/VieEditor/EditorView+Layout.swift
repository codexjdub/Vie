import AppKit
import CoreText
import VieText

/// Where one line sits in the rope, in bytes and UTF-16 units.
struct LineInfo {
    let start: Int
    let end: Int // the newline, or the end of the text
    let u16Start: Int
    let u16Length: Int
}

/// A laid-out piece of a line: UTF-16 units `u0..<u1` of the line, drawn starting at content
/// x `x0` (0 is the left edge of the text, before horizontal scrolling).
struct Fragment {
    let ct: CTLine
    let u0: Int
    let u1: Int
    let x0: CGFloat
    let width: CGFloat
}

/// Cached layout of one line. Short lines (most of them) are one `prefix` fragment laid out
/// from the line start. Lines longer than `exactLimit` units add `far` windows of
/// `farWindow` units each.
struct LineEntry {
    let info: LineInfo
    var prefix: Fragment?
    var far: [Int: Fragment] = [:]
}

/// Line layout. Text is laid out from the line start up to what is visible (plus slack), so
/// x positions are exact. Past `exactLimit` UTF-16 units, a line is laid out in independent
/// windows placed as if every unit were one column wide: a 50 MB line costs no more than a
/// short one, and positions stay consistent between drawing, the caret and clicks.
extension EditorView {
    static let exactLimit = 4096
    static let farWindow = 1024

    func info(_ line: Int) -> LineInfo {
        if let entry = lines[line] { return entry.info }
        let start = rope.offset(ofLine: line), end = rope.lineEnd(line)
        let u16Start = rope.utf16Offset(at: start)
        let info = LineInfo(start: start, end: end, u16Start: u16Start, u16Length: rope.utf16Offset(at: end) - u16Start)
        lines[line] = LineEntry(info: info)
        return info
    }

    /// UTF-16 units to lay out to reach content x `x`, with slack.
    func units(forX x: CGFloat) -> Int { max(0, Int(ceil(x / charWidth))) + 64 }

    /// The line laid out from its start, covering at least `units` units (or the whole line,
    /// up to `exactLimit`).
    func prefix(_ line: Int, covering units: Int) -> Fragment {
        let info = info(line)
        let want = min(units, info.u16Length, Self.exactLimit)
        if let p = lines[line]?.prefix, p.u1 >= want { return p }
        var target = min(info.u16Length, Self.exactLimit, (max(want, 1) + 255) / 256 * 256)
        if info.u16Length <= 512 { target = info.u16Length }
        let f = makeFragment(info, u0: 0, u1: target, x0: 0)
        lines[line]?.prefix = f
        let estimate = f.u1 >= info.u16Length ? f.width : f.width + CGFloat(info.u16Length - f.u1) * charWidth
        widestLine = max(widestLine, estimate)
        return f
    }

    private func makeFragment(_ info: LineInfo, u0: Int, u1: Int, x0: CGFloat) -> Fragment {
        let b0 = u0 == 0 ? info.start : rope.offset(atUTF16: info.u16Start + u0)
        let b1 = u1 >= info.u16Length ? info.end : rope.offset(atUTF16: info.u16Start + u1)
        // Offsets inside a surrogate pair round up; record the units actually covered.
        let a0 = u0 == 0 ? 0 : rope.utf16Offset(at: b0) - info.u16Start
        let a1 = u1 >= info.u16Length ? info.u16Length : rope.utf16Offset(at: b1) - info.u16Start
        let attr = Highlighter.highlight(rope.string(in: b0..<b1), font: font, paragraph: paragraph)
        let ct = CTLineCreateWithAttributedString(attr as CFAttributedString)
        return Fragment(ct: ct, u0: a0, u1: a1, x0: x0, width: CGFloat(CTLineGetTypographicBounds(ct, nil, nil, nil)))
    }

    /// Number of far windows after the exact prefix ending at unit `exactEnd`.
    private func farCount(_ info: LineInfo, exactEnd: Int) -> Int {
        max(0, (info.u16Length - exactEnd + Self.farWindow - 1) / Self.farWindow)
    }

    private func farFragment(_ line: Int, _ k: Int) -> Fragment {
        if let f = lines[line]?.far[k] { return f }
        let info = info(line)
        let exact = prefix(line, covering: Self.exactLimit)
        let u0 = exact.u1 + k * Self.farWindow
        let x0 = exact.width + CGFloat(k * Self.farWindow) * charWidth
        let f = makeFragment(info, u0: u0, u1: min(info.u16Length, u0 + Self.farWindow), x0: x0)
        lines[line]?.far[k] = f
        widestLine = max(widestLine, x0 + f.width + CGFloat(info.u16Length - f.u1) * charWidth)
        return f
    }

    /// The fragment that contains unit `u` of the line.
    func fragment(_ line: Int, containing u: Int) -> Fragment {
        let info = info(line)
        if u <= Self.exactLimit || info.u16Length <= Self.exactLimit { return prefix(line, covering: u + 64) }
        let exact = prefix(line, covering: Self.exactLimit)
        if u <= exact.u1 { return exact }
        let k = min((u - exact.u1) / Self.farWindow, farCount(info, exactEnd: exact.u1) - 1)
        return farFragment(line, max(0, k))
    }

    /// Fragments to draw for content x range `x0...x1`, with the IME composition swapped in.
    func fragments(_ line: Int, from x0: CGFloat, to x1: CGFloat) -> [Fragment] {
        let info = info(line)
        var p = prefix(line, covering: units(forX: x1))
        // Zero-width characters can leave the prefix short of the right edge.
        while p.width < x1 && p.u1 < min(info.u16Length, Self.exactLimit) { p = prefix(line, covering: p.u1 * 2) }
        var out: [Fragment] = []
        if p.width > x0 || p.u1 >= info.u16Length { out.append(p) }
        if p.u1 < info.u16Length && p.width < x1 {
            let w = CGFloat(Self.farWindow) * charWidth
            let last = farCount(info, exactEnd: p.u1) - 1
            let from = max(0, Int((x0 - p.width) / w)), to = min(last, Int((x1 - p.width) / w))
            if from <= to { for k in from...to { out.append(farFragment(line, k)) } }
        }
        if marked != nil, let composed = composedFragment(), composed.line == line,
           let i = out.firstIndex(where: { $0.u0 == composed.base.u0 }) {
            out[i] = composed.fragment
        }
        return out
    }

    /// The fragment holding the cursor, re-laid out with the IME composition inserted and
    /// underlined. Nil when nothing is being composed.
    func composedFragment() -> (fragment: Fragment, line: Int, base: Fragment)? {
        guard let m = marked else { return nil }
        let head = buffer.selection.head
        let line = rope.line(at: head)
        let info = info(line)
        let base = fragment(line, containing: rope.utf16Offset(at: head) - info.u16Start)
        let b0 = base.u0 == 0 ? info.start : rope.offset(atUTF16: info.u16Start + base.u0)
        let b1 = base.u1 >= info.u16Length ? info.end : rope.offset(atUTF16: info.u16Start + base.u1)
        let before = rope.string(in: b0..<head), after = rope.string(in: head..<b1)
        let attr = Highlighter.highlight(before + m + after, font: font, paragraph: paragraph)
        let start = before.utf16.count
        attr.addAttribute(Highlighter.underlineKey, value: NSNumber(value: CTUnderlineStyle.single.rawValue),
                          range: NSRange(location: start, length: m.utf16.count))
        let sel = markedSelection
        if sel.length > 0, sel.location + sel.length <= m.utf16.count {
            attr.addAttribute(Highlighter.underlineKey, value: NSNumber(value: CTUnderlineStyle.thick.rawValue),
                              range: NSRange(location: start + sel.location, length: sel.length))
        }
        let ct = CTLineCreateWithAttributedString(attr as CFAttributedString)
        let f = Fragment(ct: ct, u0: base.u0, u1: base.u1 + m.utf16.count, x0: base.x0,
                         width: CGFloat(CTLineGetTypographicBounds(ct, nil, nil, nil)))
        return (f, line, base)
    }

    // MARK: - Positions

    /// Content x of byte offset `off`.
    func x(of off: Int) -> CGFloat { x(of: off, line: rope.line(at: off)) }

    func x(of off: Int, line: Int) -> CGFloat {
        let info = info(line)
        if off <= info.start { return 0 }
        let u = rope.utf16Offset(at: min(off, info.end)) - info.u16Start
        let f = fragment(line, containing: u)
        return f.x0 + CTLineGetOffsetForStringIndex(f.ct, u - f.u0, nil)
    }

    /// Content x of the caret, inside the composition while composing.
    func caretX() -> CGFloat {
        let head = buffer.selection.head
        if let composed = composedFragment() {
            let info = info(composed.line)
            let index = rope.utf16Offset(at: head) - info.u16Start - composed.base.u0 + markedSelection.location
            return composed.fragment.x0 + CTLineGetOffsetForStringIndex(composed.fragment.ct, index, nil)
        }
        return x(of: head)
    }

    /// Byte offset of the character boundary nearest content x `x` on `line`.
    func offset(atX x: CGFloat, line: Int) -> Int {
        let info = info(line)
        guard x > 0, info.u16Length > 0 else { return info.start }
        var f = prefix(line, covering: units(forX: x))
        while f.width < x && f.u1 < min(info.u16Length, Self.exactLimit) { f = prefix(line, covering: f.u1 * 2) }
        if f.width < x && f.u1 < info.u16Length {
            let w = CGFloat(Self.farWindow) * charWidth
            let k = min(farCount(info, exactEnd: f.u1) - 1, max(0, Int((x - f.width) / w)))
            f = farFragment(line, k)
        }
        var index = CTLineGetStringIndexForPosition(f.ct, CGPoint(x: x - f.x0, y: 0))
        if index == kCFNotFound { index = 0 }
        let u = f.u0 + index
        return u >= info.u16Length ? info.end : rope.offset(atUTF16: info.u16Start + u)
    }

    /// Byte offset under a point in view coordinates. Below the last line is the end of text.
    func offset(at p: NSPoint) -> Int {
        let line = Int(floor((p.y + scrollY) / lineHeight))
        if line >= rope.lineCount { return rope.byteCount }
        return offset(atX: p.x - textX + scrollX, line: max(0, line))
    }
}
