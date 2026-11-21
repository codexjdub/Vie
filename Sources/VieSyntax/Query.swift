import Foundation
import TreeSitter
import VieText

/// A compiled tree-sitter query. tree-sitter only parses predicates (`#eq?`, `#match?`, …) and
/// leaves checking them to the caller, which this does; `#set!` settings are kept per pattern.
final class Query: @unchecked Sendable {
    let pointer: OpaquePointer
    let captureNames: [String]
    /// Per capture: its highlight, or nil if it isn't one.
    let highlights: [Highlight?]
    /// Per pattern.
    private let predicates: [[Predicate]]
    let settings: [[String: String]]

    private enum Predicate {
        case equal(capture: UInt32, text: String, negated: Bool)
        case equalCaptures(UInt32, UInt32, negated: Bool)
        case match(capture: UInt32, NSRegularExpression, negated: Bool)
        case anyOf(capture: UInt32, Set<String>, negated: Bool)
    }

    init?(language: OpaquePointer, source: String, error: inout String?) {
        var offset: UInt32 = 0
        var type = TSQueryErrorNone
        let bytes = Array(source.utf8)
        guard let q = bytes.withUnsafeBufferPointer({ p in
            p.withMemoryRebound(to: CChar.self) { ts_query_new(language, $0.baseAddress, UInt32($0.count), &offset, &type) }
        }) else {
            let line = bytes[..<min(Int(offset), bytes.count)].filter { $0 == 0x0A }.count + 1
            let kind = type == TSQueryErrorSyntax ? "syntax error" : type == TSQueryErrorNodeType ? "unknown node type"
                : type == TSQueryErrorField ? "unknown field" : type == TSQueryErrorCapture ? "unknown capture"
                : type == TSQueryErrorStructure ? "impossible pattern" : "error"
            let near = String(decoding: bytes[min(Int(offset), bytes.count)...].prefix(40), as: UTF8.self)
            error = "\(kind) at line \(line), near “\(near.split(separator: "\n").first ?? "")”"
            return nil
        }
        pointer = q
        var names: [String] = []
        for i in 0..<ts_query_capture_count(q) {
            var length: UInt32 = 0
            let p = ts_query_capture_name_for_id(q, i, &length)!
            names.append(String(decoding: UnsafeRawBufferPointer(start: p, count: Int(length)), as: UTF8.self))
        }
        captureNames = names
        highlights = names.map { Highlight(captureName: $0) }

        func string(_ id: UInt32) -> String {
            var length: UInt32 = 0
            let p = ts_query_string_value_for_id(q, id, &length)!
            return String(decoding: UnsafeRawBufferPointer(start: p, count: Int(length)), as: UTF8.self)
        }
        var allPredicates: [[Predicate]] = []
        var allSettings: [[String: String]] = []
        for pattern in 0..<ts_query_pattern_count(q) {
            var count: UInt32 = 0
            let steps = ts_query_predicates_for_pattern(q, pattern, &count)
            var preds: [Predicate] = []
            var sets: [String: String] = [:]
            var group: [TSQueryPredicateStep] = []
            for i in 0..<Int(count) {
                let step = steps![i]
                guard step.type == TSQueryPredicateStepTypeDone else {
                    group.append(step)
                    continue
                }
                defer { group = [] }
                guard let first = group.first, first.type == TSQueryPredicateStepTypeString else { continue }
                let name = string(first.value_id)
                let args = Array(group.dropFirst())
                func isCapture(_ k: Int) -> Bool { args.indices.contains(k) && args[k].type == TSQueryPredicateStepTypeCapture }
                func isString(_ k: Int) -> Bool { args.indices.contains(k) && args[k].type == TSQueryPredicateStepTypeString }
                let negated = name.hasPrefix("not-")
                switch name {
                case "eq?", "not-eq?":
                    if isCapture(0) && isString(1) {
                        preds.append(.equal(capture: args[0].value_id, text: string(args[1].value_id), negated: negated))
                    } else if isCapture(0) && isCapture(1) {
                        preds.append(.equalCaptures(args[0].value_id, args[1].value_id, negated: negated))
                    }
                case "match?", "not-match?":
                    if isCapture(0) && isString(1), let re = try? NSRegularExpression(pattern: string(args[1].value_id)) {
                        preds.append(.match(capture: args[0].value_id, re, negated: negated))
                    }
                case "any-of?", "not-any-of?":
                    if isCapture(0) {
                        let values = Set(args.dropFirst().filter { $0.type == TSQueryPredicateStepTypeString }.map { string($0.value_id) })
                        preds.append(.anyOf(capture: args[0].value_id, values, negated: negated))
                    }
                case "set!":
                    if isString(0) { sets[string(args[0].value_id)] = isString(1) ? string(args[1].value_id) : "" }
                default:
                    break // #is-not? local, #offset!, …: not supported; the pattern still applies.
                }
            }
            allPredicates.append(preds)
            allSettings.append(sets)
        }
        predicates = allPredicates
        settings = allSettings
    }

