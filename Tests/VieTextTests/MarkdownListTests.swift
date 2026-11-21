import Testing
@testable import VieText

/// The Markdown list rules the editor uses for Return, Tab, Backspace and numbering.
@Suite struct MarkdownListTests {
    private func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }

    /// `text` after `changes` (in the original text's offsets).
    private func applying(_ changes: [Change], to text: String) -> String {
        var rope = Rope(text)
        for c in changes.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) { rope.replace(c.range, with: c.text) }
        return rope.string(in: 0..<rope.byteCount)
    }

    @Test func prefixes() throws {
        let item = try #require(MarkdownList.prefix(of: bytes("  - [x] done")))
        #expect(item.indent == 0..<2 && item.marker == 2..<3 && item.task == 4..<8 && item.checked && item.content == 8)
        let numbered = try #require(MarkdownList.prefix(of: bytes("12) twelve")))
        #expect(numbered.number == 12 && numbered.marker == 0..<3 && numbered.content == 4)
        let quoted = try #require(MarkdownList.prefix(of: bytes("> > - x")))
        #expect(quoted.lead == 0..<4 && quoted.marker == 4..<5 && quoted.isQuote && quoted.isItem)
        let quote = try #require(MarkdownList.prefix(of: bytes("> just a quote")))
        #expect(!quote.isItem && quote.content == 2)
        #expect(MarkdownList.prefix(of: bytes("- "))?.content == 2) // an empty item
        for line in ["text", "-text", "- - -", "***", "* * *", "1.5 apples", "#1. heading", "-", ""] {
            #expect(MarkdownList.prefix(of: bytes(line)) == nil, "\(line)")
        }
    }

    @Test func returnContinuesItems() {
        func action(_ line: String, _ column: Int? = nil) -> MarkdownList.ReturnAction? {
            MarkdownList.returnAction(line: bytes(line), column: column ?? line.utf8.count)
        }
        #expect(action("- one") == .newItem(bytes("- ")))
        #expect(action("  * two") == .newItem(bytes("  * ")))
        #expect(action("1. one") == .newItem(bytes("2. ")))
        #expect(action("9) nine") == .newItem(bytes("10) ")))
        #expect(action("1.  wide gap") == .newItem(bytes("2.  ")))
        #expect(action("- [x] done") == .newItem(bytes("- [ ] ")))
        #expect(action("- [ ] todo", 7) == .newItem(bytes("- [ ] "))) // in the middle of the text
        #expect(action("> quoted") == .newItem(bytes("> ")))
        #expect(action("> - quoted item") == .newItem(bytes("> - ")))
        // Before the text it's a plain line break; elsewhere it's not a list.
        #expect(action("- one", 0) == nil)
        #expect(action("- one", 1) == nil)
        #expect(action("plain") == nil)
    }

    @Test func returnOnAnEmptyItemEndsTheListOrOutdents() {
        func action(_ line: String) -> MarkdownList.ReturnAction? {
            MarkdownList.returnAction(line: bytes(line), column: line.utf8.count)
        }
        #expect(action("- ") == .end(range: 0..<2, text: []))
        #expect(action("3. ") == .end(range: 0..<3, text: []))
        #expect(action("- [ ] ") == .end(range: 0..<6, text: []))
        #expect(action("> - ") == .end(range: 2..<4, text: []))
        #expect(action("  - ") == .outdent)
        #expect(action("> ") == .end(range: 0..<2, text: []))
        #expect(action("> > ") == .end(range: 0..<4, text: bytes("> ")))
    }

    @Test func backspaceRemovesTheBoxThenTheMarker() {
        func range(_ line: String, _ column: Int) -> Range<Int>? { MarkdownList.backspaceRange(line: bytes(line), column: column) }
        #expect(range("- one", 2) == 0..<2)
        #expect(range("- ", 2) == 0..<2)
        #expect(range("- [ ] todo", 6) == 2..<6)
        #expect(range("  1. x", 5) == 2..<5)
        #expect(range("- one", 3) == nil)
        #expect(range("> quote", 2) == nil)
    }

    @Test func indentingNestsUnderTheItemAbove() throws {
        let text = "- a\n- b\n  - c\n\n  more of b\n- d\n"
        let rope = Rope(text)
        let right = try #require(MarkdownList.shift(rope, line: 1, right: true, unit: bytes("    ")))
        #expect(applying(right, to: text) == "- a\n  - b\n    - c\n\n    more of b\n- d\n")
        // Under a numbered item, as far as its text: three spaces for `1. `.
        let numbered = "1. a\n2. b\n"
        let n = try #require(MarkdownList.shift(Rope(numbered), line: 1, right: true, unit: bytes("    ")))
        #expect(applying(n, to: numbered) == "1. a\n   2. b\n")
        // The first item has none above: one indentation unit.
        let first = try #require(MarkdownList.shift(Rope("- a\n"), line: 0, right: true, unit: bytes("\t")))
        #expect(applying(first, to: "- a\n") == "\t- a\n")
        // In a quote, the indentation goes after the quote markers.
        let quoted = try #require(MarkdownList.shift(Rope("> - a\n> - b\n"), line: 1, right: true, unit: bytes("  ")))
        #expect(applying(quoted, to: "> - a\n> - b\n") == "> - a\n>   - b\n")
    }

    @Test func outdentingGoesToTheParentLevel() throws {
        let text = "- a\n    - b\n        - c\n    - d\n"
        let left = try #require(MarkdownList.shift(Rope(text), line: 1, right: false, unit: bytes("  ")))
        #expect(applying(left, to: text) == "- a\n- b\n    - c\n    - d\n")
        #expect(MarkdownList.shift(Rope("- a\n"), line: 0, right: false, unit: bytes("  ")) == nil)
        #expect(MarkdownList.shift(Rope("text\n"), line: 0, right: true, unit: bytes("  ")) == nil)
    }

    @Test func renumbering() {
        func fixed(_ text: String, _ lines: [Int]) -> String {
            applying(MarkdownList.renumber(Rope(text), around: lines), to: text)
        }
        #expect(fixed("1. a\n1. b\n1. c\n", [0]) == "1. a\n2. b\n3. c\n")
        #expect(fixed("3. a\n5. b\n", [1]) == "3. a\n4. b\n")
        #expect(fixed("9. a\n9. b\n9. c\n", [2]) == "9. a\n10. b\n11. c\n")
        // Blank lines and deeper lines belong to the list; a nested list starts at 1.
        #expect(fixed("1. a\n\n   5. x\n   9. y\n\n7. b\n", [0, 2]) == "1. a\n\n   1. x\n   2. y\n\n2. b\n")
        // A bullet or a paragraph at its level ends a list.
        #expect(fixed("1. a\n- b\n5. c\n", [0, 2]) == "1. a\n- b\n5. c\n")
        #expect(fixed("1. a\ntext\n5. c\n", [2]) == "1. a\ntext\n5. c\n")
        #expect(fixed("- a\n", [0]) == "- a\n")
        #expect(MarkdownList.renumber(Rope("1. a\n2. b\n"), around: [0, 1]).isEmpty)
        // A blank line stands for the item after it.
        #expect(fixed("1. a\n\n\n5. b\n", [1]) == "1. a\n\n\n2. b\n")
    }

    @Test func openingALineAboveKeepsTheNumber() throws {
        let line = bytes("4) [x] four")
        let p = try #require(MarkdownList.prefix(of: line))
        #expect(MarkdownList.continuation(of: p, in: line, above: true) == bytes("4) [ ] "))
        #expect(MarkdownList.continuation(of: p, in: line) == bytes("5) [ ] "))
    }

    /// Which edits call for renumbering: adding or removing lines, and indentation changes.
    @Test func editsThatRenumber() {
        let rope = Rope("1. a\n2. b\n3. c\n")
        func lines(_ changes: [Change]) -> [Int] { MarkdownList.linesToRenumber(rope, changes: changes) }
        #expect(lines([Change(4..<4, "\n2. ")]) == [0, 2])     // Return after "1. a"
        #expect(lines([Change(5..<10, "")]) == [1, 2])         // the "2. b" line deleted
        #expect(lines([Change(5..<5, "   ")]) == [1, 2])       // "2. b" indented
        #expect(lines([Change(8..<8, "x")]).isEmpty)           // typing in the text
        #expect(lines([Change(5..<6, "7")]).isEmpty)           // typing in the number
        #expect(lines([Change(7..<7, "  ")]).isEmpty)          // spaces after the marker
        // Lines are counted as after the changes before them.
        #expect(lines([Change(0..<5, ""), Change(10..<10, "  ")]) == [0, 1, 1, 2])
    }

    @Test func positionsFollowChanges() {
        let changes = [Change(2..<2, "xx"), Change(5..<8, "y")]
        #expect([0, 2, 3, 5, 6, 8, 9].map { Change.map($0, through: changes) } == [0, 4, 5, 7, 8, 8, 9])
    }
}
