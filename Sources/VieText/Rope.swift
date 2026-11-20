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

/// True for UTF-8 continuation bytes (10xxxxxx).
@inline(__always) public func isContinuation(_ b: UInt8) -> Bool { (b & 0xC0) == 0x80 }

/// Number of Unicode scalars in a UTF-8 byte run.
public func scalarCount(_ bytes: [UInt8]) -> Int {
    var n = 0
    for b in bytes where !isContinuation(b) { n += 1 }
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

/// A rope node. Nodes are shared between rope versions, so a node is only ever changed in
/// place while exactly one rope references it (checked with `isKnownUniquelyReferenced`).
/// That rule is what makes sharing nodes across threads safe.
final class RopeNode: @unchecked Sendable {
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

    init(leaf data: [UInt8], summary: Summary) {
        self.data = data
        children = []
        isLeaf = true
        self.summary = summary
    }

    init(children: [RopeNode]) {
        self.children = children
        data = []
        isLeaf = false
        summary = children.reduce(Summary()) { $0 + $1.summary }
    }

    init(copying other: RopeNode) {
        summary = other.summary
        children = other.children
        data = other.data
        isLeaf = other.isLeaf
    }
}

/// A persistent B-tree rope over raw UTF-8 bytes. Leaves hold small byte chunks; every node
/// caches the byte/newline/UTF-16 counts of its subtree, so edits and lookups by line, byte
/// offset or UTF-16 offset are O(log n) regardless of file size.
///
/// `Rope` is a value type. Copying one is O(1) and gives an independent snapshot: an edit
/// copies only the nodes on the path it changes and shares the rest with older versions.
/// When no other version holds a node, edits change it in place instead.
public struct Rope: Sendable {
    public let leafSize: Int
    public let maxLeaf: Int
    public let maxChildren: Int
    private(set) var root: RopeNode

    var minLeaf: Int { leafSize / 2 }
    var minChildren: Int { max(2, maxChildren / 2) }

    public var byteCount: Int { root.summary.bytes }
    public var lineCount: Int { root.summary.newlines + 1 }
    public var utf16Count: Int { root.summary.utf16 }
    public var isEmpty: Bool { root.summary.bytes == 0 }

    public init(leafSize: Int = 2016, maxLeaf: Int = 4096, maxChildren: Int = 32) {
        precondition(maxLeaf > leafSize && leafSize >= 2 && maxChildren >= 3)
        self.leafSize = leafSize
        self.maxLeaf = maxLeaf
        self.maxChildren = maxChildren
        root = RopeNode(leaf: [])
    }

    /// Builds a balanced rope from UTF-8 bytes (an array, `Data`, a buffer pointer…).
    /// Default leaves are 2016 bytes so leaf + 32-byte array header = 2048, an exact malloc size.
    public init<Bytes: ContiguousBytes>(bytes: Bytes, leafSize: Int = 2016, maxLeaf: Int = 4096, maxChildren: Int = 32) {
        self.init(leafSize: leafSize, maxLeaf: maxLeaf, maxChildren: maxChildren)
        let leaves = bytes.withUnsafeBytes { raw in
            Rope.makeLeaves(raw.bindMemory(to: UInt8.self), leafSize: leafSize, maxLeaf: maxLeaf)
        }
        var level = leaves
        while level.count > 1 { level = Rope.group(level, max: maxChildren) }
        if let top = level.first { root = top }
    }

    public init(_ string: String) {
        self.init(bytes: Array(string.utf8))
    }

    /// True when both ropes are the same version (not just equal text).
    public func isIdentical(to other: Rope) -> Bool { root === other.root }

    /// Splits bytes into leaves of `leafSize` (never inside a UTF-8 sequence). The last leaf
    /// takes the remainder, between `maxLeaf - leafSize` and `maxLeaf` bytes, so no tiny leaf
    /// is left at the end.
    private static func makeLeaves(_ p: UnsafeBufferPointer<UInt8>, leafSize: Int, maxLeaf: Int) -> [RopeNode] {
        var leaves: [RopeNode] = []
        guard !p.isEmpty else { return leaves }
        leaves.reserveCapacity(p.count / leafSize + 1)
        var start = 0
        while p.count - start > maxLeaf {
            var end = start + leafSize
            while end > start + 1 && isContinuation(p[end]) { end -= 1 }
            leaves.append(RopeNode(leaf: Array(UnsafeBufferPointer(rebasing: p[start..<end]))))
            start = end
        }
        leaves.append(RopeNode(leaf: Array(UnsafeBufferPointer(rebasing: p[start...]))))
        return leaves
    }

    /// Groups sibling nodes under new parents of at most `max` children each, sized evenly.
    private static func group(_ nodes: [RopeNode], max: Int) -> [RopeNode] {
        let parents = (nodes.count + max - 1) / max
        var out: [RopeNode] = []
        out.reserveCapacity(parents)
        var start = 0
        for k in 0..<parents {
            let end = start + (nodes.count - start) / (parents - k)
            out.append(RopeNode(children: Array(nodes[start..<end])))
            start = end
        }
        return out
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

    /// Byte offset of UTF-16 offset `u`. An offset inside a surrogate pair rounds up to the
    /// end of that character.
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

    /// Start of the Unicode scalar before `off`.
    public func previousCharStart(_ off: Int) -> Int {
        var i = off - 1
        while i > 0 && isContinuation(byte(at: i)) { i -= 1 }
        return max(i, 0)
    }

    /// End of the Unicode scalar starting at `off`.
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
                    if !isContinuation(b) {
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
            while k > 0 && isContinuation(out[k]) && out.count - k < 4 { k -= 1 }
            if k + utf8Length(out[k]) > out.count { out.removeSubrange(k...) }
        }
        return out
    }

    /// Copies the bytes in `range` exactly (clamped to the text).
    public func bytes(in range: Range<Int>) -> [UInt8] {
        let lo = max(0, range.lowerBound), hi = min(byteCount, range.upperBound)
        guard lo < hi else { return [] }
        var out: [UInt8] = []
        out.reserveCapacity(hi - lo)
        forEachChunk(in: lo..<hi) { out.append(contentsOf: $0) }
        return out
    }

    /// The text in `range` as a String.
    public func string(in range: Range<Int>) -> String {
        String(decoding: bytes(in: range), as: UTF8.self)
    }

    /// Calls `body` with each leaf's bytes inside `range` (the whole text by default), in order.
    public func forEachChunk(in range: Range<Int>? = nil, _ body: (UnsafeBufferPointer<UInt8>) throws -> Void) rethrows {
        let lo = max(0, range?.lowerBound ?? 0), hi = min(byteCount, range?.upperBound ?? byteCount)
        guard lo < hi else { return }
        try visit(root, base: 0, lo, hi, body)
    }

    private func visit(_ node: RopeNode, base: Int, _ lo: Int, _ hi: Int,
                       _ body: (UnsafeBufferPointer<UInt8>) throws -> Void) rethrows {
        if node.isLeaf {
            let s = max(lo - base, 0), e = min(hi - base, node.data.count)
            if s < e { try node.data.withUnsafeBufferPointer { try body(UnsafeBufferPointer(rebasing: $0[s..<e])) } }
            return
        }
        var b = base
        for child in node.children {
            let size = child.summary.bytes
            if b + size > lo { try visit(child, base: b, lo, hi, body) }
            b += size
            if b >= hi { break }
        }
    }

    // MARK: - Edits

    /// Replaces the bytes in `range` with `bytes`.
    public mutating func replace(_ range: Range<Int>, with bytes: [UInt8]) {
        delete(range)
        insert(bytes, at: range.lowerBound)
    }

    /// Inserts `bytes` at `off`. A large insert becomes whole new leaves spliced into the tree,
    /// so pasting 100 MB costs about as much as loading it.
    public mutating func insert(_ bytes: [UInt8], at off: Int) {
        guard !bytes.isEmpty else { return }
        let delta = Summary.of(bytes)
        var extra = insert(bytes, delta, at: min(max(off, 0), byteCount), into: &root)
        while !extra.isEmpty {
            let level = Rope.group([root] + extra, max: maxChildren)
            root = level[0]
            extra = Array(level.dropFirst())
        }
    }

    /// Inserts into `node`, copying it first unless this rope is its only owner. Returns new
    /// right siblings when the node had to split; they have the same height as `node`.
    private func insert(_ bytes: [UInt8], _ delta: Summary, at off: Int, into node: inout RopeNode) -> [RopeNode] {
        if node.isLeaf {
            let fits = node.data.count + bytes.count <= maxLeaf
            if fits && isKnownUniquelyReferenced(&node) {
                node.data.insert(contentsOf: bytes, at: off)
                node.summary += delta
                return []
            }
            var combined: [UInt8] = []
            combined.reserveCapacity(node.data.count + bytes.count)
            combined += node.data[..<off]
            combined += bytes
            combined += node.data[off...]
            if fits {
                node = RopeNode(leaf: combined, summary: node.summary + delta)
                return []
            }
            let leaves = combined.withUnsafeBufferPointer { Rope.makeLeaves($0, leafSize: leafSize, maxLeaf: maxLeaf) }
            node = leaves[0]
            return Array(leaves.dropFirst())
        }

        if !isKnownUniquelyReferenced(&node) { node = RopeNode(copying: node) }
        var i = 0, rem = off
        let last = node.children.count - 1
        while i < last && rem > node.children[i].summary.bytes {
            rem -= node.children[i].summary.bytes
            i += 1
        }
        let extra = insert(bytes, delta, at: rem, into: &node.children[i])
        node.summary += delta
        guard !extra.isEmpty else { return [] }
        node.children.insert(contentsOf: extra, at: i + 1)
        guard node.children.count > maxChildren else { return [] }
        let parts = Rope.group(node.children, max: maxChildren)
        node = parts[0]
        return Array(parts.dropFirst())
    }

    /// Deletes the bytes in `range`. Whole subtrees inside the range are dropped in one step,
    /// and nodes left underfull at the edges are merged with a neighbor.
    public mutating func delete(_ range: Range<Int>) {
        let lo = max(range.lowerBound, 0), hi = min(range.upperBound, byteCount)
        guard lo < hi else { return }
        delete(lo, hi, from: &root)
        while !root.isLeaf && root.children.count == 1 { root = root.children[0] }
        if !root.isLeaf && root.children.isEmpty { root = RopeNode(leaf: []) }
    }

    private func delete(_ lo: Int, _ hi: Int, from node: inout RopeNode) {
        if node.isLeaf {
            let removed = Summary.of(node.data[lo..<hi])
            if isKnownUniquelyReferenced(&node) {
                node.data.removeSubrange(lo..<hi)
                node.summary -= removed
            } else {
                var kept: [UInt8] = []
                kept.reserveCapacity(node.data.count - (hi - lo))
                kept += node.data[..<lo]
                kept += node.data[hi...]
                node = RopeNode(leaf: kept, summary: node.summary - removed)
            }
            return
        }

        if !isKnownUniquelyReferenced(&node) { node = RopeNode(copying: node) }
        var start = 0, firstFull = -1, fullCount = 0
        var touched: [Int] = []
        var i = 0
        while i < node.children.count {
            let cs = start, ce = start + node.children[i].summary.bytes
            if ce <= lo { start = ce; i += 1; continue }
            if cs >= hi { break }
            if lo <= cs && ce <= hi {
                if firstFull < 0 { firstFull = i }
                fullCount += 1
            } else {
                delete(max(lo, cs) - cs, min(hi, ce) - cs, from: &node.children[i])
                touched.append(i)
            }
            start = ce
            i += 1
        }
        if fullCount > 0 { node.children.removeSubrange(firstFull..<firstFull + fullCount) }
        // The partly deleted children sit at the range's two edges; after removing the
        // children in between, the right one moves left.
        let edges = touched.map { firstFull >= 0 && $0 > firstFull ? $0 - fullCount : $0 }
        for idx in edges.sorted(by: >) { mergeIfUnderfull(&node, at: idx) }
        node.summary = node.children.reduce(Summary()) { $0 + $1.summary }
    }

    private func mergeIfUnderfull(_ parent: inout RopeNode, at i: Int) {
        guard i < parent.children.count, parent.children.count > 1 else { return }
        let child = parent.children[i]
        let underfull = child.isLeaf ? child.data.count < minLeaf : child.children.count < minChildren
        guard underfull else { return }
        let a = i > 0 ? i - 1 : i
        parent.children.replaceSubrange(a...a + 1, with: merge(parent.children[a], parent.children[a + 1]))
    }

    /// Joins two neighbors into one node, or two balanced ones if one would be too big.
    private func merge(_ a: RopeNode, _ b: RopeNode) -> [RopeNode] {
        if a.isLeaf {
            var d: [UInt8] = []
            d.reserveCapacity(a.data.count + b.data.count)
            d += a.data
            d += b.data
            if d.count <= maxLeaf { return [RopeNode(leaf: d, summary: a.summary + b.summary)] }
            var mid = d.count / 2
            while mid < d.count && isContinuation(d[mid]) { mid += 1 }
            return [RopeNode(leaf: Array(d[..<mid])), RopeNode(leaf: Array(d[mid...]))]
        }
        let kids = a.children + b.children
        if kids.count <= maxChildren { return [RopeNode(children: kids)] }
        let mid = kids.count / 2
        return [RopeNode(children: Array(kids[..<mid])), RopeNode(children: Array(kids[mid...]))]
    }

    // MARK: - Verification (used by tests)

    func allBytes() -> [UInt8] { bytes(in: 0..<byteCount) }

    var leafCount: Int { countLeaves(root) }

    private func countLeaves(_ node: RopeNode) -> Int {
        node.isLeaf ? 1 : node.children.reduce(0) { $0 + countLeaves($1) }
    }

    /// True when every cached summary matches its contents, no node is over capacity, no
    /// node except the root is empty, and all leaves are at the same depth.
    func checkInvariants() -> Bool {
        var leafDepth: Int?
        return verify(root, depth: 0, isRoot: true, leafDepth: &leafDepth) != nil
    }

    private func verify(_ node: RopeNode, depth: Int, isRoot: Bool, leafDepth: inout Int?) -> Summary? {
        var s = Summary()
        if node.isLeaf {
            if node.data.count > maxLeaf || (!isRoot && node.data.isEmpty) { return nil }
            if let d = leafDepth, d != depth { return nil }
            leafDepth = depth
            s = Summary.of(node.data)
        } else {
            if node.children.count > maxChildren || node.children.isEmpty { return nil }
            for c in node.children {
                guard let cs = verify(c, depth: depth + 1, isRoot: false, leafDepth: &leafDepth) else { return nil }
                s += cs
            }
        }
        return s == node.summary ? s : nil
    }
}
