import AppKit
import VieText

/// What the Find bar asks of the editor: where the cursor is, showing a match, and replacing.
extension EditorView {
    /// Where the cursor is: Vim's cursor in Vim mode, else the selection's head.
    public var cursorOffset: Int { caretOffset }

    /// Shows a match the Find bar found: selected (in Vim mode the cursor goes to its start, as
    /// `/` leaves it), in the middle of the view if it was off screen, and drawn as the current
    /// match.
    public func showMatch(_ r: Range<Int>) {
        let offscreen = !visibleLines.contains(rope.line(at: r.lowerBound))
        setSelection(vim == nil ? Selection(anchor: r.lowerBound, head: r.upperBound) : Selection(r.lowerBound), reveal: !offscreen)
        if offscreen {
            center(rowPosition(of: r.lowerBound))
            revealCursor()
        }
        findCurrent = r
    }

    /// Replaces matches (one, or all of them) as one undo step, leaving the cursor at `cursor`.
    public func replaceMatches(_ changes: [Change], cursor: Int) {
        guard !changes.isEmpty else { return }
        if marked != nil { unmarkText() }
        buffer.breakUndoCoalescing()
        applyEdit(changes, selection: Selection(cursor), kind: .other)
        buffer.breakUndoCoalescing()
        vimSelectionChanged()
        needsDisplay = true
    }
}
