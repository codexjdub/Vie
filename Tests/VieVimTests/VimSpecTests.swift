import Foundation
import Testing
import VieText
@testable import VieVim

/// Runs the spec files in Specs/. Each line is `"before" → keys → "after"`, with `|` for the
/// cursor; scripts/vim-oracle.py checks the same files against real Vim.
@MainActor
struct VimSpecTests {
    nonisolated static let specDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Specs")

    nonisolated static var files: [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: specDir.path)) ?? []
        return names.filter { $0.hasSuffix(".vimspec") }.sorted()
    }

    @Test(arguments: files)
    func specFile(_ name: String) throws {
        let specs = try VimSpec.load(Self.specDir.appendingPathComponent(name))
        #expect(!specs.isEmpty)
        var failures: [String] = []
        for spec in specs {
            let (text, cursor) = spec.run()
            if text != spec.after || cursor != spec.afterCursor {
                failures.append("\(name):\(spec.line): \(VimSpec.quote(spec.before, spec.beforeCursor)) → \(spec.keys) → "
                                + "\(VimSpec.quote(text, cursor)), expected \(VimSpec.quote(spec.after, spec.afterCursor))")
            }
        }
        for f in failures { Issue.record(Comment(rawValue: f)) }
    }

    @Test func specCount() {
        let total = Self.files.compactMap { try? VimSpec.load(Self.specDir.appendingPathComponent($0)) }.map(\.count).reduce(0, +)
        #expect(total >= 300)
    }
}

/// A Vim host for tests: a 10-line window, a private clipboard, file commands that succeed.
@MainActor
final class TestHost: VimHost {
    var top = 0
    var height = 10
    var clipboard: String?
    var beeps = 0
    var performed: [VimFileCommand] = []

    var visibleLines: Range<Int> { top..<(top + height) }
    func vimScroll(toTopLine line: Int) { top = max(line, 0) }
    func vimReadClipboard() -> String? { clipboard }
    func vimWriteClipboard(_ text: String) { clipboard = text }
    func vimBeep() { beeps += 1 }
    func vimPerform(_ command: VimFileCommand) -> String? {
        performed.append(command)
        return nil
    }
    func vimStateDidChange() {}
    func vimSwitchToASCIIInput() {}
}

struct VimSpec {
    var line: Int
    var before: String
    var beforeCursor: Int
    var keys: String
    var after: String
    var afterCursor: Int
    var settings: String

    static func load(_ url: URL) throws -> [VimSpec] {
        let text = try String(contentsOf: url, encoding: .utf8)
        var out: [VimSpec] = []
        for (i, raw) in text.components(separatedBy: "\n").enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.components(separatedBy: " → ")
            guard parts.count == 3 || parts.count == 4 else { throw SpecError(line: i + 1, message: "expected 3 or 4 fields") }
            let (b, bc) = try unquote(parts[0], line: i + 1)
            let (a, ac) = try unquote(parts[2], line: i + 1)
            let settings = parts.count == 4 ? parts[3].replacingOccurrences(of: "vie-only", with: "").trimmingCharacters(in: .whitespaces) : ""
            out.append(VimSpec(line: i + 1, before: b, beforeCursor: bc, keys: parts[1], after: a, afterCursor: ac, settings: settings))
        }
        return out
    }

    struct SpecError: Error, CustomStringConvertible {
        var line: Int
        var message: String
        var description: String { "line \(line): \(message)" }
    }

    /// Text and cursor (byte offset) from a quoted field: `|` is the cursor, `\|` a bar.
    static func unquote(_ field: String, line: Int) throws -> (String, Int) {
        let f = field.trimmingCharacters(in: .whitespaces)
        guard f.count >= 2, f.first == "\"", f.last == "\"" else { throw SpecError(line: line, message: "expected a quoted string: \(f)") }
        let body = Array(f.dropFirst().dropLast())
        var out = ""
        var cursor: Int?
        var i = 0
        while i < body.count {
            let c = body[i]
            if c == "\\" && i + 1 < body.count {
                let n = body[i + 1]
                switch n {
                case "n": out += "\n"
                case "t": out += "\t"
                case "|", "\\", "\"": out.append(n)
                default: out += "\\" + String(n)
                }
                i += 2
                continue
            }
            if c == "|" && cursor == nil { cursor = out.utf8.count } else { out.append(c) }
            i += 1
        }
        return (out, cursor ?? 0)
    }

    static func quote(_ text: String, _ cursor: Int) -> String {
        let bytes = Array(text.utf8)
        let c = min(cursor, bytes.count)
        func esc(_ s: String) -> String {
            var o = ""
            for ch in s {
                switch ch {
                case "\n": o += "\\n"
                case "\t": o += "\\t"
                case "\\": o += "\\\\"
                case "\"": o += "\\\""
                case "|": o += "\\|"
                default: o.append(ch)
                }
            }
            return o
        }
        return "\"" + esc(String(decoding: bytes[..<c], as: UTF8.self)) + "|" + esc(String(decoding: bytes[c...], as: UTF8.self)) + "\""
    }

    /// Feeds the keys to a fresh engine, as if typed, and returns the text and cursor.
    @MainActor
    func run() -> (String, Int) {
        let buffer = Buffer(rope: Rope(before))
        buffer.selection = Selection(beforeCursor)
        let engine = VimEngine(buffer: buffer)
        let host = TestHost()
        engine.host = host
        if !settings.isEmpty {
            let args = settings.hasPrefix("set ") ? String(settings.dropFirst(4)) : settings
            _ = engine.options.set(args)
        }
        engine.handle(keys: VimKey.parse(keys))
        return (buffer.rope.string(in: 0..<buffer.rope.byteCount), engine.cursor)
    }
}
