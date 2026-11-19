import Foundation

/// Random edits against a plain byte array, checking every rope query after each batch.
/// Uses tiny leaves and nodes so the tree gets deep and splits constantly.
enum SelfTest {
    static func run() {
        var rng = XorShift(seed: 42)
        let pieces = ["a", "bc", "def\n", "\n", "é", "日本語", "🚀", "x\ny\nz", "    ", "naïve", "\n\n"].map { Array($0.utf8) }
        let rope = Rope(leafSize: 8, maxLeaf: 16, maxChildren: 4)
        var reference: [UInt8] = []
        let steps = 30_000
        for step in 1...steps {
            if reference.isEmpty || rng.int(5) > 0 {
                let piece = pieces[rng.int(pieces.count)]
                let at = boundary(rng.int(reference.count + 1), reference)
                reference.insert(contentsOf: piece, at: at)
                rope.insert(piece, at: at)
            } else {
                let lo = boundary(rng.int(reference.count), reference)
                let hi = boundary(min(reference.count, lo + 1 + rng.int(24)), reference)
                if lo < hi {
                    reference.removeSubrange(lo..<hi)
                    rope.delete(lo..<hi)
                }
            }
            if step % 100 == 0 { check(rope, reference, step: step) }
        }
        let built = reference.withUnsafeBufferPointer { Rope(bytes: $0, leafSize: 8, maxLeaf: 16, maxChildren: 4) }
        check(built, reference, step: -1)
        let builtDefault = reference.withUnsafeBufferPointer { Rope(bytes: $0) }
        check(builtDefault, reference, step: -2)
        print("selftest OK: \(steps.formatted()) random edits, \(reference.count.formatted()) bytes, \(rope.lineCount.formatted()) lines")
    }

    private static func boundary(_ i: Int, _ r: [UInt8]) -> Int {
        var i = i
        while i < r.count && (r[i] & 0xC0) == 0x80 { i += 1 }
        return i
    }

    private static func check(_ rope: Rope, _ ref: [UInt8], step: Int) {
        func fail(_ what: String) -> Never { fatalError("selftest failed at step \(step): \(what)") }
        guard rope.checkInvariants() else { fail("cached summaries") }
        guard rope.allBytes() == ref else { fail("content") }
        guard rope.byteCount == ref.count else { fail("byteCount") }
        guard rope.utf16Count == String(decoding: ref, as: UTF8.self).utf16.count else { fail("utf16Count") }

        var lineStarts = [0]
        for (i, b) in ref.enumerated() where b == 0x0A { lineStarts.append(i + 1) }
        guard rope.lineCount == lineStarts.count else { fail("lineCount") }
        for (n, s) in lineStarts.enumerated() {
            guard rope.offset(ofLine: n) == s else { fail("offset(ofLine: \(n))") }
            let end = n + 1 < lineStarts.count ? lineStarts[n + 1] - 1 : ref.count
            guard rope.lineEnd(n) == end else { fail("lineEnd(\(n))") }
            guard rope.bytes(from: s) == Array(ref[s..<end]) else { fail("bytes(from:) line \(n)") }
        }

        var utf16 = 0, lines = 0
        for off in 0...ref.count {
            let isBoundary = off == ref.count || (ref[off] & 0xC0) != 0x80
            if isBoundary && off % 7 == abs(step) % 7 {
                guard rope.line(at: off) == lines else { fail("line(at: \(off))") }
                guard rope.utf16Offset(at: off) == utf16 else { fail("utf16Offset(at: \(off))") }
                guard rope.offset(atUTF16: utf16) == off else { fail("offset(atUTF16: \(utf16))") }
                if off > 0 {
                    var p = off - 1
                    while p > 0 && (ref[p] & 0xC0) == 0x80 { p -= 1 }
                    guard rope.previousCharStart(off) == p else { fail("previousCharStart(\(off))") }
                }
            }
            if off < ref.count {
                let b = ref[off]
                if b == 0x0A { lines += 1 }
                if (b & 0xC0) != 0x80 { utf16 += b >= 0xF0 ? 2 : 1 }
            }
        }
    }
}
