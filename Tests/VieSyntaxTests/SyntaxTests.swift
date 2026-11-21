import Foundation
import Testing
import VieText
@testable import VieSyntax

@Suite struct LanguageTests {
    /// A query that references a node type the grammar doesn't have fails as a whole, so
    /// every bundled language's queries must compile.
    @Test(arguments: SyntaxLanguage.all.map(\.name))
    func queriesCompile(_ name: String) throws {
        let language = try #require(SyntaxLanguage.named(name))
        #expect(language.queryErrors == [])
        #expect(language.highlights != nil)
    }

    @Test func filesAreRecognized() {
        func name(_ file: String, _ firstLine: String? = nil) -> String? { SyntaxLanguage.forFile(named: file, firstLine: firstLine)?.name }
        #expect(name("main.swift") == "swift")
        #expect(name("Package.swift") == "swift")
        #expect(name("README.md") == "markdown")
        #expect(name("app.TSX") == "tsx")
        #expect(name("lib.rs") == "rust")
        #expect(name("x.h") == "c")
        #expect(name("x.hpp") == "cpp")
        #expect(name(".zshrc") == "bash")
        #expect(name("Cargo.lock") == "toml")
        #expect(name("notes.txt") == nil)
        #expect(name("build", "#!/usr/bin/env python3") == "python")
        #expect(name("run", "#!/bin/zsh -f") == "bash")
        #expect(name("serve", "#!/usr/bin/env -S node --flag") == "javascript")
        #expect(name("data", "plain text") == nil)
        #expect(SyntaxLanguage.named("JS")?.name == "javascript")
        #expect(SyntaxLanguage.named(" c++ ")?.name == "cpp")
    }

    @Test func captureNamesMapByLongestPrefix() {
        #expect(Highlight(captureName: "keyword") == .keyword)
        #expect(Highlight(captureName: "keyword.import") == .keyword)
        #expect(Highlight(captureName: "function.method.call") == .function)
        #expect(Highlight(captureName: "function.builtin") == .builtinFunction)
        #expect(Highlight(captureName: "string.special.key") == .property)
        #expect(Highlight(captureName: "string.special.url") == .escape)
        #expect(Highlight(captureName: "variable") == Highlight.none)
        #expect(Highlight(captureName: "variable.parameter") == .parameter)
        #expect(Highlight(captureName: "_name") == nil)
        #expect(Highlight(captureName: "injection.content") == nil)
        #expect(Highlight(captureName: "spell") == nil)
    }
}

