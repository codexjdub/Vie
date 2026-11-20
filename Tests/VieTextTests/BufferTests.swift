import Testing
@testable import VieText

@MainActor
@Suite struct BufferTests {
    private func text(_ b: Buffer) -> String { b.rope.string(in: 0..<b.rope.byteCount) }

    private func type(_ s: String, into b: Buffer) {
        for ch in s {
            let at = b.selection.head
            b.replace(at..<at, with: Array(String(ch).utf8), kind: .typing)
        }
    }

    @Test func typingIsOneUndoStep() {
        let b = Buffer(rope: Rope("start"))
        b.selection = Selection(5)
        type(" more", into: b)
        #expect(text(b) == "start more")
        #expect(b.isDirty)
        b.undo()
        #expect(text(b) == "start")
        #expect(b.selection == Selection(5))
        #expect(!b.isDirty)
        b.redo()
        #expect(text(b) == "start more")
        #expect(b.selection == Selection(10))
    }

    @Test func movingTheCursorStartsANewStep() {
        let b = Buffer()
        type("ab", into: b)
        b.selection = Selection(0)
        type("X", into: b)
        #expect(text(b) == "Xab")
        b.undo()
        #expect(text(b) == "ab")
        b.undo()
        #expect(text(b).isEmpty)
        #expect(!b.canUndo)
    }

    @Test func typingThenDeletingAreSeparateSteps() {
        let b = Buffer()
        type("abc", into: b)
        b.edit([Change(2..<3, "")], selection: Selection(2), kind: .deleting)
        b.edit([Change(1..<2, "")], selection: Selection(1), kind: .deleting)
        #expect(text(b) == "a")
        b.undo()
        #expect(text(b) == "abc")
        b.undo()
        #expect(text(b).isEmpty)
    }

    @Test func multipleChangesUndoTogether() {
        let b = Buffer(rope: Rope("one two three"))
        b.edit([Change(0..<3, "1"), Change(4..<7, "2"), Change(8..<13, "3")], selection: Selection(5))
        #expect(text(b) == "1 2 3")
        b.undo()
        #expect(text(b) == "one two three")
        b.redo()
        #expect(text(b) == "1 2 3")
    }

    @Test func dirtyTrackingFollowsTheSavePoint() {
        let b = Buffer()
        type("saved", into: b)
        b.markSaved()
        #expect(!b.isDirty)
        type("!", into: b) // must not join the saved step
        #expect(b.isDirty)
        b.undo()
        #expect(!b.isDirty && text(b) == "saved")
        b.undo()
        #expect(b.isDirty)
        b.redo()
        #expect(!b.isDirty)
        b.undo()
        type("x", into: b) // the saved state can no longer be reached
        #expect(b.isDirty)
        b.undo()
        #expect(b.isDirty)
    }

    @Test func editsDuringASaveKeepTheBufferDirty() {
        let b = Buffer()
        type("abc", into: b)
        let state = b.beginSave()
        type("d", into: b)
        b.markSaved(at: state)
        #expect(b.isDirty)
        b.undo()
        #expect(!b.isDirty)
    }

    @Test func changeNotifications() {
        let b = Buffer(rope: Rope("a\nb\nc\nd"))
        var events: [BufferChange] = []
        let owner = NSObjectLike()
        b.addObserver(owner) { events.append($0) }
        b.edit([Change(2..<3, "B")], selection: Selection(3))
        b.edit([Change(4..<4, "x\ny\n")], selection: Selection(8))
        #expect(events.count == 2)
        #expect(events[0].firstLine == 1 && events[0].lastLine == 1 && events[0].lineDelta == 0)
        #expect(events[1].firstLine == 2 && events[1].lineDelta == 2)
        b.removeObserver(owner)
        b.undo()
        #expect(events.count == 2)
    }

    @Test func replaceAllKeepsSelectionAndUndo() {
        let b = Buffer(rope: Rope("header\nmiddle line\nfooter\n"))
        b.selection = Selection(anchor: 19, head: 22) // "foo" of "footer"
        b.replaceAll(with: Rope("header\nchanged\nfooter\n"))
        #expect(text(b) == "header\nchanged\nfooter\n")
        #expect(b.rope.string(in: b.selection.range) == "foo")
        b.undo()
        #expect(text(b) == "header\nmiddle line\nfooter\n")
    }

    @Test func commonAffixesRespectCharacters() {
        let (p, s) = Buffer.commonAffixes(Rope("日本"), Rope("日語"))
        #expect(p == 3 && s == 0)
        let (p2, s2) = Buffer.commonAffixes(Rope("aaa"), Rope("aaaa"))
        #expect(p2 + s2 <= 3)
    }

    /// Random edits, then undo everything and redo everything.
    @Test func randomUndoRedo() {
        var rng = SeededGenerator(seed: 21)
        let b = Buffer(rope: Rope("seed text\n"))
        var history = [text(b)]
        for _ in 0..<300 {
            let n = b.rope.byteCount
            let lo = rng.int(n + 1)
            let hi = min(n, lo + rng.int(6))
            let t = ["", "x", "yz\n", "日本", "🚀"][rng.int(5)]
            let safeLo = boundary(lo, b), safeHi = max(safeLo, boundary(hi, b))
            b.edit([Change(safeLo..<safeHi, t)], selection: Selection(safeLo))
            if text(b) != history.last { history.append(text(b)) }
        }
        while b.undo() {}
        #expect(text(b) == history.first)
        while b.redo() {}
        #expect(text(b) == history.last)
    }

    private func boundary(_ off: Int, _ b: Buffer) -> Int {
        var off = off
        while off < b.rope.byteCount && isContinuation(b.rope.byte(at: off)) { off += 1 }
        return off
    }
}

private final class NSObjectLike {}
