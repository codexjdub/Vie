import AppKit
import Foundation
import Testing
import VieText
import VieVim
@testable import VieEditor

/// Soft wrap: rows, positions on them, scrolling by rows from a line anchor, and the switch.
@MainActor
@Suite struct WrapTests {
    private let words = "the quick brown fox jumps over the lazy dog and keeps running past the old mill "

    private func make(_ text: String, width: CGFloat = 400, height: CGFloat = 200, cursor: Int = 0) -> EditorView {
        let buffer = Buffer(rope: Rope(text))
        buffer.selection = Selection(cursor)
        let v = EditorView(frame: NSRect(x: 0, y: 0, width: width, height: height), buffer: buffer)
        v.wrapsLines = true
        return v
    }

    @Test func longLinesWrapAtWordsWithinTheWidth() {
        let line = String(repeating: words, count: 3)
        let v = make(line + "\nshort\n")
        let rows = v.wrappedRows(0)
        #expect(rows.count > 3)
        #expect(v.rowCount(1) == 1)
        // Contiguous, each row within the width, breaks after spaces.
        #expect(rows.first?.u0 == 0 && rows.last?.u1 == line.utf16.count)
        for (a, b) in zip(rows, rows.dropFirst()) { #expect(a.u1 == b.u0) }
        let units = Array(line.utf16)
        for r in rows.dropLast() {
            #expect(r.x0 + r.width <= v.wrapWidth + v.charWidth)
            #expect(units[r.u1 - 1] == 0x20)
        }
    }

    @Test func rowsAfterTheFirstKeepTheIndent() {
        let v = make("        " + String(repeating: words, count: 2))
        let rows = v.wrappedRows(0)
        #expect(rows.count > 1)
        #expect(rows[0].x0 == 0)
        #expect(abs(rows[1].x0 - 8 * v.charWidth) < 0.5)
    }

    @Test func veryLongLinesWrapByColumnsLazily() {
        let line = String(repeating: "x", count: 20_000)
        let v = make(line)
        let cols = v.wrapColumns
        #expect(v.rowCount(0) == (20_000 + cols - 1) / cols)
        let f = v.rowFragment(RowPosition(line: 0, row: 50))
        #expect(f.u0 == 50 * cols && f.u1 == 51 * cols)
        #expect(v.lines[0]?.rows == nil)
        #expect(v.lines[0]?.longRows.count == 1)
        // A caret deep in the line lands on its row.
        #expect(v.place(50 * cols + 3, line: 0).row == 50)
    }

    @Test func noSidewaysScrolling() {
        let line = String(repeating: words, count: 4)
        let v = make(line, cursor: line.utf8.count)
        v.revealCursor()
        #expect(v.scrollX == 0 && v.maxScrollX == 0)
        let end = v.rowPosition(of: line.utf8.count)
        #expect(end.row == v.rowCount(0) - 1)
    }

    @Test func arrowsAndClicksGoByRows() {
        let line = String(repeating: words, count: 3)
        let v = make(line + "\nnext\n", cursor: 4)
        v.doCommand(by: #selector(NSResponder.moveDown(_:)))
        let p = v.rowPosition(of: v.selection.head)
        #expect(p == RowPosition(line: 0, row: 1))
        // The column is kept (monospaced text).
        #expect(abs(v.x(of: v.selection.head) - v.x(of: 4)) < v.charWidth)
        v.doCommand(by: #selector(NSResponder.moveUp(_:)))
        #expect(v.selection.head == 4)
        // A click in the second row, and past the end of a row that wraps.
        let x = v.textX + v.charWidth * 2.2
        let hit = v.offset(at: NSPoint(x: x, y: v.lineHeight * 1.5))
        #expect(v.rowPosition(of: hit) == RowPosition(line: 0, row: 1))
        let past = v.offset(at: NSPoint(x: v.bounds.width - 12, y: v.lineHeight * 0.5))
        #expect(v.rowPosition(of: past) == RowPosition(line: 0, row: 0))
    }

    @Test func scrollingWalksRowsAndStopsAtTheEnd() {
        let text = (0..<40).map { _ in String(repeating: words, count: 2) }.joined(separator: "\n")
        let v = make(text)
        let perLine = v.rowCount(0)
        #expect(perLine > 1)
        v.scroll(by: v.lineHeight * CGFloat(perLine + 1))
        #expect(v.top == RowPosition(line: 1, row: 1))
        v.scroll(by: -v.lineHeight * 0.5)
        #expect(v.top == RowPosition(line: 1, row: 0) && abs(v.topOffset - v.lineHeight / 2) < 0.01)
        v.scroll(by: 1_000_000)
        let rows = v.visibleRows()
        let last = rows.last!
        #expect(last.pos == RowPosition(line: 39, row: v.rowCount(39) - 1))
        #expect(abs(last.y + v.lineHeight - v.bounds.height) < 0.5)
        v.scroll(toLine: 0)
        #expect(v.top == RowPosition(line: 0, row: 0) && v.topOffset == 0)
    }

    @Test func revealingTheCursorShowsItsRow() {
        let text = (0..<40).map { _ in String(repeating: words, count: 2) }.joined(separator: "\n")
        let v = make(text)
        v.doCommand(by: #selector(NSResponder.moveToEndOfDocument(_:)))
        let rows = v.visibleRows()
        let caret = v.rowPosition(of: v.selection.head)
        let shown = rows.first { $0.pos == caret }
        #expect(shown != nil)
        #expect(shown.map { $0.y + v.lineHeight <= v.bounds.height + 0.5 } == true)
        v.doCommand(by: #selector(NSResponder.moveToBeginningOfDocument(_:)))
        #expect(v.top == RowPosition(line: 0, row: 0))
    }

    @Test func editsAboveTheViewKeepWhatsShown() {
        let text = (0..<300).map { "line \($0)" }.joined(separator: "\n")
        let v = make(text)
        v.scroll(toLine: 100)
        v.buffer.edit([Change(0..<0, "new\nlines\n")], selection: Selection(200 * 8), kind: .other)
        #expect(v.top.line == 102)
        v.buffer.edit([Change(0..<v.rope.offset(ofLine: 3), "")], selection: Selection(0), kind: .other)
        #expect(v.top.line == 99)
    }

    @Test func resizingWrapsAgainKeepingTheTopText() {
        let text = (0..<30).map { _ in String(repeating: words, count: 2) }.joined(separator: "\n")
        let v = make(text, width: 400)
        v.scroll(by: v.lineHeight * CGFloat(v.rowCount(0) + 2))
        let unit = v.rowFragment(v.top).u0
        let narrow = v.rowCount(1)
        v.setFrameSize(NSSize(width: 800, height: 200))
        #expect(v.rowCount(1) < narrow)
        let f = v.rowFragment(v.top)
        #expect(f.u0 <= unit && unit <= f.u1)
    }

    @Test func turningWrapOffScrollsSideways() {
        let line = String(repeating: words, count: 4)
        let v = make(line, cursor: line.utf8.count)
        v.wrapsLines = false
        #expect(v.rowCount(0) == 1)
        #expect(v.scrollX > 0)
        v.wrapsLines = true
        #expect(v.scrollX == 0)
    }

    @Test func vimSetWrapAndVisibleLines() {
        let text = (0..<30).map { _ in String(repeating: words, count: 2) }.joined(separator: "\n")
        let v = make(text, height: 200)
        v.vimEnabled = true
        #expect(v.vim?.options.wrap == true)
        let shown = v.visibleLines
        let rowsPerLine = v.rowCount(0)
        #expect(shown.count == Int(v.bounds.height / v.lineHeight) / rowsPerLine)
        v.vim?.handle(keys: VimKey.parse(":set nowrap<CR>"))
        #expect(!v.wrapsLines)
        v.vim?.handle(keys: VimKey.parse(":set wrap<CR>"))
        #expect(v.wrapsLines)
        // j moves by lines, as in Vim.
        v.vim?.handle(keys: VimKey.parse("j"))
        #expect(v.rope.line(at: v.vim!.cursor) == 1)
    }

    /// A wrapped paragraph with a selection across a wrap point. Set VIE_SNAPSHOT_DIR to write a PNG.
    @Test func rendersWrappedText() throws {
        let text = "func greet() {\n    " + String(repeating: words, count: 3) + "\n}\n" + String(repeating: "y", count: 300) + "\n"
        let v = make(text, width: 420, height: 260)
        v.focusedForTesting = true
        let start = text.utf8.count / 5
        v.buffer.selection = Selection(anchor: start, head: start + 60)
        let rep = try #require(v.bitmapImageRepForCachingDisplay(in: v.bounds))
        v.cacheDisplay(in: v.bounds, to: rep)
        if let dir = ProcessInfo.processInfo.environment["VIE_SNAPSHOT_DIR"], let png = rep.representation(using: .png, properties: [:]) {
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("wrap.png"))
        }
    }
}
