import AppKit
import Foundation
import Testing
import VieText
@testable import VieEditor

/// Drives the editor the way AppKit does: key binding commands (`doCommand(by:)` selectors)
/// and NSTextInputClient calls, then checks the buffer. No window needed.
@MainActor
@Suite struct EditorViewTests {
    /// Makes a view over `text`, where "|" marks the cursor (or "[" and "]" a selection:
    /// "[" is the anchor, "]" the head).
    private func make(_ text: String) -> EditorView {
        var s = text
        var anchor: Int?, head = 0
        if let open = s.firstIndex(of: "["), let close = s.firstIndex(of: "]") {
            let a = s.utf8.distance(from: s.startIndex, to: open)
            var h = s.utf8.distance(from: s.startIndex, to: close)
            if a < h { h -= 1 }
            s.remove(at: s.firstIndex(of: "[")!)
            s.remove(at: s.firstIndex(of: "]")!)
            anchor = a < h ? a : a - 1
            head = h
        } else if let bar = s.firstIndex(of: "|") {
            head = s.utf8.distance(from: s.startIndex, to: bar)
            s.remove(at: bar)
        }
        let buffer = Buffer(rope: Rope(s))
        buffer.selection = Selection(anchor: anchor ?? head, head: head)
        let view = EditorView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), buffer: buffer)
        view.pasteboard = NSPasteboard(name: NSPasteboard.Name("vie-test-\(UUID().uuidString)"))
        return view
    }

    /// The text with "|" at the cursor, or "[" anchor and "]" head around a selection.
    private func state(_ v: EditorView) -> String {
        var bytes = v.rope.bytes(in: 0..<v.rope.byteCount)
        let s = v.selection
        if s.isEmpty {
            bytes.insert(UInt8(ascii: "|"), at: s.head)
        } else {
            let marks: [(Int, UInt8)] = [(s.anchor, UInt8(ascii: "[")), (s.head, UInt8(ascii: "]"))].sorted { $0.0 > $1.0 }
            for (at, mark) in marks { bytes.insert(mark, at: at) }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private func run(_ v: EditorView, _ commands: String...) {
        for c in commands { v.doCommand(by: Selector(c)) }
    }

    @Test func arrowsMoveByCharacterCluster() {
        let v = make("a|👨‍👩‍👧b")
        run(v, "moveRight:")
        #expect(state(v) == "a👨‍👩‍👧|b")
        run(v, "moveLeft:", "moveLeft:")
        #expect(state(v) == "|a👨‍👩‍👧b")
    }

    @Test func upAndDownKeepTheColumn() {
        let v = make("abcdef|\nab\nabcdefgh")
        run(v, "moveDown:")
        #expect(state(v) == "abcdef\nab|\nabcdefgh")
        run(v, "moveDown:")
        #expect(state(v) == "abcdef\nab\nabcdef|gh")
        run(v, "moveDown:")
        #expect(state(v) == "abcdef\nab\nabcdefgh|")
        run(v, "moveToBeginningOfDocument:", "moveUp:")
        #expect(state(v) == "|abcdef\nab\nabcdefgh")
    }

    @Test func shiftArrowsExtendAndArrowsCollapse() {
        let v = make("one |two three")
        run(v, "moveWordRightAndModifySelection:", "moveRightAndModifySelection:")
        #expect(state(v) == "one [two ]three")
        run(v, "moveLeft:")
        #expect(state(v) == "one |two three")
        run(v, "moveToEndOfLineAndModifySelection:")
        #expect(state(v) == "one [two three]")
        run(v, "moveRight:")
        #expect(state(v) == "one two three|")
    }

    @Test func wordAndLineMovement() {
        let v = make("  foo.bar baz|")
        run(v, "moveWordLeft:")
        #expect(state(v) == "  foo.bar |baz")
        run(v, "moveWordLeft:", "moveWordLeft:")
        #expect(state(v) == "  |foo.bar baz")
        run(v, "moveToBeginningOfLine:")
        #expect(state(v) == "|  foo.bar baz")
        run(v, "moveWordRight:")
        #expect(state(v) == "  foo|.bar baz")
    }

    @Test func typingDeletingAndUndo() {
        let v = make("hello|")
        v.insertText(" world", replacementRange: NSRange(location: NSNotFound, length: 0))
        run(v, "deleteBackward:", "deleteWordBackward:")
        #expect(state(v) == "hello |")
        v.undo(nil)
        #expect(state(v) == "hello world|")
        v.undo(nil)
        #expect(state(v) == "hello|")
        v.redo(nil)
        #expect(state(v) == "hello world|")
    }

    @Test func newlineKeepsIndentation() {
        let v = make("    if x {|")
        run(v, "insertNewline:")
        #expect(state(v) == "    if x {\n    |")
        let w = make("  |  code")
        run(w, "insertNewline:")
        #expect(state(w) == "  \n  |  code")
    }

    @Test func tabInsertsToTheNextStop() {
        let v = make("ab|")
        run(v, "insertTab:")
        #expect(state(v) == "ab  |")
        v.indentation = .tabs
        run(v, "insertTab:")
        #expect(state(v) == "ab  \t|")
    }

    @Test func tabIndentsSelectedLines() {
        let v = make("[one\ntwo\n]three")
        run(v, "insertTab:")
        #expect(state(v) == "[    one\n    two\n]three")
        run(v, "insertBacktab:")
        #expect(state(v) == "[one\ntwo\n]three")
        v.undo(nil)
        #expect(state(v) == "[    one\n    two\n]three")
    }

    @Test func killAndYank() {
        let v = make("keep| this\nnext")
        run(v, "deleteToEndOfParagraph:")
        #expect(state(v) == "keep|\nnext")
        run(v, "deleteToEndOfParagraph:")
        #expect(state(v) == "keep|next")
        run(v, "moveToEndOfLine:", "yank:")
        #expect(state(v) == "keepnext\n|")
    }

    @Test func clipboard() {
        let v = make("[copy me] please")
        v.copy(nil)
        run(v, "moveToEndOfDocument:")
        v.paste(nil)
        #expect(state(v) == "copy me pleasecopy me|")
        run(v, "selectAll:")
        v.cut(nil)
        #expect(state(v) == "|")
        #expect(v.pasteboard.string(forType: .string) == "copy me pleasecopy me")
    }

    @Test func pasteNormalizesLineEndings() {
        let v = make("|")
        v.pasteboard.clearContents()
        v.pasteboard.setString("a\r\nb\rc", forType: .string)
        v.paste(nil)
        #expect(state(v) == "a\nb\nc|")
    }

    @Test func imeCompositionCommitsAsOneUndoStep() {
        let v = make("x [old] y")
        let none = NSRange(location: NSNotFound, length: 0)
        v.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0), replacementRange: none)
        #expect(state(v) == "x | y") // the selection is replaced; the composition isn't in the buffer yet
        #expect(v.hasMarkedText())
        #expect(v.markedRange() == NSRange(location: 2, length: 1))
        v.setMarkedText("日本", selectedRange: NSRange(location: 2, length: 0), replacementRange: none)
        #expect(v.attributedSubstring(forProposedRange: NSRange(location: 0, length: 6), actualRange: nil)?.string == "x 日本 y")
        v.insertText("日本", replacementRange: none)
        #expect(state(v) == "x 日本| y")
        #expect(!v.hasMarkedText())
        v.undo(nil)
        #expect(state(v) == "x [old] y")
    }

    @Test func accentMenuReplacesThePreviousCharacter() {
        let v = make("cafe|")
        v.insertText("é", replacementRange: NSRange(location: 3, length: 1))
        #expect(state(v) == "café|")
    }

    @Test func longLinesUseWindowedLayout() {
        let line = String(repeating: "abcdefghij", count: 2_000) // 20,000 characters
        let v = make("|" + line)
        run(v, "moveToEndOfLine:")
        #expect(v.selection.head == 20_000)
        #expect(v.scrollX > 0) // scrolled to show the cursor
        let x = v.x(of: 20_000)
        #expect(v.offset(atX: x, line: 0) == 20_000)
        let mid = v.x(of: 9_000)
        #expect(v.offset(atX: mid, line: 0) == 9_000)
        run(v, "moveToBeginningOfLine:")
        #expect(v.scrollX == 0)
    }

    /// Renders a view into a bitmap. Set VIE_SNAPSHOT_DIR to also write PNGs to look at.
    @Test func rendersSelectionAndText() throws {
        let v = make("func [hello() {\n    let 日本 = \"🚀\"\n}]\n// done")
        let rep = try #require(v.bitmapImageRepForCachingDisplay(in: v.bounds))
        v.cacheDisplay(in: v.bounds, to: rep)
        #expect(rep.pixelsWide > 0)
        if let dir = ProcessInfo.processInfo.environment["VIE_SNAPSHOT_DIR"],
           let png = rep.representation(using: .png, properties: [:]) {
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("editor-selection.png"))
        }
    }
}
