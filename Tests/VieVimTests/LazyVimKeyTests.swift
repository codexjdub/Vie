import Testing
import VieText
@testable import VieVim

/// Keys LazyVim adds to Vim: `gc` comments lines out and back in (as Neovim does), and ⌥J and
/// ⌥K move lines, the Visual ones staying selected.
@MainActor
@Suite struct LazyVimKeyTests {
    private func engine(_ text: String, marker: (String, String)? = ("//", ""), _ host: TestHost = TestHost()) -> VimEngine {
        let e = VimEngine(buffer: Buffer(rope: Rope(text)))
        e.host = host
        e.commentMarker = { marker.map { (start: $0.0, end: $0.1) } }
        return e
    }

    private func text(_ e: VimEngine) -> String { e.buffer.rope.string(in: 0..<e.buffer.rope.byteCount) }

    @Test func gccTogglesTheLine() {
        let e = engine("let a = 1\n    let b = 2\n")
        e.handle(keys: VimKey.parse("gcc"))
        #expect(text(e) == "// let a = 1\n    let b = 2\n")
        e.handle(keys: VimKey.parse("gcc"))
        #expect(text(e) == "let a = 1\n    let b = 2\n")
        e.handle(keys: VimKey.parse("2gcc"))
        #expect(text(e) == "// let a = 1\n//     let b = 2\n")
        e.handle(keys: VimKey.parse("u"))
        #expect(text(e) == "let a = 1\n    let b = 2\n")
    }

    /// The marker goes at the smallest indent; blank lines are left alone; lines already
    /// commented among others get a second marker; uncommenting takes one space after it.
    @Test func gcTakesAMotionAndTheSmallestIndent() {
        let e = engine("    a\n\n        b\n")
        e.handle(keys: VimKey.parse("gcG"))
        #expect(text(e) == "    // a\n\n    //     b\n")
        e.handle(keys: VimKey.parse("gcG"))
        #expect(text(e) == "    a\n\n        b\n")
        let mixed = engine("// a\nb\n")
        mixed.handle(keys: VimKey.parse("gcj"))
        #expect(text(mixed) == "// // a\n// b\n")
        let tight = engine("//a\n//  b\n")
        tight.handle(keys: VimKey.parse("gcip"))
        #expect(text(tight) == "a\n b\n")
    }

    @Test func gcInVisualModeAndRepeated() {
        let e = engine("a\nb\nc\nd\n")
        e.handle(keys: VimKey.parse("Vjgc"))
        #expect(text(e) == "// a\n// b\nc\nd\n" && e.mode == .normal)
        e.handle(keys: VimKey.parse("2j."))
        #expect(text(e) == "// a\n// b\n// c\n// d\n")
    }

    /// Markdown, HTML and CSS have only block comments: each line gets both ends.
    @Test func blockMarkersGoAroundEachLine() {
        let e = engine("# Title\nText  \n", marker: ("<!--", "-->"))
        e.handle(keys: VimKey.parse("gcj"))
        #expect(text(e) == "<!-- # Title -->\n<!-- Text -->  \n")
        e.handle(keys: VimKey.parse("gcj"))
        #expect(text(e) == "# Title\nText  \n")
    }

    @Test func noMarkerSaysSo() {
        let host = TestHost()
        let e = engine("{\"a\": 1}\n", marker: nil, host)
        e.handle(keys: VimKey.parse("gcc"))
        #expect(text(e) == "{\"a\": 1}\n" && host.beeps == 1)
        #expect(e.message == "This kind of file has no comment marker" && e.messageIsError)
    }

    @Test func altJAndKMoveTheLine() {
        let host = TestHost()
        let e = engine("a\n  b\nc\n", host)
        e.handle(keys: VimKey.parse("<M-j>"))
        #expect(text(e) == "  b\na\nc\n" && e.buffer.rope.line(at: e.cursor) == 1)
        e.handle(keys: VimKey.parse("<M-k>"))
        #expect(text(e) == "a\n  b\nc\n" && e.cursor == 0)
        e.handle(keys: VimKey.parse("2<M-j>"))
        #expect(text(e) == "  b\nc\na\n")
        e.handle(keys: VimKey.parse("<M-j>"))
        #expect(host.beeps == 1) // already at the end
        e.handle(keys: VimKey.parse("u"))
        #expect(text(e) == "a\n  b\nc\n")
    }

    @Test func altJAndKMoveTheVisualLinesAndKeepThemSelected() {
        let e = engine("a\nb\nc\nd\n")
        e.handle(keys: VimKey.parse("Vj<M-j>"))
        #expect(text(e) == "c\na\nb\nd\n" && e.mode == .visualLine)
        #expect(e.buffer.selection.range == 2..<6)
        e.handle(keys: VimKey.parse("<M-j>"))
        #expect(text(e) == "c\nd\na\nb\n" && e.buffer.selection.range == 4..<8)
        e.handle(keys: VimKey.parse("<M-k><M-k><Esc>"))
        #expect(text(e) == "a\nb\nc\nd\n" && e.mode == .normal)
    }
}
