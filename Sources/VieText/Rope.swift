import Foundation

/// Byte, newline and UTF-16 code unit counts for a run of UTF-8 text.
/// Every rope node caches one, so line and offset lookups are O(log n).
public struct Summary: Equatable, Sendable {
    public var bytes = 0
    public var newlines = 0
    public var utf16 = 0

    public init(bytes: Int = 0, newlines: Int = 0, utf16: Int = 0) {
        self.bytes = bytes
        self.newlines = newlines
        self.utf16 = utf16
    }

    public static func of(_ p: UnsafeBufferPointer<UInt8>) -> Summary {
        var newlines = 0, utf16 = 0
        for b in p {
            newlines &+= b == 0x0A ? 1 : 0
            // One UTF-16 unit per scalar (counted at its lead byte), two for 4-byte scalars.
            utf16 &+= ((b & 0xC0) != 0x80 ? 1 : 0) &+ (b >= 0xF0 ? 1 : 0)
        }
        return Summary(bytes: p.count, newlines: newlines, utf16: utf16)
    }

    public static func of(_ bytes: [UInt8]) -> Summary { bytes.withUnsafeBufferPointer { of($0) } }
    public static func of(_ bytes: ArraySlice<UInt8>) -> Summary { bytes.withUnsafeBufferPointer { of($0) } }

    public static func + (a: Summary, b: Summary) -> Summary {
        Summary(bytes: a.bytes + b.bytes, newlines: a.newlines + b.newlines, utf16: a.utf16 + b.utf16)
    }

    public static func - (a: Summary, b: Summary) -> Summary {
        Summary(bytes: a.bytes - b.bytes, newlines: a.newlines - b.newlines, utf16: a.utf16 - b.utf16)
    }

    public static func += (a: inout Summary, b: Summary) { a = a + b }
    public static func -= (a: inout Summary, b: Summary) { a = a - b }
}

/// Length of the UTF-8 sequence starting with `lead`.
@inline(__always) public func utf8Length(_ lead: UInt8) -> Int {
    lead < 0x80 ? 1 : lead < 0xE0 ? 2 : lead < 0xF0 ? 3 : 4
}

/// Number of Unicode scalars in a UTF-8 byte run.
public func scalarCount(_ bytes: [UInt8]) -> Int {
    var n = 0
    for b in bytes where (b & 0xC0) != 0x80 { n += 1 }
    return n
}

/// Byte length of the first `units` UTF-16 code units of a UTF-8 byte run.
public func byteOffset(forUTF16 units: Int, in bytes: [UInt8]) -> Int {
    var i = 0, u = 0
    while i < bytes.count && u < units {
        let len = utf8Length(bytes[i])
        u += len == 4 ? 2 : 1
        i += len
    }
    return min(i, bytes.count)
}

final class RopeNode {
    var summary: Summary
    var children: [RopeNode]
    var data: [UInt8]
    let isLeaf: Bool

    init(leaf data: [UInt8]) {
        self.data = data
        children = []
        isLeaf = true
        summary = Summary.of(data)
    }

    init(children: [RopeNode]) {
        self.children = children
        data = []
        isLeaf = false
        summary = children.reduce(Summary()) { $0 + $1.summary }
    }
}

/// A B-tree rope over raw UTF-8 bytes. Leaves hold small byte chunks; every node caches the
/// byte/newline/UTF-16 counts of its subtree, so edits and lookups by line, byte offset or
/// UTF-16 offset are O(log n) regardless of file size.
///
/// M0 state: nodes are edited in place. M1 makes edits path-copying so snapshots are free.
public final class Rope {
    public let leafSize: Int
    public let maxLeaf: Int
    public let maxChildren: Int
    private(set) var root: RopeNode

    public var byteCount: Int { root.summary.bytes }
    public var lineCount: Int { root.summary.newlines + 1 }
    public var utf16Count: Int { root.summary.utf16 }

    public init(leafSize: Int = 2016, maxLeaf: Int = 4096, maxChildren: Int = 32) {
        self.leafSize = leafSize
        self.maxLeaf = maxLeaf
        self.maxChildren = maxChildren
        root = RopeNode(leaf: [])
    }

    /// Builds a balanced rope from UTF-8 bytes (an array, `Data`, a buffer pointer…).
    /// Default leaves are 2016 bytes so leaf + 32-byte array header = 2048, an exact malloc size.
    public init<Bytes: ContiguousBytes>(bytes: Bytes, leafSize: Int = 2016, maxLeaf: Int = 4096, maxChildren: Int = 32) {
        self.leafSize = leafSize
        self.maxLeaf = maxLeaf
        self.maxChildren = maxChildren
        root = bytes.withUnsafeBytes { raw in
            Rope.buildTree(raw.bindMemory(to: UInt8.self), leafSize: leafSize, maxChildren: maxChildren)
        }
    }

    public convenience init(_ string: String) {
        self.init(bytes: Array(string.utf8))
    }

    /// Memory-maps a file and builds a rope from its bytes.
    public static func load(contentsOf url: URL) throws -> Rope {
        Rope(bytes: try Data(contentsOf: url, options: .alwaysMapped))
    }

