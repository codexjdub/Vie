import Foundation
import Testing
import VieText
@testable import VieSyntax

@Suite struct LanguageTests {
    /// Neovim's queries match with Lua patterns (`#lua-match?`), translated to ICU regexes.
    @Test func luaPatternsBecomeRegexes() throws {
        func matches(_ lua: String, _ text: String) throws -> Bool {
            let pattern = try #require(Query.regex(fromLuaPattern: lua))
            let re = try NSRegularExpression(pattern: pattern, options: .dotMatchesLineSeparators)
            return re.firstMatch(in: text, range: NSRange(location: 0, length: text.utf16.count)) != nil
        }
        // The LaTeX query's: `\if…` commands and `% !TeX` lines.
        #expect(try Query.regex(fromLuaPattern: #"^\if[a-zA-Z@]+$"#) == #"^\\if[a-zA-Z@]+\z"#)
        #expect(try matches(#"^\if[a-zA-Z@]+$"#, #"\ifx"#) && matches(#"^\if[a-zA-Z@]+$"#, #"\if@tempswa"#))
        #expect(try !matches(#"^\if[a-zA-Z@]+$"#, #"\if"#) && !matches(#"^\if[a-zA-Z@]+$"#, #"\iffy1"#))
        #expect(try matches("^%% !TeX", "% !TeX program = xelatex") && !matches("^%% !TeX", "%% !TeX"))
        #expect(try matches("^%%&", "%&pdflatex"))
        // Classes, complements, escapes, the lazy repeat, and anchors only at the ends.
        #expect(try matches("^%d+%.%d+$", "1.25") && !matches("^%d+%.%d+$", "1x25"))
        #expect(try matches("^[%w_]+$", "snake_case2") && !matches("^[%w_]+$", "a-b"))
        #expect(try matches("^%S+$", "a.b") && !matches("^%S+$", "a b"))
        #expect(try matches("^[^%s]+$", "x") && !matches("^[^%s]+$", " "))
        #expect(try matches("^a.-b$", "axxb") && matches("^%u%l*$", "Word"))
        #expect(try matches("a^b", "a^b") && matches("a$b", "a$b") && matches("^{|}$", "{|}"))
        #expect(try matches("^[]x]$", "]") && matches("^[%]]$", "]") && matches("^[\\]$", #"\"#))
        // No ICU equivalent.
        #expect(Query.regex(fromLuaPattern: "%b()") == nil)
        #expect(Query.regex(fromLuaPattern: "%f[%w]") == nil)
        #expect(Query.regex(fromLuaPattern: "abc%") == nil)
        #expect(Query.regex(fromLuaPattern: "[abc") == nil)
    }

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
        #expect(name("paper.tex") == "latex")
        #expect(name("thesis.cls") == "latex")
        #expect(name("macros.sty") == "latex")
        #expect(name("refs.bib") == "bibtex")
        #expect(SyntaxLanguage.named("tex")?.name == "latex") // Vim's filetype, and code fences
        #expect(SyntaxLanguage.named("bib")?.name == "bibtex")
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
        #expect(Highlight(captureName: "boolean") == .boolean)
        #expect(Highlight(captureName: "constant.builtin") == .builtinConstant)
        #expect(Highlight(captureName: "punctuation.bracket") == .bracket)
        #expect(Highlight(captureName: "punctuation.delimiter") == .punctuation)
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
        for _ in 0..<2000 {
            try await Task.sleep(for: .milliseconds(5))
            if h.isReady && !h.isParsing { return }
        }
    }

    /// A Markdown file's headings, for the Outline: `#` lines and underlined ones, in nested
    /// sections, with their levels and their text without the marks. Not a `#` in a paragraph,
    /// a code block, a quote or a list; other languages have none.
    @Test func markdownHeadings() async throws {
        let text = """
        # Title

        Intro with # not a heading.

        ## Install ##

        ```sh
        # a comment, not a heading
        ```

        Setext two
        ----------

        > # quoted

        - # in a list

        ### Deep `code` *em*
        #
        Top
        again
        =====

        """
        let h = try await highlighter("markdown", text)
        let headings = h.markdownHeadings()
        #expect(headings.map(\.level) == [1, 2, 2, 3, 1, 1])
        #expect(headings.map(\.title) == ["Title", "Install", "Setext two", "Deep `code` *em*", "", "Top again"])
        let install = try #require(text.range(of: "## Install"))
        #expect(headings.first?.offset == 0 && headings[1].offset == text.utf8.distance(from: text.startIndex, to: install.lowerBound))
        #expect(try await highlighter("swift", "// # not markdown\n").markdownHeadings().isEmpty)
        #expect(SyntaxHighlighter.headingTitle("Install ##") == "Install" && SyntaxHighlighter.headingTitle("C# 12") == "C# 12")
    }

    /// A parse that finished while the main thread was busy (as AppKit keeps it after launch)
    /// is taken in before the next frame, without waiting for the main queue.
    @Test func finishedParseLandsWithoutTheMainQueue() throws {
        let h = SyntaxHighlighter(language: try #require(SyntaxLanguage.named("swift")), rope: Rope("let x = 1\n"))
        let deadline = Date().addingTimeInterval(5)
        while !h.isReady && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.005) // keeps the main queue from running
            h.landFinishedParse()
        }
        #expect(h.isReady && !h.isParsing)
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

    /// Whether all of `needle`'s first occurrence (after `after`) is struck through.
    private func isStruck(_ h: SyntaxHighlighter, _ text: String, _ needle: String, after: String = "") -> Bool {
        let start = text.range(of: after).map { text.utf8.distance(from: text.startIndex, to: $0.upperBound) } ?? 0
        let tail = String(text.utf8.dropFirst(start))!
        guard let r = tail.range(of: needle) else { return false }
        let lo = start + tail.utf8.distance(from: tail.startIndex, to: r.lowerBound)
        let struck = h.spans(in: 0..<text.utf8.count).filter(\.struck)
        return (lo..<lo + needle.utf8.count).allSatisfy { i in struck.contains { $0.range.contains(i) } }
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

    /// Neovim's rules with Vie's additions: list markers and task boxes, finished tasks
    /// dimmed and struck through, tables, strikethrough and quotes.
    @Test func markdownListsTablesAndQuotes() async throws {
        let text = """
            - [ ] open task
            - [x] done task *still em*
              - sub item

            | Name | Size |
            |------|------|
            | a    | 1    |

            Some ~~old~~ text.

            > quoted words
            """ + "\n"
        let h = try await highlighter("markdown", text)
        #expect(kind(h, text, "-") == .specialPunctuation)
        #expect(kind(h, text, "[ ]") == .specialPunctuation)
        #expect(kind(h, text, "open task") == Highlight.none)
        #expect(kind(h, text, "[x]") == .comment)
        #expect(kind(h, text, "done task") == .comment)
        #expect(kind(h, text, "still em") == .emphasis)
        #expect(kind(h, text, "sub item") == Highlight.none)
        // The line runs through the done item's text, markup in it included, not its box.
        #expect(isStruck(h, text, "done task *still em*"))
        #expect(!isStruck(h, text, "[x]") && !isStruck(h, text, "open task") && !isStruck(h, text, "sub item"))
        #expect(kind(h, text, "Name") == .heading)
        #expect(kind(h, text, "|", after: "Name ") == .specialPunctuation)
        #expect(kind(h, text, "------") == .specialPunctuation)
        #expect(kind(h, text, "a", after: "|------|\n| ") == Highlight.none)
        #expect(kind(h, text, "old") == Highlight.none)
        #expect(isStruck(h, text, "~~old~~") && !isStruck(h, text, "text."))
        #expect(kind(h, text, "quoted words") == .emphasis)
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
        ("bibtex", "@article{knuth84,\n  year = 1984,\n}\n", "@article", .keyword),
        ("c", "int main(void) { return 0; }\n", "return", .keyword),
        ("cpp", "class A { public: int x; };\n", "class", .keyword),
        ("css", "a { color: red; }\n", "color", .property),
        ("go", "package main\nfunc f() {}\n", "func", .keyword),
        ("javascript", "const x = () => 1;\n", "const", .keyword),
        ("json", "{\"a\": 1}\n", "1", .number),
        ("latex", "\\section{Intro}\n", "Intro", .heading),
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

    /// A Markdown document with every kind of injection: front matter, inline markup in
    /// paragraphs, headings, items and quotes, inline HTML and math, and code blocks.
    private static let markdownSample = #"""
        ---
        title: Sample
        ---
        # Heading with `code`

        A paragraph with **bold**, *italic*, `code`, a [link](https://example.com) and <kbd>K</kbd>.
        Math like $x^2$ too.

        - an item with **bold**
        - [ ] a task

        > A quote with *emphasis*.

        ```swift
        let x = 42 // answer
        func f() -> Int { x }
        ```

        <div>
        <b>html</b>
        </div>

        ```python
        def g():
            return "py"
        ```

        Last paragraph, *done*.

        """#

    /// Reusing layers and reparsing edited ones from their old trees must give what a fresh
    /// parse of the same text gives, through random edits: typing, deleting, opening and
    /// closing code fences, some while a parse runs.
    @Test(arguments: [7, 21] as [UInt64])
    func reusedLayersMatchAFreshParse(seed: UInt64) async throws {
        var rope = Rope(Self.markdownSample)
        let h = SyntaxHighlighter(language: try #require(SyntaxLanguage.named("markdown")), rope: rope)
        try await settle(h)
        var rng = SplitMix(seed: seed)
        let snippets = ["x", " ", "**", "*", "`", "\n", "\n\n", "```\n", "```swift\n", "$", "<b>", "[a](b)", "> ", "- ", "# "]
        for step in 1...240 {
            let count = rope.byteCount
            if rng.next(4) == 0 && count > 10 {
                let at = rng.next(count - 1), n = min(1 + rng.next(5), count - at)
                rope.delete(at..<at + n)
                h.update(rope: rope, edits: [TextEdit(range: at..<at + n, newLength: 0, insertsNewline: false)])
            } else {
                let text = snippets[rng.next(snippets.count)], at = rng.next(count + 1)
                rope.insert(Array(text.utf8), at: at)
                h.update(rope: rope, edits: [TextEdit(range: at..<at, newLength: text.utf8.count, insertsNewline: text.contains("\n"))])
            }
            // Mostly in bursts, so edits also land while a parse runs.
            if step % 3 == 0 { try await settle(h) }
            if step % 20 == 0 {
                try await settle(h)
                let fresh = try await highlighter("markdown", rope.string(in: 0..<rope.byteCount))
                #expect(h.spans(in: 0..<rope.byteCount) == fresh.spans(in: 0..<rope.byteCount), "after \(step) edits")
                #expect(h.layerCount == fresh.layerCount, "after \(step) edits")
            }
        }
    }

    /// The same for HTML, whose scripts and styles are layers that edits elsewhere leave alone
    /// and edits inside reparse.
    @Test(arguments: [11, 29] as [UInt64])
    func reusedLayersMatchAFreshParseInHTML(seed: UInt64) async throws {
        var text = "<!doctype html>\n<html><head><style>\n"
        for i in 0..<20 { text += ".c\(i) { margin: \(i)px; color: red; }\n" }
        text += "</style></head><body>\n<p>Hello <b>there</b></p>\n<script>\n"
        for i in 0..<30 { text += "function f\(i)(a) { const s = `x${a}`; return a + \(i); } // note\n" }
        text += "</script>\n<p>End</p>\n</body></html>\n"
        var rope = Rope(text)
        let h = SyntaxHighlighter(language: try #require(SyntaxLanguage.named("html")), rope: rope)
        try await settle(h)
        var rng = SplitMix(seed: seed)
        let snippets = ["x", " ", "{", "}", "(", ")", "\"", "'", "`", "/*", "*/", "//", "\n", ";", "<", ">", "</script>", "<script>", "=>"]
        for step in 1...240 {
            let count = rope.byteCount
            if rng.next(4) == 0 && count > 10 {
                let at = rng.next(count - 1), n = min(1 + rng.next(5), count - at)
                rope.delete(at..<at + n)
                h.update(rope: rope, edits: [TextEdit(range: at..<at + n, newLength: 0, insertsNewline: false)])
            } else {
                let s = snippets[rng.next(snippets.count)], at = rng.next(count + 1)
                rope.insert(Array(s.utf8), at: at)
                h.update(rope: rope, edits: [TextEdit(range: at..<at, newLength: s.utf8.count, insertsNewline: s.contains("\n"))])
            }
            if step % 3 == 0 { try await settle(h) }
            if step % 20 == 0 {
                try await settle(h)
                let fresh = try await highlighter("html", rope.string(in: 0..<rope.byteCount))
                #expect(h.spans(in: 0..<rope.byteCount) == fresh.spans(in: 0..<rope.byteCount), "after \(step) edits")
                #expect(h.layerCount == fresh.layerCount, "after \(step) edits")
            }
        }
    }

    /// Typing in one paragraph parses that paragraph's layer again, not the others; typing in
    /// a code block, that block's.
    @Test func typingReparsesOnlyTheEditedLayer() async throws {
        let text = String(repeating: "Some **bold** text and `code`.\n\n", count: 50) + "```swift\nlet x = 1\n```\n"
        var rope = Rope(text)
        let h = SyntaxHighlighter(language: try #require(SyntaxLanguage.named("markdown")), rope: rope)
        try await settle(h)
        #expect(h.layerCount == 51)
        func type(at off: Int) async throws {
            rope.insert(Array("x".utf8), at: off)
            h.update(rope: rope, edits: [TextEdit(range: off..<off, newLength: 1, insertsNewline: false)])
            try await settle(h)
        }
        try await type(at: 25 * 32 + 5) // in the 26th paragraph
        #expect(h.lastLayerParses == 1 && h.layerCount == 51)
        try await type(at: rope.byteCount - 8) // in the code block
        #expect(h.lastLayerParses == 1 && h.layerCount == 51)
        let fresh = try await highlighter("markdown", rope.string(in: 0..<rope.byteCount))
        #expect(h.spans(in: 0..<rope.byteCount) == fresh.spans(in: 0..<rope.byteCount))
    }

    /// In a long file, layers are kept only around what was last asked for, and follow the
    /// requests; what's shown matches a fresh parse once the layers land.
    @Test func layersFollowRequestsInLongFiles() async throws {
        let paragraph = "A paragraph with **bold** text in it, long enough to take a line of its own.\n\n"
        let count = 5000 // about 400 KB, past two region margins
        let text = String(repeating: paragraph, count: count)
        let h = SyntaxHighlighter(language: try #require(SyntaxLanguage.named("markdown")), rope: Rope(text))
        try await settle(h)
        let size = text.utf8.count, per = paragraph.utf8.count
        #expect(size > 2 * SyntaxHighlighter.regionMargin)
        // Only the start of the file has layers (a region's worth, give or take the paragraphs
        // its edges cut through): bold there, not near the end.
        let regionParagraphs = 2 * SyntaxHighlighter.regionMargin / per
        #expect(h.layerCount > 0 && h.layerCount <= regionParagraphs / 2 + 4)
        let top = 0..<per, bottom = size - per..<size
        #expect(h.spans(in: top).contains { $0.highlight == .strong })
        #expect(!h.spans(in: bottom).contains { $0.highlight == .strong })
        // Asking for the end moves the region there.
        try await settle(h)
        #expect(h.spans(in: bottom).contains { $0.highlight == .strong })
        #expect(h.layerCount <= regionParagraphs + 4)
        // The middle, from far away: the part being drawn gets layers first, then the rest of
        // the region does, and the end's are dropped.
        let middle = size / 2..<size / 2 + per
        let parses = h.parseCount
        _ = h.spans(in: middle)
        while h.parseCount == parses { try await Task.sleep(for: .milliseconds(1)) }
        #expect(h.spans(in: middle).contains { $0.highlight == .strong })
        let window = (SyntaxHighlighter.windowBefore + SyntaxHighlighter.windowAfter) / per
        #expect(h.layerCount <= window + 4)
        try await settle(h)
        #expect(h.spans(in: middle).contains { $0.highlight == .strong })
        #expect(h.layerCount > window + 4 && h.layerCount <= regionParagraphs + 4)
        let fresh = SyntaxHighlighter(language: try #require(SyntaxLanguage.named("markdown")), rope: Rope(text))
        try await settle(fresh)
        _ = fresh.spans(in: middle)
        try await settle(fresh)
        let around = size / 2 - 8 * per..<size / 2 + 8 * per
        #expect(h.spans(in: around) == fresh.spans(in: around))
    }

    /// LaTeX, with Neovim's query: its `#lua-match?` special cases apply only where they
    /// match, bold and italic arguments, math, references, and code in minted (Python).
    @Test func latexHighlights() async throws {
        let text = #"""
            % !TeX program = xelatex
            \documentclass{article}
            \section{Intro}
            Some \textbf{bold} and \emph{it}, see \ref{fig:a} and \cite{knuth}.
            % a comment
            \ifx\a\b yes\fi
            Inline $x^2$ here.
            \begin{minted}{python}
            def f(): return 1
            \end{minted}
            """#
        let h = try await highlighter("latex", text)
        #expect(kind(h, text, "% !TeX program = xelatex") == .keyword)
        #expect(kind(h, text, "% a comment") == .comment)
        #expect(kind(h, text, #"\ifx"#) == .keyword)
        #expect(kind(h, text, #"\a"#, after: #"\ifx"#) == .function)
        #expect(kind(h, text, "Intro") == .heading)
        #expect(kind(h, text, "bold") == .strong)
        #expect(kind(h, text, "it", after: #"\emph{"#) == .emphasis)
        #expect(kind(h, text, "fig:a") == .link)
        #expect(kind(h, text, "knuth") == .link)
        #expect(kind(h, text, "$x") == .literal)
        #expect(kind(h, text, "def") == .keyword)
        #expect(kind(h, text, "return") == .keyword)
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

/// A small seeded random number generator, so random tests repeat.
struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    /// A number in 0..<bound.
    mutating func next(_ bound: Int) -> Int {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return Int((z ^ (z >> 31)) % UInt64(bound))
    }
}
