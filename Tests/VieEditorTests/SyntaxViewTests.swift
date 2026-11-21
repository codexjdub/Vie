import AppKit
import Testing
import VieSyntax
import VieText
@testable import VieEditor

/// The editor's side of highlighting: lines laid out with their syntax colors, plain text and
/// big files left alone, recoloring after edits, and light and dark themes.
@MainActor
@Suite(.serialized) struct SyntaxViewTests {
    private func view(_ text: String, language: String?, width: CGFloat = 640, height: CGFloat = 300) -> EditorView {
        let v = EditorView(frame: NSRect(x: 0, y: 0, width: width, height: height), buffer: Buffer(rope: Rope(text)))
        v.syntaxLanguage = language.flatMap { SyntaxLanguage.named($0) }
        return v
    }

    private func settle(_ v: EditorView) async throws {
        for _ in 0..<400 {
            if let s = v.syntax, s.isReady, !s.isParsing { return }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func color(_ attr: NSAttributedString, at i: Int) -> CGColor? {
        attr.attribute(Highlighter.colorKey, at: i, effectiveRange: nil).map { $0 as! CGColor }
    }

    @Test func linesAreColoredByTheirSyntax() async throws {
        let v = view("let x = 1 // note\n", language: "swift")
        try await settle(v)
        let attr = v.styledText(0..<17)
        #expect(color(attr, at: 0) == Theme.style(.keyword).color)
        #expect(color(attr, at: 4) == Theme.text)
        #expect(color(attr, at: 8) == Theme.style(.number).color)
        #expect(color(attr, at: 12) == Theme.style(.comment).color)
    }

    @Test func offsetsSurviveMultibyteText() async throws {
        let text = "let 日本 = \"🚀\" // é\n"
        let v = view(text, language: "swift")
        try await settle(v)
        let attr = v.styledText(0..<text.utf8.count)
        let u16 = Array(text.utf16)
        let comment = u16.firstIndex(of: 0x2F)!
        #expect(color(attr, at: comment) == Theme.style(.comment).color)
        #expect(color(attr, at: u16.count - 2) == Theme.style(.comment).color)
        #expect(color(attr, at: u16.firstIndex(of: 0x22)!) == Theme.style(.string).color)
    }

    @Test func sameColoredWordsShareARun() async throws {
        let v = view("public static func f() {}\n", language: "swift")
        try await settle(v)
        var run = NSRange()
        let attr = v.styledText(0..<25)
        #expect(attr.attribute(Highlighter.colorKey, at: 0, effectiveRange: &run) as! CGColor == Theme.style(.keyword).color)
        #expect(run == NSRange(location: 0, length: 18))
    }

    @Test func plainTextAndBigFilesAreNotParsed() {
        #expect(view("let x = 1\n", language: nil).syntax == nil)
        let limit = EditorView.syntaxSizeLimit
        EditorView.syntaxSizeLimit = 5
        defer { EditorView.syntaxSizeLimit = limit }
        #expect(view("let x = 1\n", language: "swift").syntax == nil)
    }

    @Test func editsRecolorWhenTheirParseLands() async throws {
        let v = view("let a = 1\nlet b = 2\n", language: "swift")
        try await settle(v)
        let before = v.prefix(1, covering: 100)
        v.buffer.replace(10..<10, with: Array("// ".utf8))
        try await settle(v)
        let after = v.prefix(1, covering: 100)
        #expect(before.ct !== after.ct)
        let line = v.rope.offset(ofLine: 1)..<v.rope.lineEnd(1)
        #expect(color(v.styledText(line), at: 3) == Theme.style(.comment).color)
    }

    @Test func followsTheAppearance() {
        let v = view("let x = 1\n", language: "swift")
        v.appearance = NSAppearance(named: .aqua)
        v.followTheme()
        #expect(!Theme.isDark)
        let light = Theme.background
        _ = v.prefix(0, covering: 10)
        v.appearance = NSAppearance(named: .darkAqua)
        v.followTheme()
        #expect(Theme.isDark)
        #expect(Theme.background != light)
        #expect(v.lines.isEmpty)
    }

    /// Light and dark renders of highlighted Swift, Markdown and LaTeX. Set VIE_SNAPSHOT_DIR to write PNGs.
    @Test func rendersHighlightedText() async throws {
        let samples = [
            ("swift", """
            import Foundation

            /// A greeting, with a count.
            struct Greeter {
                let name: String
                var count = 0

                func greet(times: Int = 2) -> String {
                    // Repeat the name.
                    return (0..<times).map { _ in "Hello, \\(name)!" }.joined(separator: " ")
                }
            }

            """),
            ("markdown", """
            # Vie

            A *fast* editor with **Vim** keys and `tree-sitter`. See [the plan](PLAN.md).

            - one
            - two

            ```swift
            let x = 42 // answer
            ```

            > Quoted *text*

            """),
            ("latex", #"""
            % !TeX program = xelatex
            \documentclass{article}
            \usepackage{amsmath}
            \begin{document}
            \section{Results}\label{sec:results}
            We find \textbf{faster} parsing, as in \cite{knuth84} (see \ref{eq:e}).
            \begin{equation}
              E = mc^2 \quad \text{and} \quad x_{1} + \alpha
            \end{equation}
            % TODO: more
            \end{document}

            """#),
        ]
        for (language, text) in samples {
            let v = view(text, language: language, width: 620, height: 260)
            v.focusedForTesting = true
            try await settle(v)
            for (name, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
                v.appearance = NSAppearance(named: appearance)
                let rep = try #require(v.bitmapImageRepForCachingDisplay(in: v.bounds))
                v.cacheDisplay(in: v.bounds, to: rep)
                #expect(Theme.isDark == (name == "dark"))
                if let dir = ProcessInfo.processInfo.environment["VIE_SNAPSHOT_DIR"],
                   let png = rep.representation(using: .png, properties: [:]) {
                    try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("syntax-\(language)-\(name).png"))
                }
            }
        }
    }
}
