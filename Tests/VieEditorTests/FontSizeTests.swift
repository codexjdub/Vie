import AppKit
import Foundation
import Testing
import VieText
@testable import VieEditor

/// Changing the font size: metrics and layouts follow, the top line and a visible cursor stay.
@MainActor
@Suite struct FontSizeTests {
    private let words = "the quick brown fox jumps over the lazy dog and keeps running past the old mill "

    private func make(_ text: String, wrap: Bool = false, width: CGFloat = 500, height: CGFloat = 300, cursor: Int = 0) -> EditorView {
        let buffer = Buffer(rope: Rope(text))
        buffer.selection = Selection(cursor)
        let v = EditorView(frame: NSRect(x: 0, y: 0, width: width, height: height), buffer: buffer)
        v.wrapsLines = wrap
        return v
    }

    private func numbered(_ n: Int) -> String { (0..<n).map { "line \($0)" }.joined(separator: "\n") }

    @Test func metricsAndLayoutsFollowTheSize() {
        let v = make("abcdef\n\tx\n")
        #expect(v.fontSize == EditorFont.defaultSize)
        let (height, width, gutter) = (v.lineHeight, v.charWidth, v.gutterWidth)
        let x = v.x(of: 4)
        v.fontSize = 26
        #expect(v.fontSize == 26)
        #expect(v.lineHeight > height * 1.7)
        #expect(abs(v.charWidth - width * 2) < 0.5)
        #expect(v.gutterWidth > gutter)
        // Lines are laid out again in the new font, tab stops included.
        #expect(abs(v.x(of: 4) - x * 2) < 1)
        let tabEnd = v.rope.offset(ofLine: 1) + 1
        #expect(abs(v.x(of: tabEnd) - v.charWidth * 4) < 1)
        let bold = CTFontCopyTraits(v.boldFont) as? [CFString: Any]
        #expect(CTFontGetSize(v.boldFont) == 26 && bold != nil)
    }

    @Test func sizesStayInRange() {
        let v = make("x")
        v.fontSize = 200
        #expect(v.fontSize == EditorFont.sizes.upperBound)
        v.fontSize = 1
        #expect(v.fontSize == EditorFont.sizes.lowerBound)
    }

    @Test func theTopLineStays() {
        let v = make(numbered(500))
        v.scroll(toLine: 200)
        v.fontSize = 24
        #expect(v.top == RowPosition(line: 200, row: 0) && v.topOffset == 0)
        v.fontSize = 9
        #expect(v.top.line == 200)
    }

    @Test func aVisibleCursorStaysVisible() {
        let v = make(numbered(500), cursor: 0)
        v.scroll(toLine: 100)
        let line = v.visibleRows().last!.pos.line - 1
        v.buffer.selection = Selection(v.rope.offset(ofLine: line))
        v.fontSize = 30
        let caret = v.rowPosition(of: v.selection.head)
        let row = v.visibleRows().first { $0.pos == caret }
        #expect(row.map { $0.y + v.lineHeight <= v.bounds.height + 0.5 } == true)
        // A cursor off screen doesn't pull the view to it.
        v.scroll(toLine: 300)
        v.fontSize = 12
        #expect(v.top.line == 300)
    }

    @Test func wrappedRowsFollowTheSize() {
        let text = (0..<40).map { _ in String(repeating: words, count: 2) }.joined(separator: "\n")
        let v = make(text, wrap: true)
        let rows = v.rowCount(0)
        v.scroll(by: v.lineHeight * CGFloat(rows * 3 + 1))
        let unit = v.rowFragment(v.top).u0
        v.fontSize = 20
        #expect(v.rowCount(0) > rows)
        #expect(v.top.line == 3)
        let f = v.rowFragment(v.top)
        #expect(f.u0 <= unit && unit < f.u1)
        for r in v.wrappedRows(0).dropLast() { #expect(r.x0 + r.width <= v.wrapWidth + v.charWidth) }
    }

    @Test func sidewaysScrollScales() {
        let line = String(repeating: words, count: 4)
        let v = make(line + "\n", cursor: 200)
        v.revealCursor()
        let scrollX = v.scrollX
        #expect(scrollX > 0)
        v.fontSize = 26
        let caretX = v.textX + v.caretX() - v.scrollX
        #expect(v.scrollX > scrollX)
        #expect(caretX >= v.textX && caretX <= v.bounds.width - v.scrollbarWidth)
    }

    /// Wrapped text at 20 pt with a selection. Set VIE_SNAPSHOT_DIR to write a PNG.
    @Test func rendersLargerText() throws {
        let text = "func greet() {\n\tprint(\"" + String(repeating: words, count: 2) + "\")\n}\n"
        let v = make(text, wrap: true, width: 520, height: 260)
        v.fontSize = 20
        v.focusedForTesting = true
        v.buffer.selection = Selection(anchor: 20, head: 70)
        let rep = try #require(v.bitmapImageRepForCachingDisplay(in: v.bounds))
        v.cacheDisplay(in: v.bounds, to: rep)
        if let dir = ProcessInfo.processInfo.environment["VIE_SNAPSHOT_DIR"], let png = rep.representation(using: .png, properties: [:]) {
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("font-size.png"))
        }
    }
}
