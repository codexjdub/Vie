/// A selection as two byte offsets. `head` is where the cursor is; `anchor` is the end that
/// stays put when the selection is extended. Empty when they're equal.
public struct Selection: Equatable, Sendable {
    public var anchor: Int
    public var head: Int

    public init(anchor: Int, head: Int) {
        self.anchor = anchor
        self.head = head
    }

    /// An empty selection (a cursor) at `offset`.
    public init(_ offset: Int) {
        anchor = offset
        head = offset
    }

    public var lowerBound: Int { min(anchor, head) }
    public var upperBound: Int { max(anchor, head) }
    public var range: Range<Int> { lowerBound..<upperBound }
    public var isEmpty: Bool { anchor == head }
}

/// Replace the bytes in `range` with `text`. In a list of changes, every range refers to the
/// text before any of them apply, and ranges are sorted and don't overlap.
public struct Change: Equatable, Sendable {
    public var range: Range<Int>
    public var text: [UInt8]

    public init(_ range: Range<Int>, _ text: [UInt8]) {
        self.range = range
        self.text = text
    }

    public init(_ range: Range<Int>, _ text: String) {
        self.init(range, Array(text.utf8))
    }

    /// Where offset `p` ends up when sorted, non-overlapping `changes` apply: after text
    /// inserted at it, and inside a replaced range as far into the new text (at most its end).
    public static func map(_ p: Int, through changes: [Change]) -> Int {
        var shift = 0
        for c in changes {
            if p < c.range.lowerBound { break }
            if p < c.range.upperBound { return c.range.lowerBound + shift + min(p - c.range.lowerBound, c.text.count) }
            shift += c.text.count - c.range.count
        }
        return p + shift
    }
}

/// One replaced range, for code that keeps positions (marks) in step with edits.
public struct TextEdit: Equatable, Sendable {
    /// The bytes replaced, in the text as it was just before this edit.
    public var range: Range<Int>
    /// Length of the text that replaced them.
    public var newLength: Int
    /// Whether that text contains a line break.
    public var insertsNewline: Bool

    public init(range: Range<Int>, newLength: Int, insertsNewline: Bool) {
        self.range = range
        self.newLength = newLength
        self.insertsNewline = insertsNewline
    }
}

/// What an edit, undo or redo changed, so views can drop stale layout.
public struct BufferChange: Sendable {
    /// First line whose text changed.
    public var firstLine: Int
    /// Last changed line, counted after the change; `Int.max` means "through the end".
    public var lastLine: Int
    /// Lines added (or removed, if negative).
    public var lineDelta: Int
    /// The replacements in the order they were applied; each range refers to the text after
    /// the edits before it.
    public var edits: [TextEdit]
}

/// What an undo or redo did.
public struct UndoResult: Sendable {
    /// The selection before the undone (or redone) step was first made.
    public var selectionBefore: Selection
    /// The selection after that step was first made.
    public var selectionAfter: Selection
    public var change: BufferChange
}

/// How an edit joins the undo history: consecutive typing (or deleting) with no cursor
/// movement in between becomes one undo step; `.other` edits are always their own step.
public enum EditKind: Sendable {
    case typing, deleting, other
}

/// A text buffer: a rope, a selection, and undo history. Owned by the main thread; views and
/// documents observe it.
@MainActor
public final class Buffer {
    public private(set) var rope: Rope
    public var selection: Selection
    /// Increases with every change to the text.
    public private(set) var version = 0

    private struct Transaction {
        var forward: [Change]
        var inverse: [Change]
    }

    private struct Group {
        let id: Int
        let kind: EditKind
        var transactions: [Transaction]
        let selectionBefore: Selection
        var selectionAfter: Selection
        var isOpen: Bool
    }

