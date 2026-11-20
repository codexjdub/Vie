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
}

/// What an edit, undo or redo changed, so views can drop stale layout.
public struct BufferChange: Sendable {
    /// First line whose text changed.
    public var firstLine: Int
    /// Last changed line, counted after the change; `Int.max` means "through the end".
    public var lastLine: Int
    /// Lines added (or removed, if negative).
    public var lineDelta: Int
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

    public var isDirty: Bool { currentState != savedState }
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

        // Extend the open typing run in place (copying the group out would copy its whole
        // transaction list on every keystroke).
        if kind != .other, let i = undoStack.indices.last, undoStack[i].isOpen, undoStack[i].kind == kind,
           undoStack[i].selectionAfter == before, redoStack.isEmpty {
            undoStack[i].transactions.append(transaction)
            undoStack[i].selectionAfter = after
        } else {
            if let i = undoStack.indices.last { undoStack[i].isOpen = false }
            if let saved = savedState, redoStack.contains(where: { $0.id == saved }) { savedState = nil }
            redoStack.removeAll()
            undoStack.append(Group(id: nextGroupID, kind: kind, transactions: [transaction],
                                   selectionBefore: before, selectionAfter: after, isOpen: kind != .other))
            nextGroupID += 1
        }
        selection = after
        notify(change)
    }

    /// Replaces `range` with `text` and puts the cursor after the inserted text.
    public func replace(_ range: Range<Int>, with text: [UInt8], kind: EditKind = .other) {
        edit([Change(range, text)], selection: Selection(range.lowerBound + text.count), kind: kind)
    }

    /// Ends the current typing run, so the next edit starts a new undo step.
    public func breakUndoCoalescing() {
        if let i = undoStack.indices.last { undoStack[i].isOpen = false }
    }

    @discardableResult
    public func undo() -> Bool {
        guard var group = undoStack.popLast() else { return false }
        group.isOpen = false
        var merged: BufferChange?
        for t in group.transactions.reversed() { merged = combine(merged, apply(t.inverse).1, group.transactions.count) }
        redoStack.append(group)
        selection = group.selectionBefore
        if let merged { notify(merged) }
        return true
    }

    @discardableResult
    public func redo() -> Bool {
        guard let group = redoStack.popLast() else { return false }
        var merged: BufferChange?
        for t in group.transactions { merged = combine(merged, apply(t.forward).1, group.transactions.count) }
        undoStack.append(group)
        selection = group.selectionAfter
        if let merged { notify(merged) }
        return true
    }

    private func combine(_ a: BufferChange?, _ b: BufferChange, _ count: Int) -> BufferChange {
        guard let a else { return count == 1 ? b : BufferChange(firstLine: b.firstLine, lastLine: .max, lineDelta: b.lineDelta) }
        return BufferChange(firstLine: min(a.firstLine, b.firstLine), lastLine: .max, lineDelta: a.lineDelta + b.lineDelta)
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
        for c in changes.reversed() { rope.replace(c.range, with: c.text) }
        version += 1
        let lastLine = rope.line(at: inverse[inverse.count - 1].range.upperBound)
        return (inverse, BufferChange(firstLine: firstLine, lastLine: lastLine, lineDelta: rope.lineCount - linesBefore))
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
    }

    /// Records that the current text is on disk.
    public func markSaved() {
        breakUndoCoalescing()
        savedState = currentState
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
