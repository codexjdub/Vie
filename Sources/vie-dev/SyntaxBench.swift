import Darwin
import Foundation
import QuartzCore
import VieSyntax
import VieText

/// Times highlighting one file without a window: the first parse and the memory it takes,
/// reparses after single-character edits, and the main-thread cost of a screenful of spans
/// (what the editor asks for when it lays out lines it hasn't seen).
@MainActor
enum SyntaxBench {
    static func run(path: String) {
        let url = URL(fileURLWithPath: path)
        guard let data = try? Data(contentsOf: url) else {
            fputs("can't read \(path)\n", stderr)
            exit(1)
        }
        let firstLine = String(decoding: data.prefix(200).prefix { $0 != 0x0A }, as: UTF8.self)
        guard let language = SyntaxLanguage.forFile(named: url.lastPathComponent, firstLine: firstLine) else {
            fputs("no language for \(url.lastPathComponent)\n", stderr)
            exit(1)
        }
        var rope = Rope(bytes: data)
        let mb = Double(rope.byteCount) / 1_048_576
        print(String(format: "file         %@, %.1f MB, %@ lines, %@", url.lastPathComponent, mb, rope.lineCount.formatted(), language.displayName))

        // Compile the queries outside the timings.
        let warm = SyntaxHighlighter(language: language, rope: Rope("x\n"))
        wait { warm.isReady }
        _ = warm.spans(in: 0..<1)
        let before = footprintMB()
        let t0 = CACurrentMediaTime()
        let highlighter = SyntaxHighlighter(language: language, rope: rope)
        wait { highlighter.isReady }
        let wall = (CACurrentMediaTime() - t0) * 1000
        let tree = footprintMB() - before
        print(String(format: "first parse  %.1f ms (%.1f ms until ready on the main thread)", highlighter.lastParseMs, wall))
        print(String(format: "memory       +%.1f MB for the tree, %.1f× the file", tree, tree / max(mb, 0.001)))

        // Reparses: one character typed at a random place, then waiting for the result.
        var rng = SeededGenerator(seed: 11)
        let reparses = Stats()
        for _ in 0..<40 {
            let off = rope.offset(ofLine: rng.int(rope.lineCount))
            rope.insert(Array("x".utf8), at: off)
            let count = highlighter.parseCount
            highlighter.update(rope: rope, edits: [TextEdit(range: off..<off, newLength: 1, insertsNewline: false)])
            wait { highlighter.parseCount > count && !highlighter.isParsing }
            reparses.record(highlighter.lastParseMs)
        }
        print("reparse      " + reparses.describe(unit: "ms (background)"))

        // A screenful of lines at a random place, asked a line at a time as the view lays them out.
        let screens = Stats(), perLine = Stats()
        for _ in 0..<100 {
            let first = rng.int(max(rope.lineCount - 60, 1))
            let t = CACurrentMediaTime()
            for line in first..<min(first + 60, rope.lineCount) {
                let l = CACurrentMediaTime()
                _ = highlighter.spans(in: rope.offset(ofLine: line)..<rope.lineEnd(line))
                perLine.record((CACurrentMediaTime() - l) * 1_000_000)
            }
            screens.record((CACurrentMediaTime() - t) * 1000)
        }
        let whole = Stats()
        for _ in 0..<100 {
            let first = rng.int(max(rope.lineCount - 60, 1))
            highlighter.update(rope: rope, edits: []) // forget the last window
            let t = CACurrentMediaTime()
            _ = highlighter.spans(in: rope.offset(ofLine: first)..<rope.lineEnd(min(first + 59, rope.lineCount - 1)))
            whole.record((CACurrentMediaTime() - t) * 1000)
        }
        print("screen       " + screens.describe(unit: "ms, 60 lines asked one at a time (main thread)"))
        print("line         " + perLine.describe(unit: "µs"))
        print("all at once  " + whole.describe(unit: "ms, the same 60 lines in one request"))
    }

    /// Runs the main run loop (where parse results land) until `done`, for up to 60 s.
    private static func wait(_ done: () -> Bool) {
        let limit = Date().addingTimeInterval(60)
        while !done() && Date() < limit {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.001))
        }
    }

    private static func footprintMB() -> Double {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
            }
        }
        return result == 0 ? Double(info.ri_phys_footprint) / 1_048_576 : 0
    }
}

/// Timing samples with percentiles.
final class Stats {
    private(set) var samples: [Double] = []
    func record(_ v: Double) { samples.append(v) }
    func percentile(_ p: Double) -> Double {
        guard !samples.isEmpty else { return 0 }
        let s = samples.sorted()
        return s[min(s.count - 1, Int((Double(s.count - 1) * p).rounded()))]
    }
    func describe(unit: String) -> String {
        String(format: "n=%d  p50 %.2f  p95 %.2f  max %.2f %@", samples.count, percentile(0.5), percentile(0.95), samples.max() ?? 0, unit)
    }
}