    private var undoStack: [Group] = []
    private var redoStack: [Group] = []
    private var nextGroupID = 1
    /// Nesting depth of `beginUndoGroup()` calls; while above 0 every edit joins one group.
    private var explicitDepth = 0
    /// The group the current explicit grouping is filling (created by its first edit).
    private var explicitGroupID: Int?
    private var explicitSelectionBefore: Selection?
    /// The history position (id of the top undo group, 0 for none) whose text is on disk;
    /// nil when that position is no longer reachable.
    private var savedState: Int? = 0

    private struct Observer {
        weak var owner: AnyObject?
        let handler: @MainActor (BufferChange) -> Void
    }
    private var observers: [Observer] = []

    public init(rope: Rope = Rope()) {
        self.rope = rope
        selection = Selection(0)
    }

    public var isDirty: Bool { currentState != savedState || formatChanged }
    /// The file's encoding or line endings were changed since it was last saved, so it needs
    /// saving even when the text hasn't changed. Saving clears it.
    public var formatChanged = false
    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    private var currentState: Int { undoStack.last?.id ?? 0 }

    // MARK: - Observing

    /// Calls `handler` after every change to the text until `owner` is deallocated.
    public func addObserver(_ owner: AnyObject, _ handler: @escaping @MainActor (BufferChange) -> Void) {
        observers.removeAll { $0.owner == nil }
        observers.append(Observer(owner: owner, handler: handler))
    }

    public func removeObserver(_ owner: AnyObject) {
        observers.removeAll { $0.owner == nil || $0.owner === owner }
    }

    private func notify(_ change: BufferChange) {
        for o in observers where o.owner != nil { o.handler(change) }
    }

    // MARK: - Editing

    /// Applies `changes` as one transaction and moves the selection to `after`.
    public func edit(_ changes: [Change], selection after: Selection, kind: EditKind = .other) {
        let changes = changes.map { c in
            Change(min(max(c.range.lowerBound, 0), rope.byteCount)..<min(max(c.range.upperBound, 0), rope.byteCount), c.text)
        }.filter { !$0.range.isEmpty || !$0.text.isEmpty }
        guard !changes.isEmpty else {
            selection = after
            return
        }
        let before = selection
        let (inverse, change) = apply(changes)
        let transaction = Transaction(forward: changes, inverse: inverse)

        if explicitDepth > 0 {
            if let id = explicitGroupID, let i = undoStack.indices.last, undoStack[i].id == id {
                undoStack[i].transactions.append(transaction)
                undoStack[i].selectionAfter = after
            } else {
                startGroup(kind: .other, transaction, before: explicitSelectionBefore ?? before, after: after, open: false)
                explicitGroupID = undoStack.last?.id
            }
        } else if kind != .other, let i = undoStack.indices.last, undoStack[i].isOpen, undoStack[i].kind == kind,
           undoStack[i].selectionAfter == before, redoStack.isEmpty {
            // Extend the open typing run in place (copying the group out would copy its
            // whole transaction list on every keystroke).
            undoStack[i].transactions.append(transaction)
            undoStack[i].selectionAfter = after
        } else {
            startGroup(kind: kind, transaction, before: before, after: after, open: kind != .other)
        }
        selection = after
        notify(change)
    }

    private func startGroup(kind: EditKind, _ transaction: Transaction, before: Selection, after: Selection, open: Bool) {
        if let i = undoStack.indices.last { undoStack[i].isOpen = false }
        if let saved = savedState, redoStack.contains(where: { $0.id == saved }) { savedState = nil }
        redoStack.removeAll()
        undoStack.append(Group(id: nextGroupID, kind: kind, transactions: [transaction],
                               selectionBefore: before, selectionAfter: after, isOpen: open))
        nextGroupID += 1
    }

    /// Starts an undo group: every edit until the matching `endUndoGroup()` becomes one undo
    /// step, whatever its kind. Groups nest; only the outermost pair counts. The step's
    /// "selection before" is the selection now.
    public func beginUndoGroup() {
        if explicitDepth == 0 {
            breakUndoCoalescing()
            explicitGroupID = nil
            explicitSelectionBefore = selection
        }
        explicitDepth += 1
    }