    /// Chunks bytes into leaves, then groups each level into parents until one root remains.
    private static func buildTree(_ p: UnsafeBufferPointer<UInt8>, leafSize: Int, maxChildren: Int) -> RopeNode {
        var level: [RopeNode] = []
        level.reserveCapacity(p.count / leafSize + 1)
        var start = 0
        while start < p.count {
            var end = min(start + leafSize, p.count)
            // Never split a UTF-8 sequence across leaves.
            while end < p.count && end > start + 1 && (p[end] & 0xC0) == 0x80 { end -= 1 }
            level.append(RopeNode(leaf: Array(UnsafeBufferPointer(rebasing: p[start..<end]))))
            start = end
        }
        if level.isEmpty { return RopeNode(leaf: []) }
        while level.count > 1 {
            var next: [RopeNode] = []
            next.reserveCapacity(level.count / maxChildren + 1)
            var i = 0
            while i < level.count {
                let j = min(i + maxChildren, level.count)
                next.append(RopeNode(children: Array(level[i..<j])))
                i = j
            }
            level = next
        }
        return level[0]
    }

    // MARK: - Lookups

    /// Byte offset where 0-based line `n` starts.
    public func offset(ofLine n: Int) -> Int {
        if n <= 0 { return 0 }
        if n > root.summary.newlines { return byteCount }
        var node = root, remaining = n, base = 0
        while !node.isLeaf {
            var i = 0
            while remaining > node.children[i].summary.newlines {
                remaining -= node.children[i].summary.newlines
                base += node.children[i].summary.bytes
                i += 1
            }
            node = node.children[i]
        }
        return node.data.withUnsafeBufferPointer { p -> Int in
            var seen = 0
            for i in 0..<p.count where p[i] == 0x0A {
                seen += 1
                if seen == remaining { return base + i + 1 }
            }
            return base + p.count
        }
    }

    /// Byte offset of the newline ending line `n`, or the end of the text for the last line.
    public func lineEnd(_ n: Int) -> Int {
        n >= root.summary.newlines ? byteCount : offset(ofLine: n + 1) - 1
    }

    /// 0-based line containing byte offset `off`.
    public func line(at off: Int) -> Int {
        var node = root, rem = min(max(off, 0), byteCount), lines = 0
        while !node.isLeaf {
            var i = 0
            let last = node.children.count - 1
            while i < last && rem >= node.children[i].summary.bytes {
                rem -= node.children[i].summary.bytes
                lines += node.children[i].summary.newlines
                i += 1
            }
            node = node.children[i]
        }
        node.data.withUnsafeBufferPointer { p in
            for i in 0..<min(rem, p.count) where p[i] == 0x0A { lines += 1 }
        }
        return lines
    }

    /// UTF-16 offset of byte offset `off` (what NSTextInputClient speaks).
    public func utf16Offset(at off: Int) -> Int {
        var node = root, rem = min(max(off, 0), byteCount), acc = 0
        while !node.isLeaf {
            var i = 0
            let last = node.children.count - 1
            while i < last && rem >= node.children[i].summary.bytes {
                rem -= node.children[i].summary.bytes
                acc += node.children[i].summary.utf16
                i += 1
            }
            node = node.children[i]
        }
        let n = min(rem, node.data.count)
        return acc + node.data.withUnsafeBufferPointer { Summary.of(UnsafeBufferPointer(rebasing: $0[0..<n])).utf16 }
    }

    /// Byte offset of UTF-16 offset `u`.
    public func offset(atUTF16 u: Int) -> Int {
        var node = root, rem = min(max(u, 0), utf16Count), base = 0
        while !node.isLeaf {
            var i = 0
            let last = node.children.count - 1
            while i < last && rem >= node.children[i].summary.utf16 {
                rem -= node.children[i].summary.utf16
                base += node.children[i].summary.bytes
                i += 1
            }
            node = node.children[i]
        }
        return node.data.withUnsafeBufferPointer { p -> Int in
            var i = 0, units = 0
            while i < p.count && units < rem {
                let len = utf8Length(p[i])
                units += len == 4 ? 2 : 1
                i += len
            }
            return base + min(i, p.count)
        }
    }

    /// Leaf holding byte `off` (requires off < byteCount) and the leaf's starting offset.
    private func leaf(containing off: Int) -> (RopeNode, Int) {
        var node = root, rem = off, base = 0
        while !node.isLeaf {
            var i = 0
            while rem >= node.children[i].summary.bytes {
                rem -= node.children[i].summary.bytes
                base += node.children[i].summary.bytes
                i += 1
            }
            node = node.children[i]
        }
        return (node, base)
    }

    public func byte(at off: Int) -> UInt8 {
        let (leaf, base) = leaf(containing: off)
        return leaf.data[off - base]
    }

    public func previousCharStart(_ off: Int) -> Int {
        var i = off - 1
        while i > 0 && (byte(at: i) & 0xC0) == 0x80 { i -= 1 }
        return max(i, 0)
    }

    public func nextCharEnd(_ off: Int) -> Int {
        guard off < byteCount else { return byteCount }
        return min(off + utf8Length(byte(at: off)), byteCount)
    }

