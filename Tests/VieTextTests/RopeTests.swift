import Testing
@testable import VieText

@Suite struct RopeTests {
    @Test func emptyRope() {
        let r = Rope()
        #expect(r.byteCount == 0)
        #expect(r.lineCount == 1)
        #expect(r.offset(ofLine: 0) == 0)
        #expect(r.lineEnd(0) == 0)
        #expect(r.bytes(from: 0).isEmpty)
    }

    @Test func lineLookups() {
        let r = Rope("one\ntwo\n\nfour")
        #expect(r.lineCount == 4)
        #expect(r.offset(ofLine: 1) == 4)
        #expect(r.offset(ofLine: 2) == 8)
        #expect(r.offset(ofLine: 3) == 9)
        #expect(r.offset(ofLine: 99) == r.byteCount)
        #expect(r.lineEnd(0) == 3)
        #expect(r.lineEnd(3) == 13)
        #expect(r.line(at: 0) == 0)
        #expect(r.line(at: 4) == 1)
        #expect(r.line(at: 13) == 3)
    }

    @Test func utf16Conversions() {
        // a (1 byte, 1 unit) · 🚀 (4 bytes, 2 units) · é (2 bytes, 1 unit) · 日 (3 bytes, 1 unit)
        let r = Rope("a🚀é日")
        #expect(r.byteCount == 10)
        #expect(r.utf16Count == 5)
        #expect(r.utf16Offset(at: 1) == 1)
        #expect(r.utf16Offset(at: 5) == 3)
        #expect(r.utf16Offset(at: 7) == 4)
        #expect(r.offset(atUTF16: 3) == 5)
        #expect(r.offset(atUTF16: 4) == 7)
        #expect(r.offset(atUTF16: 5) == 10)
    }

    @Test func characterNavigation() {
        let r = Rope("a🚀é")
        #expect(r.nextCharEnd(0) == 1)
        #expect(r.nextCharEnd(1) == 5)
        #expect(r.previousCharStart(7) == 5)
        #expect(r.previousCharStart(5) == 1)
        #expect(r.previousCharStart(1) == 0)
    }

    @Test func byteCopyLimits() {
        let r = Rope("日本語のテキスト\nnext")
        #expect(text(r.bytes(from: 0, maxScalars: 3)) == "日本語")
        #expect(text(r.bytes(from: 0, maxBytes: 4)) == "日") // never ends mid-character
        #expect(text(r.bytes(from: 0)) == "日本語のテキスト") // stops at the newline
        #expect(text(r.bytes(from: 0, stopAtNewline: false)) == "日本語のテキスト\nnext")
    }

    @Test func editsAcrossLeaves() {
        let r = Rope(bytes: Array("0123456789".utf8), leafSize: 3, maxLeaf: 4, maxChildren: 2)
        r.insert(Array("abc".utf8), at: 5)
        #expect(text(r.allBytes()) == "01234abc56789")
        r.delete(2..<11)
        #expect(text(r.allBytes()) == "0189")
        r.delete(0..<4)
        #expect(r.byteCount == 0)
        #expect(r.lineCount == 1)
        r.insert(Array("x\ny".utf8), at: 0)
        #expect(r.lineCount == 2)
        #expect(r.checkInvariants())
    }

    /// Random edits against a plain byte array, checking every query after each batch.
    /// Tiny leaves and nodes make the tree deep, so splits and merges happen constantly.
    @Test func randomEditsMatchReference() {
        var rng = SeededGenerator(seed: 42)
        let pieces = ["a", "bc", "def\n", "\n", "é", "日本語", "🚀", "x\ny\nz", "    ", "naïve", "\n\n"].map { Array($0.utf8) }
        let rope = Rope(leafSize: 8, maxLeaf: 16, maxChildren: 4)
        var reference: [UInt8] = []
        for step in 1...10_000 {
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
            if step % 200 == 0, let problem = mismatch(rope, reference, sample: step) {
                Issue.record("after \(step) edits: \(problem)")
                return
            }
        }
    }

    @Test(arguments: [8, 2016])
    func bulkBuildMatchesReference(leafSize: Int) {
        var rng = SeededGenerator(seed: 9)
        let pieces = ["word ", "日本語", "🚀", "\n", "naïve\n"].map { Array($0.utf8) }
        var reference: [UInt8] = []
        while reference.count < 20_000 { reference += pieces[rng.int(pieces.count)] }
        let rope = Rope(bytes: reference, leafSize: leafSize, maxLeaf: leafSize * 2, maxChildren: leafSize == 8 ? 4 : 32)
        if let problem = mismatch(rope, reference, sample: 0) { Issue.record("\(problem)") }
    }

    // MARK: - Helpers

    private func text(_ bytes: [UInt8]) -> String { String(decoding: bytes, as: UTF8.self) }

    private func boundary(_ i: Int, _ r: [UInt8]) -> Int {
        var i = i
        while i < r.count && (r[i] & 0xC0) == 0x80 { i += 1 }
        return i
    }

    /// Describes the first way `rope` disagrees with `ref`, or nil if they match.
    /// Offset checks run on every 7th character boundary, shifted by `sample`.
    private func mismatch(_ rope: Rope, _ ref: [UInt8], sample: Int) -> String? {
        guard rope.checkInvariants() else { return "cached summaries are wrong" }
        guard rope.allBytes() == ref else { return "content differs" }
        guard rope.byteCount == ref.count else { return "byteCount" }
        guard rope.utf16Count == String(decoding: ref, as: UTF8.self).utf16.count else { return "utf16Count" }

        var lineStarts = [0]
        for (i, b) in ref.enumerated() where b == 0x0A { lineStarts.append(i + 1) }
        guard rope.lineCount == lineStarts.count else { return "lineCount" }
        for (n, s) in lineStarts.enumerated() {
            guard rope.offset(ofLine: n) == s else { return "offset(ofLine: \(n))" }
            let end = n + 1 < lineStarts.count ? lineStarts[n + 1] - 1 : ref.count
            guard rope.lineEnd(n) == end else { return "lineEnd(\(n))" }
            guard rope.bytes(from: s) == Array(ref[s..<end]) else { return "bytes(from:) on line \(n)" }
        }

        var utf16 = 0, lines = 0
        for off in 0...ref.count {
            let isBoundary = off == ref.count || (ref[off] & 0xC0) != 0x80
            if isBoundary && off % 7 == sample % 7 {
                guard rope.line(at: off) == lines else { return "line(at: \(off))" }
                guard rope.utf16Offset(at: off) == utf16 else { return "utf16Offset(at: \(off))" }
                guard rope.offset(atUTF16: utf16) == off else { return "offset(atUTF16: \(utf16))" }
                if off > 0 {
                    var p = off - 1
                    while p > 0 && (ref[p] & 0xC0) == 0x80 { p -= 1 }
                    guard rope.previousCharStart(off) == p else { return "previousCharStart(\(off))" }
                }
            }
            if off < ref.count {
                let b = ref[off]
                if b == 0x0A { lines += 1 }
                if (b & 0xC0) != 0x80 { utf16 += b >= 0xF0 ? 2 : 1 }
            }
        }
        return nil
    }
}
