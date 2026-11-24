import AppKit
import VieSyntax
import VieText

/// What the sidebar's Outline asks of the editor.
extension EditorView {
    /// The file's Markdown headings, from its last parse; empty for other languages, before
    /// the first parse, and for files too big to parse.
    public var markdownHeadings: [MarkdownHeading] { syntax?.markdownHeadings() ?? [] }

    /// Puts the cursor at `offset` (a heading chosen in the Outline), its line at the top of
    /// the view.
    public func jump(to offset: Int) {
        let off = min(max(offset, 0), rope.byteCount)
        if marked != nil { unmarkText() }
        setSelection(Selection(off), reveal: false)
        scroll(toLine: rope.line(at: off))
        revealCursor()
        needsDisplay = true
    }
}