    deinit { ts_query_delete(pointer) }

    /// Whether a match's text predicates hold.
    func satisfies(_ match: TSQueryMatch, rope: Rope) -> Bool {
        let preds = predicates[Int(match.pattern_index)]
        guard !preds.isEmpty else { return true }
        func nodes(_ capture: UInt32) -> [TSNode] {
            (0..<Int(match.capture_count)).compactMap { match.captures[$0].index == capture ? match.captures[$0].node : nil }
        }
        func text(_ node: TSNode) -> String {
            rope.string(in: Int(ts_node_start_byte(node))..<Int(ts_node_end_byte(node)))
        }
        for p in preds {
            switch p {
            case .equal(let c, let value, let negated):
                for n in nodes(c) where (text(n) == value) == negated { return false }
            case .equalCaptures(let a, let b, let negated):
                if let x = nodes(a).first, let y = nodes(b).first, (text(x) == text(y)) == negated { return false }
            case .match(let c, let re, let negated):
                for n in nodes(c) {
                    let s = text(n)
                    let found = re.firstMatch(in: s, range: NSRange(location: 0, length: s.utf16.count)) != nil
                    if found == negated { return false }
                }
            case .anyOf(let c, let values, let negated):
                for n in nodes(c) where values.contains(text(n)) == negated { return false }
            }
        }
        return true
    }

    /// Paints this query's highlights of the tree under `root` into `styles`, which covers
    /// bytes `range` (nil where nothing matched). The query files list general patterns first
    /// and special cases later, so a later pattern wins on the same node; an inner node wins
    /// over the one around it.
    func paint(_ root: TSNode, range: Range<Int>, cursor: OpaquePointer, rope: Rope, into styles: inout [Highlight?]) {
        ts_query_cursor_set_byte_range(cursor, UInt32(range.lowerBound), UInt32(range.upperBound))
        ts_query_cursor_exec(cursor, pointer, root)
        var hits: [(start: Int, end: Int, pattern: UInt16, highlight: Highlight)] = []
        var match = TSQueryMatch()
        while ts_query_cursor_next_match(cursor, &match) {
            guard satisfies(match, rope: rope) else { continue }
            for i in 0..<Int(match.capture_count) {
                let capture = match.captures[i]
                guard let h = highlights[Int(capture.index)] else { continue }
                let start = Int(ts_node_start_byte(capture.node)), end = Int(ts_node_end_byte(capture.node))
                guard start < range.upperBound, end > range.lowerBound, start < end else { continue }
                hits.append((start, end, match.pattern_index, h))
            }
        }
        hits.sort { a, b in
            if a.start != b.start { return a.start < b.start }
            if a.end != b.end { return a.end > b.end }
            return a.pattern < b.pattern
        }
        let base = range.lowerBound
        for hit in hits {
            let s = max(hit.start, base) - base, e = min(hit.end, range.upperBound) - base
            for i in s..<e { styles[i] = hit.highlight }
        }
    }
}