@MainActor
@Suite struct HighlighterTests {
    private func highlighter(_ language: String, _ text: String) async throws -> SyntaxHighlighter {
        let h = SyntaxHighlighter(language: try #require(SyntaxLanguage.named(language)), rope: Rope(text))
        try await settle(h)
        #expect(h.isReady)
        return h
    }

    /// Waits for parses in flight to land.
    private func settle(_ h: SyntaxHighlighter) async throws {
        for _ in 0..<200 {
            try await Task.sleep(for: .milliseconds(5))
            if h.isReady && !h.isParsing { return }
        }
    }

    /// The highlight covering all of `needle`'s first occurrence (after `after`), or nil.
    private func kind(_ h: SyntaxHighlighter, _ text: String, _ needle: String, after: String = "") -> Highlight? {
        let start = text.range(of: after).map { text.utf8.distance(from: text.startIndex, to: $0.upperBound) } ?? 0
        let tail = String(text.utf8.dropFirst(start))!
        guard let r = tail.range(of: needle) else { return nil }
        let lo = start + tail.utf8.distance(from: tail.startIndex, to: r.lowerBound), hi = lo + needle.utf8.count
        let spans = h.spans(in: 0..<text.utf8.count)
        guard let s = spans.first(where: { $0.range.contains(lo) }), s.range.upperBound >= hi else { return Highlight.none }
        return s.highlight
    }

    @Test func swift() async throws {
        let text = "import Foundation\nlet count = 42 // answer\nfunc greet(name: String) -> String { \"hi \\(name)\" }\n"
        let h = try await highlighter("swift", text)
        #expect(kind(h, text, "import") == .keyword)
        #expect(kind(h, text, "let") == .keyword)
        #expect(kind(h, text, "42") == .number)
        #expect(kind(h, text, "// answer") == .comment)
        #expect(kind(h, text, "func") == .keyword)
        #expect(kind(h, text, "greet") == .function)
        #expect(kind(h, text, "String") == .type)
        #expect(kind(h, text, "\"hi ") == .string)
    }

    @Test func spansStayInsideTheRequestedRange() async throws {
        let text = "let a = \"a long string literal\"\n"
        let h = try await highlighter("swift", text)
        let spans = h.spans(in: 12..<20)
        #expect(spans == [HighlightSpan(range: 12..<20, highlight: .string)])
    }

    /// Lines are served from a window highlighted around an earlier request; wherever that
    /// window starts, a line gets the same spans.
    @Test func windowedSpansDontDependOnTheWindow() async throws {
        let line = "    let message = \"hello, \\(name)\" + String(count * 42) // note\n"
        let text = "func f(name: String, count: Int) {\n" + String(repeating: line, count: 400) + "}\n"
        let rope = Rope(text)
        let forward = try await highlighter("swift", text)
        let backward = try await highlighter("swift", text)
        let lines = 0..<rope.lineCount - 1
        let ahead = lines.map { forward.spans(in: rope.offset(ofLine: $0)..<rope.lineEnd($0)) }
        let behind = lines.reversed().map { backward.spans(in: rope.offset(ofLine: $0)..<rope.lineEnd($0)) }.reversed()
        #expect(ahead == Array(behind))
        #expect(ahead[200].contains { $0.highlight == .comment })
        // A range crossing where a window ended.
        let wide = rope.offset(ofLine: 10)..<rope.offset(ofLine: 150)
        #expect(forward.spans(in: wide) == Array(ahead[10..<150].joined()))
    }

    @Test func editsReparse() async throws {
        let buffer = Buffer(rope: Rope("let a = 1\nlet b = 2\n"))
        let h = SyntaxHighlighter(language: try #require(SyntaxLanguage.named("swift")), rope: buffer.rope)
        var reported: [Range<Int>] = []
        h.onChange = { reported += $0 }
        try await settle(h)
        let text = { buffer.rope.string(in: 0..<buffer.rope.byteCount) }
        #expect(kind(h, text(), "let", after: "\n") == .keyword)
        // Commenting out the second line, then uncommenting it.
        let token = NSObject()
        buffer.addObserver(token) { change in h.update(rope: buffer.rope, edits: change.edits) }
        buffer.replace(10..<10, with: Array("// ".utf8))
        try await settle(h)
        #expect(kind(h, text(), "let", after: "\n") == .comment)
        #expect(reported.contains { $0.contains(15) })
        buffer.replace(10..<13, with: [])
        try await settle(h)
        #expect(kind(h, text(), "let", after: "\n") == .keyword)
        buffer.removeObserver(token)
    }

    @Test func markdownInjectsInlineMarkupAndCode() async throws {
        let text = "# Title here\n\nSome *em* and `code` text.\n\n```swift\nlet x = 1\n```\n\n> quoted **strong**\n> line\n"
        let h = try await highlighter("markdown", text)
        #expect(kind(h, text, "Title here") == .heading)
        #expect(kind(h, text, "em", after: "Some *") == .emphasis)
        #expect(kind(h, text, "code", after: "`") == .literal)
        #expect(kind(h, text, "let") == .keyword)
        #expect(kind(h, text, "x =", after: "let ") == Highlight.none)
        #expect(kind(h, text, "strong", after: "**") == .strong)
        #expect(kind(h, text, "Some") == Highlight.none)
    }

    @Test func htmlInjectsScriptAndStyle() async throws {
        let text = "<p class=\"a\">Hi</p>\n<script>const n = 1;</script>\n<style>p { color: red; }</style>\n"
        let h = try await highlighter("html", text)
        #expect(kind(h, text, "p", after: "<") == .tag)
        #expect(kind(h, text, "class") == .attribute)
        #expect(kind(h, text, "const") == .keyword)
        #expect(kind(h, text, "1") == .number)
        #expect(kind(h, text, "color") == .property)
    }

    @Test(arguments: [
        ("bash", "echo \"hi\" # note\n", "echo", Highlight.function),
        ("c", "int main(void) { return 0; }\n", "return", .keyword),
        ("cpp", "class A { public: int x; };\n", "class", .keyword),
        ("css", "a { color: red; }\n", "color", .property),
        ("go", "package main\nfunc f() {}\n", "func", .keyword),
        ("javascript", "const x = () => 1;\n", "const", .keyword),
        ("json", "{\"a\": 1}\n", "1", .number),
        ("python", "def f():\n    return None\n", "def", .keyword),
        ("rust", "fn main() { let x = 1; }\n", "fn", .keyword),
        ("toml", "[package]\nname = \"vie\"\n", "\"vie\"", .string),
        ("tsx", "const a = <div>x</div>;\n", "div", .tag),
        ("typescript", "let a: number = 1;\n", "number", .builtinType),
        ("yaml", "key: value # c\n", "# c", .comment),
    ])
    func everyLanguageHighlights(_ language: String, _ text: String, _ needle: String, _ expected: Highlight) async throws {
        let h = try await highlighter(language, text)
        #expect(kind(h, text, needle) == expected)
    }
}

@Suite struct EditSpanTests {
    private func edit(_ range: Range<Int>, _ newLength: Int) -> TextEdit { TextEdit(range: range, newLength: newLength, insertsNewline: false) }

    @Test func oneEditIsExact() throws {
        let s = try #require(SyntaxHighlighter.span(of: [edit(5..<8, 2)]))
        #expect(s.start == 5 && s.oldEnd == 8 && s.newEnd == 7)
    }

    @Test func severalEditsAreCovered() throws {
        // Applied last to first, as Buffer does: 20..<22 → 5 bytes, then 2..<3 → 0 bytes.
        let s = try #require(SyntaxHighlighter.span(of: [edit(20..<22, 5), edit(2..<3, 0)]))
        #expect(s.start == 2 && s.oldEnd == 22 && s.newEnd == 24)
        // In order: 2..<3 → 0 bytes, then (in the shorter text) 19..<21 → 5 bytes.
        let t = try #require(SyntaxHighlighter.span(of: [edit(2..<3, 0), edit(19..<21, 5)]))
        #expect(t.start == 2 && t.oldEnd == 22 && t.newEnd == 24)
        // Nested: replace 10..<20 with 4, then insert 3 inside the new text.
        let u = try #require(SyntaxHighlighter.span(of: [edit(10..<20, 4), edit(12..<12, 3)]))
        #expect(u.start == 10 && u.oldEnd == 20 && u.newEnd == 17)
    }
}