    /// Ends an undo group started with `beginUndoGroup()`.
    public func endUndoGroup() {
        guard explicitDepth > 0 else { return }
        explicitDepth -= 1
        guard explicitDepth == 0 else { return }
        if let id = explicitGroupID, let i = undoStack.indices.last, undoStack[i].id == id {
            undoStack[i].selectionAfter = selection
        }
        explicitGroupID = nil
        explicitSelectionBefore = nil
    }

    /// Replaces `range` with `text` and puts the cursor after the inserted text.
    public func replace(_ range: Range<Int>, with text: [UInt8], kind: EditKind = .other) {
        edit([Change(range, text)], selection: Selection(range.lowerBound + text.count), kind: kind)
    }

    /// Applies `changes` as part of the last undo step: for a follow-up to the edit just made
    /// (renumbering a list after an item was added), which undo should take back with it.
    /// Without a step to join, it's an ordinary edit.
    public func amend(_ changes: [Change], selection after: Selection) {
        guard explicitDepth == 0, redoStack.isEmpty, let i = undoStack.indices.last else {
            return edit(changes, selection: after)
        }
        let changes = changes.filter { !$0.range.isEmpty || !$0.text.isEmpty }
        guard !changes.isEmpty else {
            selection = after
            return
        }
        let (inverse, change) = apply(changes)
        undoStack[i].transactions.append(Transaction(forward: changes, inverse: inverse))
        undoStack[i].selectionAfter = after
        selection = after
        notify(change)
    }

    /// Ends the current typing run, so the next edit starts a new undo step.
    public func breakUndoCoalescing() {
        if let i = undoStack.indices.last { undoStack[i].isOpen = false }
    }

    @discardableResult
    public func undo() -> Bool { performUndo() != nil }

    @discardableResult
    public func redo() -> Bool { performRedo() != nil }

    /// Undoes the last step and says what it was, or returns nil when there is none.
    public func performUndo() -> UndoResult? {
        guard var group = undoStack.popLast() else { return nil }
        group.isOpen = false
        if group.id == explicitGroupID { explicitGroupID = nil }
        var merged: BufferChange?
        for t in group.transactions.reversed() { merged = combine(merged, apply(t.inverse).1, group.transactions.count) }
        redoStack.append(group)
        selection = group.selectionBefore
        guard let merged else { return nil }
        notify(merged)
        return UndoResult(selectionBefore: group.selectionBefore, selectionAfter: group.selectionAfter, change: merged)
    }

    /// Redoes the last undone step and says what it was, or returns nil when there is none.
    public func performRedo() -> UndoResult? {
        guard let group = redoStack.popLast() else { return nil }
        var merged: BufferChange?
        for t in group.transactions { merged = combine(merged, apply(t.forward).1, group.transactions.count) }
        undoStack.append(group)
        selection = group.selectionAfter
        guard let merged else { return nil }
        notify(merged)
        return UndoResult(selectionBefore: group.selectionBefore, selectionAfter: group.selectionAfter, change: merged)
    }

    private func combine(_ a: BufferChange?, _ b: BufferChange, _ count: Int) -> BufferChange {
        guard let a else {
            return count == 1 ? b : BufferChange(firstLine: b.firstLine, lastLine: .max, lineDelta: b.lineDelta, edits: b.edits)
        }
        return BufferChange(firstLine: min(a.firstLine, b.firstLine), lastLine: .max, lineDelta: a.lineDelta + b.lineDelta,
                            edits: a.edits + b.edits)
    }

