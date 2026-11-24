import Foundation
import Testing
@testable import VieText

/// The Find bar's searches: text as typed or a regular expression, case, whole words, and
/// replacements; run over the rope a chunk at a time.
@Suite struct FindQueryTests {
    private func found(_ q: FindQuery, in text: String) -> [String] {
        let rope = Rope(text)
        guard let search = q.compiled() else { return [] }
        return search.allMatches(in: rope).map { String(decoding: rope.bytes(in: $0), as: UTF8.self) }
    }

    /// Text is found as typed (a dot is a dot), ignoring case unless asked.
    @Test func textAsTyped() {
        #expect(found(FindQuery("a.b"), in: "a.b axb A.B") == ["a.b", "A.B"])
        #expect(found(FindQuery("a.b", matchCase: true), in: "a.b axb A.B") == ["a.b"])
        #expect(found(FindQuery("(x)"), in: "f(x) + (x)") == ["(x)", "(x)"])
        #expect(FindQuery("").compiled() == nil)
    }

    /// Whole words: a match doesn't run on into a longer word at an end that is itself part of
    /// a word; an end that is punctuation can touch anything.
    @Test func wholeWords() {
        let text = "cat concat cat_x (cat) caté 2cat cat"
        #expect(found(FindQuery("cat", wholeWord: true), in: text) == ["cat", "cat", "cat"])
        #expect(found(FindQuery("(cat)", wholeWord: true), in: "x(cat)y (cat)") == ["(cat)", "(cat)"])
        #expect(found(FindQuery("(c", wholeWord: true), in: "(cat (c") == ["(c"])
        #expect(found(FindQuery("\\d+", wholeWord: true, regex: true), in: "a1 22 3b 4") == ["22", "4"])
    }

    /// Regular expressions use ICU's syntax; `$1` in the replacement is the first group. One
    /// that doesn't compile finds nothing.
    @Test func regularExpressions() throws {
        let q = FindQuery("c(a+)t", regex: true)
        #expect(found(q, in: "ct cat caat CAT") == ["cat", "caat", "CAT"])
        #expect(found(FindQuery("^b", regex: true), in: "ab\nbc\nb") == ["b", "b"])
        let rope = Rope("caat")
        let search = try #require(q.compiled())
        let m = try #require(search.matches(in: rope, 0..<rope.byteCount).first)
        #expect(q.replacement("<$1>", for: m, in: search) == "<aa>")
        #expect(FindQuery("c(a+)t").replacement("<$1>", for: m, in: search) == "<$1>")
        #expect(FindQuery("a(", regex: true).compiled() == nil)
    }

    /// Byte ranges come out right after multi-byte characters, and finding wraps around.
    @Test func findWrapsAndCountsBytes() throws {
        let text = "é x\nüü x\n"
        let rope = Rope(text)
        let search = try #require(FindQuery("x").compiled())
        let all = search.allMatches(in: rope)
        #expect(all == [3..<4, 10..<11]) // é is 2 bytes, each ü 2
        #expect(search.find(in: rope, from: 3, forward: true, wrap: true)?.0 == 10..<11)
        let wrapped = try #require(search.find(in: rope, from: 10, forward: true, wrap: true))
        #expect(wrapped.0 == 3..<4 && wrapped.wrapped)
        #expect(search.find(in: rope, from: 3, forward: false, wrap: true)?.0 == 10..<11)
        #expect(search.find(in: rope, from: 3, forward: true, wrap: true, acceptAt: true)?.0 == 3..<4)
    }

    /// A text of many chunks is counted whole, up to a limit, and can be stopped.
    @Test func countsAcrossChunks() throws {
        let line = String(repeating: "word ", count: 20) + "needle\n"
        let rope = Rope(String(repeating: line, count: 10_000)) // ~1 MB
        let search = try #require(FindQuery("needle").compiled())
        #expect(search.allMatches(in: rope).count == 10_000)
        #expect(search.allMatches(in: rope, limit: 50).count == 50)
        #expect(search.allMatches(in: rope) { true }.count < 10_000)
        var seen = 0
        search.forEachMatch(in: rope) { _ in
            seen += 1
            return seen < 7
        }
        #expect(seen == 7)
    }
}
