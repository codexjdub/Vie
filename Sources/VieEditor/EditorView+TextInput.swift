import AppKit
import CoreText
import VieText

/// NSTextInputClient: typed text, IME composition (marked text), the accent menu and emoji
/// picker. The composition isn't in the buffer until committed; the input method sees a
/// "virtual" document with it inserted at the cursor, so UTF-16 offsets after the cursor
/// shift by its length while composing.
extension EditorView {
    private func string(from value: Any) -> String {
        (value as? NSAttributedString)?.string ?? (value as? String) ?? ""
    }

    private func normalizeNewlines(_ s: String) -> String {
        guard s.contains("\r") else { return s }
        return s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    private func range(forUTF16 r: NSRange) -> Range<Int> {
        rope.offset(atUTF16: r.location)..<rope.offset(atUTF16: r.location + r.length)
    }

    public func insertText(_ string: Any, replacementRange: NSRange) {
        if let vim {
            let replacing = marked == nil && replacementRange.location != NSNotFound ? range(forUTF16: replacementRange) : nil
            marked = nil
            markedSelection = NSRange(location: 0, length: 0)
            vimInsert(normalizeNewlines(self.string(from: string)), replacing: replacing, vim)
            return
        }
        let bytes = Array(normalizeNewlines(self.string(from: string)).utf8)
        if marked != nil {
            marked = nil
            markedSelection = NSRange(location: 0, length: 0)
            replaceSelection(with: bytes, kind: .typing)
        } else if replacementRange.location != NSNotFound {
            // The accent menu (press and hold) replaces the character typed before it.
            let r = range(forUTF16: replacementRange)
            applyEdit([Change(r, bytes)], selection: Selection(r.lowerBound + bytes.count), kind: .typing)
        } else {
            replaceSelection(with: bytes, kind: .typing)
        }
    }

    public func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let text = self.string(from: string)
        if marked == nil && vim == nil {
            // Starting a composition replaces the selection, or the range being reconverted.
            let r = replacementRange.location != NSNotFound ? range(forUTF16: replacementRange) : buffer.selection.range
            if !r.isEmpty { applyEdit([Change(r, [])], selection: Selection(r.lowerBound), kind: .typing) }
        }
        marked = text.isEmpty ? nil : text
        markedSelection = selectedRange
        revealCursor()
    }

    public func unmarkText() {
        guard let m = marked else { return }
        marked = nil
        markedSelection = NSRange(location: 0, length: 0)
        if let vim { return vimInsert(m, replacing: nil, vim) }
        replaceSelection(with: Array(m.utf8), kind: .typing)
    }

    public func selectedRange() -> NSRange {
        let s = buffer.selection
        if marked != nil {
            return NSRange(location: rope.utf16Offset(at: s.head) + markedSelection.location, length: markedSelection.length)
        }
        let lo = rope.utf16Offset(at: s.lowerBound)
        return NSRange(location: lo, length: rope.utf16Offset(at: s.upperBound) - lo)
    }

    public func markedRange() -> NSRange {
        guard let m = marked else { return NSRange(location: NSNotFound, length: 0) }
        return NSRange(location: rope.utf16Offset(at: buffer.selection.head), length: m.utf16.count)
    }

    public func hasMarkedText() -> Bool { marked != nil }

    public func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        let cursor = rope.utf16Offset(at: buffer.selection.head)
        let m = Array((marked ?? "").utf16)
        let total = rope.utf16Count + m.count
        let lo = min(max(range.location, 0), total)
        let hi = min(total, lo + min(max(range.length, 0), 4096))
        var units: [UInt16] = []
        func real(_ a: Int, _ b: Int) {
            if a < b { units += rope.string(in: rope.offset(atUTF16: a)..<rope.offset(atUTF16: b)).utf16 }
        }
        if m.isEmpty {
            real(lo, hi)
        } else {
            real(lo, min(hi, cursor))
            let ms = max(lo, cursor), me = min(hi, cursor + m.count)
            if ms < me { units += m[(ms - cursor)..<(me - cursor)] }
            let a = max(lo, cursor + m.count)
            if a < hi { real(a - m.count, hi - m.count) }
        }
        actualRange?.pointee = NSRange(location: lo, length: units.count)
        return NSAttributedString(string: String(decoding: units, as: UTF16.self))
    }

    public func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    /// Screen rect of a character, used to place the IME candidate window.
    public func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        actualRange?.pointee = range
        guard let window else { return .zero }
        let head = buffer.selection.head
        let cursor = rope.utf16Offset(at: head)
        let line: Int, x: CGFloat
        if let m = marked, let composed = composedFragment(), range.location >= cursor {
            line = composed.line
            let info = info(line)
            let index = cursor - info.u16Start - composed.base.u0 + min(range.location - cursor, m.utf16.count)
            x = composed.fragment.x0 + CTLineGetOffsetForStringIndex(composed.fragment.ct, index, nil)
        } else {
            let off = rope.offset(atUTF16: min(range.location, rope.utf16Count))
            line = rope.line(at: off)
            x = self.x(of: off, line: line)
        }
        let off = rope.offset(atUTF16: min(range.location, rope.utf16Count))
        let y = self.y(of: wrapsLines ? rowPosition(of: off) : RowPosition(line: line, row: 0)) ?? bounds.height
        let rect = NSRect(x: textX + x - scrollX, y: y, width: charWidth, height: lineHeight)
        return window.convertToScreen(convert(rect, to: nil))
    }

    public func characterIndex(for point: NSPoint) -> Int {
        guard let window else { return NSNotFound }
        let p = convert(window.convertPoint(fromScreen: point), from: nil)
        return rope.utf16Offset(at: offset(at: p))
    }
}