    /// Applies sorted, non-overlapping changes. Returns the changes that undo them.
    private func apply(_ changes: [Change]) -> ([Change], BufferChange) {
        let firstLine = rope.line(at: changes[0].range.lowerBound)
        let linesBefore = rope.lineCount
        var inverse: [Change] = []
        inverse.reserveCapacity(changes.count)
        var shift = 0
        for c in changes {
            let start = c.range.lowerBound + shift
            inverse.append(Change(start..<start + c.text.count, rope.bytes(in: c.range)))
            shift += c.text.count - c.range.count
        }
        var edits: [TextEdit] = []
        edits.reserveCapacity(changes.count)
        // Applied last to first, so each range is still valid when its turn comes.
        for c in changes.reversed() {
            rope.replace(c.range, with: c.text)
            edits.append(TextEdit(range: c.range, newLength: c.text.count, insertsNewline: c.text.contains(0x0A)))
        }
        version += 1
        let lastLine = rope.line(at: inverse[inverse.count - 1].range.upperBound)
        return (inverse, BufferChange(firstLine: firstLine, lastLine: lastLine, lineDelta: rope.lineCount - linesBefore, edits: edits))
    }

    // MARK: - Saving and reloading

    /// Starts a save: ends the typing run and returns the history position being saved.
    /// Pass it to `markSaved(at:)` when the write succeeds.
    public func beginSave() -> Int {
        breakUndoCoalescing()
        return currentState
    }

    /// Records that the text at history position `state` (from `beginSave()`) is on disk.
    public func markSaved(at state: Int) {
        savedState = state
        formatChanged = false
    }

    /// Records that the current text is on disk.
    public func markSaved() {
        breakUndoCoalescing()
        savedState = currentState
        formatChanged = false
    }

    /// Replaces the whole text with `newRope` as one undoable step, changing only the part
    /// that differs (common start and end are kept), and keeps the selection in place.
    public func replaceAll(with newRope: Rope) {
        let (prefix, suffix) = Buffer.commonAffixes(rope, newRope)
        let range = prefix..<(rope.byteCount - suffix)
        let text = newRope.bytes(in: prefix..<(newRope.byteCount - suffix))
        guard !range.isEmpty || !text.isEmpty else { return }
        let delta = text.count - range.count
        func map(_ p: Int) -> Int {
            if p <= range.lowerBound { return p }
            if p >= range.upperBound { return p + delta }
            return range.lowerBound + min(p - range.lowerBound, text.count)
        }
        breakUndoCoalescing()
        edit([Change(range, text)], selection: Selection(anchor: map(selection.anchor), head: map(selection.head)))
    }

    /// Lengths of the common byte prefix and suffix of two ropes, on character boundaries.
    static func commonAffixes(_ a: Rope, _ b: Rope) -> (Int, Int) {
        let limit = min(a.byteCount, b.byteCount)
        let block = 64 * 1024
        var prefix = 0
        while prefix < limit {
            let n = min(block, limit - prefix)
            let x = a.bytes(in: prefix..<prefix + n), y = b.bytes(in: prefix..<prefix + n)
            if x == y {
                prefix += n
                continue
            }
            var k = 0
            while x[k] == y[k] { k += 1 }
            prefix += k
            break
        }
        while prefix > 0 && ((prefix < a.byteCount && isContinuation(a.byte(at: prefix)))
                             || (prefix < b.byteCount && isContinuation(b.byte(at: prefix)))) { prefix -= 1 }

        let maxSuffix = limit - prefix
        var suffix = 0
        while suffix < maxSuffix {
            let n = min(block, maxSuffix - suffix)
            let x = a.bytes(in: a.byteCount - suffix - n..<a.byteCount - suffix)
            let y = b.bytes(in: b.byteCount - suffix - n..<b.byteCount - suffix)
            if x == y {
                suffix += n
                continue
            }
            var k = 0
            while x[n - 1 - k] == y[n - 1 - k] { k += 1 }
            suffix += k
            break
        }
        while suffix > 0 && (isContinuation(a.byte(at: a.byteCount - suffix)) || isContinuation(b.byte(at: b.byteCount - suffix))) {
            suffix -= 1
        }
        return (prefix, suffix)
    }
}
