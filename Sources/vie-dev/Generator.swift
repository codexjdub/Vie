import Foundation
import VieText

/// Writes deterministic test files: source-like code (with some CJK, emoji and accented
/// text), or one giant minified-JSON line followed by a few short lines.
enum Generator {
    static func write(path: String, megabytes: Int, longLine: Bool) throws {
        let target = megabytes * 1_048_576
        guard FileManager.default.createFile(atPath: path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        var rng = SeededGenerator(seed: 0x5EED)
        var out: [UInt8] = []
        out.reserveCapacity(1 << 21)
        var written = 0
        func flush() throws {
            try handle.write(contentsOf: out)
            written += out.count
            out.removeAll(keepingCapacity: true)
        }

        if longLine {
            out += Array("{\"items\":[".utf8)
            var k = 0
            while written + out.count < target - 64 {
                out += Array("{\"id\":\(k),\"name\":\"item-\(rng.int(100_000))\",\"tags\":[\"alpha\",\"beta\"],\"score\":\(rng.int(1000)).\(rng.int(100))},".utf8)
                k += 1
                if out.count >= 1 << 20 { try flush() }
            }
            out += Array("{}]}\n".utf8)
            for i in 0..<40 { out += Array("// line \(i + 2), after the long line\n".utf8) }
        } else {
            var indent = 0
            while written + out.count < target {
                out += Array(sourceLine(&rng, indent: &indent).utf8)
                out.append(0x0A)
                if out.count >= 1 << 20 { try flush() }
            }
        }
        try flush()
    }

    private static let names = ["value", "count", "buffer", "index", "result", "node", "layout", "cursor", "range", "offset", "total", "line"]
    private static let comments = [
        "// TODO: handle the empty case before we touch the buffer",
        "// 日本語のコメント: 行の高さを計算する",
        "// ✅ fast path 🚀 for ASCII-only lines",
        "// Ünïcödé çhéck — naïve façade, coöperate",
        "/* block comment on one line */",
        "// MARK: - Layout",
    ]

    private static func sourceLine(_ rng: inout SeededGenerator, indent: inout Int) -> String {
        let a = names[rng.int(names.count)], b = names[rng.int(names.count)]
        let n = rng.int(1000), m = rng.int(100)
        let r = rng.int(20)
        if r < 2 && indent < 4 {
            let pad = String(repeating: " ", count: indent * 4)
            indent += 1
            return pad + "func \(a)_\(n)(_ \(b): Int, label: String) -> [Int] {"
        }
        if r < 4 && indent > 0 {
            indent -= 1
            return String(repeating: " ", count: indent * 4) + "}"
        }
        let pad = String(repeating: " ", count: indent * 4)
        switch r {
        case 4, 5, 6: return pad + "let \(a) = \(b).map { $0 * \(n) } + [\(n), \(m)]"
        case 7, 8: return pad + "if \(a) > \(n) { return \"\(b) overflow at \(n)\" }"
        case 9: return pad + "var \(a): [String: Int] = [\"alpha\": \(n), \"beta\": \(m)]"
        case 10, 11: return pad + comments[rng.int(comments.count)]
        case 12: return ""
        case 13, 14: return pad + "for \(a) in 0..<\(n) where \(a) % 3 == 0 { \(b) += \(a) * \(m) }"
        case 15: return pad + "let message = \"The quick brown fox jumps over the lazy dog while \(a) waits for \(b) number \(n) to finish\" + suffix(\(m))"
        case 16, 17: return pad + "guard let \(a) = \(b)[\(m)] else { return nil }"
        default: return pad + "\(a).append(contentsOf: \(b).filter { $0.isMultiple(of: \(m + 1)) })"
        }
    }
}