    /// Copies bytes starting at `start`, stopping at a newline (optionally), after `maxScalars`
    /// characters, or after `maxBytes` bytes (never ending inside a character).
    public func bytes(from start: Int, maxBytes: Int = .max, maxScalars: Int = .max, stopAtNewline: Bool = true) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(min(maxBytes, 512))
        var off = start, scalars = 0, hitByteLimit = false
        let total = byteCount
        while off < total {
            let (leaf, base) = leaf(containing: off)
            var stop = false
            leaf.data.withUnsafeBufferPointer { p in
                var i = off - base
                while i < p.count {
                    let b = p[i]
                    if stopAtNewline && b == 0x0A { stop = true; return }
                    if (b & 0xC0) != 0x80 {
                        if scalars == maxScalars { stop = true; return }
                        scalars += 1
                    }
                    if out.count == maxBytes { stop = true; hitByteLimit = true; return }
                    out.append(b)
                    i += 1
                }
            }
            if stop { break }
            off = base + leaf.data.count
        }
        if hitByteLimit, !out.isEmpty {
            var k = out.count - 1
            while k > 0 && (out[k] & 0xC0) == 0x80 && out.count - k < 4 { k -= 1 }
            if k + utf8Length(out[k]) > out.count { out.removeSubrange(k...) }
        }
        return out
    }

    // MARK: - Edits

    public func insert(_ bytes: [UInt8], at off: Int) {
        guard !bytes.isEmpty else { return }
        let delta = Summary.of(bytes)
        if let sibling = insert(bytes, delta, at: min(max(off, 0), byteCount), into: root) {
            root = RopeNode(children: [root, sibling])
        }
    }

    /// Returns a new right sibling if `node` had to split.
    private func insert(_ bytes: [UInt8], _ delta: Summary, at off: Int, into node: RopeNode) -> RopeNode? {
        node.summary += delta
        if node.isLeaf {
            node.data.insert(contentsOf: bytes, at: off)
            return node.data.count > maxLeaf ? splitLeaf(node) : nil
        }
        var i = 0, rem = off
        let last = node.children.count - 1
        while i < last && rem > node.children[i].summary.bytes {
            rem -= node.children[i].summary.bytes
            i += 1
        }
        guard let sibling = insert(bytes, delta, at: rem, into: node.children[i]) else { return nil }
        node.children.insert(sibling, at: i + 1)
        return node.children.count > maxChildren ? splitInternal(node) : nil
    }

    private func splitLeaf(_ node: RopeNode) -> RopeNode {
        var mid = node.data.count / 2
        while mid < node.data.count && (node.data[mid] & 0xC0) == 0x80 { mid += 1 }
        let right = RopeNode(leaf: Array(node.data[mid...]))
        node.data.removeSubrange(mid...)
        node.summary -= right.summary
        return right
    }

    private func splitInternal(_ node: RopeNode) -> RopeNode {
        let mid = node.children.count / 2
        let right = RopeNode(children: Array(node.children[mid...]))
        node.children.removeSubrange(mid...)
        node.summary -= right.summary
        return right
    }

    public func delete(_ range: Range<Int>) {
        let lo = max(range.lowerBound, 0), hi = min(range.upperBound, byteCount)
        var remaining = hi - lo
        while remaining > 0 {
            remaining -= delete(at: lo, count: remaining, from: root).bytes
        }
        while !root.isLeaf && root.children.count == 1 { root = root.children[0] }
        if !root.isLeaf && root.children.isEmpty { root = RopeNode(leaf: []) }
    }

    /// Deletes up to `count` bytes at `off`, within a single leaf. Returns what was removed.
    private func delete(at off: Int, count: Int, from node: RopeNode) -> Summary {
        if node.isLeaf {
            let n = min(count, node.data.count - off)
            let removed = Summary.of(node.data[off..<off + n])
            node.data.removeSubrange(off..<off + n)
            node.summary -= removed
            return removed
        }
        var i = 0, rem = off
        while rem >= node.children[i].summary.bytes {
            rem -= node.children[i].summary.bytes
            i += 1
        }
        let removed = delete(at: rem, count: count, from: node.children[i])
        node.summary -= removed
        if node.children[i].summary.bytes == 0 { node.children.remove(at: i) }
        return removed
    }

    // MARK: - Verification (used by tests)

    func allBytes() -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(byteCount)
        collect(root, &out)
        return out
    }

    private func collect(_ node: RopeNode, _ out: inout [UInt8]) {
        if node.isLeaf { out += node.data } else { for c in node.children { collect(c, &out) } }
    }

    /// True when every node's cached summary matches its contents and no node is over capacity.
    func checkInvariants() -> Bool { verify(root) != nil }

    private func verify(_ node: RopeNode) -> Summary? {
        var s = Summary()
        if node.isLeaf {
            s = Summary.of(node.data)
        } else {
            if node.children.count > maxChildren { return nil }
            for c in node.children {
                guard let cs = verify(c) else { return nil }
                s += cs
            }
        }
        return s == node.summary ? s : nil
    }
}
