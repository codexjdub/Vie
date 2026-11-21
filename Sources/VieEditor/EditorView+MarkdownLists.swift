import VieSyntax
import VieText

/// Typing in Markdown lists (not in code blocks): Return continues an item or quote, or ends
/// the list on an empty one; Tab and ⇧Tab indent and outdent an item with the lines under it;
/// Backspace where an item's text starts removes its task box or marker; and numbered lists
/// are renumbered after edits that add, remove or indent lines. The rules are in
/// `MarkdownList`; Vim's Insert mode uses them too (through `VimEngine.markdownLists`).
extension EditorView {
    /// Blocks whose text is taken as it is (code, HTML, front matter): no list editing there.
    private static let verbatimBlocks: Set<String> = [
        "fenced_code_block", "indented_code_block", "html_block", "minus_metadata", "plus_metadata",
    ]

    /// Whether list editing applies at `offset`: in Markdown, outside code.
    func markdownLists(at offset: Int) -> Bool {
        guard syntaxLanguage?.name == "markdown" else { return false }
        return !(syntax?.nodeTypes(at: offset).contains { Self.verbatimBlocks.contains($0) } ?? false)
    }

    /// Return in a list item or quote. False when it's an ordinary line break.
    func listReturn() -> Bool {
        let s = buffer.selection
        guard syntaxLanguage?.name == "markdown", rope.line(at: s.lowerBound) == rope.line(at: s.upperBound) else { return false }
        let start = rope.lineStart(containing: s.lowerBound), end = rope.lineEnd(containing: s.upperBound)
        // The line as it is without the selection, which Return replaces.
        let line = rope.bytes(in: start..<s.lowerBound) + rope.bytes(in: s.upperBound..<end)
        guard let action = MarkdownList.returnAction(line: line, column: s.lowerBound - start),
              markdownLists(at: s.lowerBound) else { return false }
        switch action {
        case .newItem(let markers):
            replaceSelection(with: [0x0A] + markers, kind: .typing)
        case .end(let range, let text):
            // The range runs to the end of the line, so it takes the selection with it.
            let r = start + range.lowerBound..<end
            applyEdit([Change(r, text)], selection: Selection(r.lowerBound + text.count), kind: .typing)
        case .outdent:
            if !s.isEmpty { deleteSelection { s.range } }
            _ = shiftListItem(right: false)
        }
        return true
    }

    /// Tab and ⇧Tab on a list item: indents or outdents it with the lines under it. False
    /// when the selection isn't within one item's line.
    func shiftListItem(right: Bool) -> Bool {
        let s = buffer.selection
        let line = rope.line(at: s.lowerBound)
        guard syntaxLanguage?.name == "markdown", rope.line(at: s.upperBound) == line,
              MarkdownList.prefix(of: rope.bytes(in: rope.offset(ofLine: line)..<rope.lineEnd(line)))?.isItem == true,
              markdownLists(at: s.lowerBound) else { return false }
        guard let changes = MarkdownList.shift(rope, line: line, right: right, unit: Array(indentation.text.utf8)) else { return true }
        let selection = Selection(anchor: Change.map(s.anchor, through: changes), head: Change.map(s.head, through: changes))
        buffer.breakUndoCoalescing()
        applyEdit(changes, selection: selection, kind: .other)
        return true
    }

    /// Backspace where an item's text starts: removes its task box, else its marker. False
    /// anywhere else.
    func listBackspace() -> Bool {
        let s = buffer.selection
        guard s.isEmpty, syntaxLanguage?.name == "markdown" else { return false }
        let start = rope.lineStart(containing: s.head)
        let line = rope.bytes(in: start..<rope.lineEnd(containing: s.head))
        guard let r = MarkdownList.backspaceRange(line: line, column: s.head - start), markdownLists(at: s.head) else { return false }
        applyEdit([Change(start + r.lowerBound..<start + r.upperBound, [])], selection: Selection(start + r.lowerBound), kind: .deleting)
        return true
    }

    /// For an edit about to be made: the lines (numbered as after it) whose numbered lists it
    /// may put out of order. Empty outside Markdown lists.
    func listLinesToRenumber(_ changes: [Change]) -> [Int] {
        guard syntaxLanguage?.name == "markdown", let first = changes.first else { return [] }
        let lines = MarkdownList.linesToRenumber(rope, changes: changes)
        return lines.isEmpty || !markdownLists(at: first.range.lowerBound) ? [] : lines
    }

    /// Renumbers the numbered lists on `lines`, as part of the edit just made (one undo step).
    func renumberLists(at lines: [Int]) {
        let fix = MarkdownList.renumber(rope, around: lines)
        guard !fix.isEmpty else { return }
        let s = buffer.selection
        buffer.amend(fix, selection: Selection(anchor: Change.map(s.anchor, through: fix), head: Change.map(s.head, through: fix)))
    }
}
