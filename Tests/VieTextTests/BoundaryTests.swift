import Testing
@testable import VieText

@Suite struct BoundaryTests {
    @Test func graphemeClusters() {
        // e + combining acute · family emoji (ZWJ sequence) · Japanese flag · a
        let text = "e\u{301}👨‍👩‍👧🇯🇵a"
        let r = Rope(text)
        var forward: [Int] = [0], off = 0
        while off < r.byteCount {
            off = r.nextGraphemeBoundary(after: off)
            forward.append(off)
        }
        let expected = [0] + text.indices.dropFirst().map { text.utf8.distance(from: text.startIndex, to: $0) } + [text.utf8.count]
        #expect(forward == expected)

        var backward: [Int] = [r.byteCount]
        off = r.byteCount
        while off > 0 {
            off = r.previousGraphemeBoundary(before: off)
            backward.append(off)
        }
        #expect(backward == expected.reversed())
    }

    @Test func graphemesStopAtNewlines() {
        let r = Rope("ab\n\ncd")
        #expect(r.nextGraphemeBoundary(after: 2) == 3)
        #expect(r.previousGraphemeBoundary(before: 4) == 3)
        #expect(r.previousGraphemeBoundary(before: 3) == 2)
    }

    @Test func flagsPairCorrectlyInLongLines() {
        let flags = String(repeating: "🇯🇵", count: 40) // 320 bytes, longer than the first window
        let r = Rope(flags)
        #expect(r.previousGraphemeBoundary(before: r.byteCount) == r.byteCount - 8)
        #expect(r.nextGraphemeBoundary(after: 8) == 16)
    }

    @Test func macWordMotion() {
        let r = Rope("foo.bar  baz_qux\n  next")
        #expect(r.wordEnd(after: 0) == 3)
        #expect(r.wordEnd(after: 3) == 7)
        #expect(r.wordEnd(after: 7) == 16)
        #expect(r.wordEnd(after: 16) == 23)
        #expect(r.wordStart(before: 23) == 19)
        #expect(r.wordStart(before: 19) == 9)
        #expect(r.wordStart(before: 9) == 4)
        #expect(r.wordStart(before: 3) == 0)
    }

    @Test func japaneseWordsSplitByScript() {
        let text = "日本語のテキスト"
        let r = Rope(text)
        let ends = [9, 12, 24] // 日本語 · の · テキスト
        var off = 0
        for e in ends {
            off = r.wordEnd(after: off)
            #expect(off == e)
        }
        #expect(r.wordRange(at: 15) == 12..<24)
    }

    @Test func doubleClickRanges() {
        let r = Rope("let total = a+b  \n\nend")
        #expect(r.wordRange(at: 5) == 4..<9) // total
        #expect(r.wordRange(at: 10) == 10..<11) // =
        #expect(r.wordRange(at: 13) == 13..<14) // +
        #expect(r.wordRange(at: 15) == 15..<17) // trailing spaces
        #expect(r.wordRange(at: 17) == 15..<17) // end of line uses the character before
        #expect(r.wordRange(at: 18) == 18..<19) // empty line selects its newline
        #expect(r.wordRange(at: 22) == 19..<22) // end of text
    }

    @Test func combiningMarksStayInWords() {
        let text = "cafe\u{301} ok"
        let r = Rope(text)
        #expect(r.wordEnd(after: 0) == 6)
        #expect(r.wordRange(at: 2) == 0..<6)
    }

    @Test func indentationDetection() {
        #expect(Indentation.detect(in: Rope("a\n\tb\n\t\tc\n")) == .tabs)
        #expect(Indentation.detect(in: Rope("a\n  b\n    c\n  d\n")) == .spaces(2))
        #expect(Indentation.detect(in: Rope("a {\n    b {\n        c\n    }\n}\n")) == .spaces(4))
        #expect(Indentation.detect(in: Rope("plain\ntext\n")) == nil)
    }

    @Test func lineHelpers() {
        let r = Rope("  one\n\ttwo\nthree")
        #expect(r.lineRange(at: 3) == 0..<6)
        #expect(r.lineRange(at: 13) == 11..<16)
        #expect(r.indentation(ofLineContaining: 4) == Array("  ".utf8))
        #expect(r.indentation(ofLineContaining: 8) == [0x09])
        #expect(r.indentation(ofLineContaining: 12).isEmpty)
    }
}
