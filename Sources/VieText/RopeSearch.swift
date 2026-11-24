import Foundation

/// A regular expression run over a rope a chunk of lines at a time (about 256 KB), so searching
/// a 100 MB file never copies all of it into one string. Used by Vim's searches and by the Find
/// bar. A match never crosses into the next chunk, so patterns spanning many lines can be missed.
public struct RopeRegex: @unchecked Sendable {
    public let regex: NSRegularExpression
    /// The ICU group whose range counts as the match (Vim's `\zs`), when it took part; nil for
    /// the whole match.
    public let matchGroup: Int?

    public init(_ regex: NSRegularExpression, matchGroup: Int? = nil) {
        self.regex = regex
        self.matchGroup = matchGroup
    }

    static let chunkSize = 256 * 1024

    /// The range that counts as the match.
    public func matchRange(_ m: NSTextCheckingResult) -> NSRange {
        if let g = matchGroup {
            let r = m.range(at: g)
            if r.location != NSNotFound { return r }
        }
        return m.range
    }

    /// Matches in `range` of `rope`, which should start at a line start.
    public func matches(in rope: Rope, _ range: Range<Int>, limit: Int = .max) -> [RopeMatch] {
        let map = ChunkMap(bytes: rope.bytes(in: range), base: range.lowerBound)
        var out: [RopeMatch] = []
        regex.enumerateMatches(in: map.string as String, options: [], range: NSRange(location: 0, length: map.utf16Count)) { m, _, stop in
            guard let m else { return }
            out.append(RopeMatch(range: map.byteRange(matchRange(m)), result: m, map: map))
            if out.count >= limit { stop.pointee = true }
        }
        return out
    }

    /// Calls `body` with each match in the whole text, in order, a chunk at a time, until it
    /// returns false.
    public func forEachMatch(in rope: Rope, _ body: (RopeMatch) -> Bool) {
        var start = 0
        let total = rope.byteCount
        repeat {
            let end = chunkEnd(rope, start)
            for m in matches(in: rope, start..<end) where !body(m) { return }
            start = end
        } while start < total
    }

    /// The ranges of the matches in the whole text, in order, at most `limit` of them. Stops
    /// early, with what it found so far, once `isCancelled` says so (checked between chunks).
    public func allMatches(in rope: Rope, limit: Int = .max, isCancelled: () -> Bool = { false }) -> [Range<Int>] {
        var out: [Range<Int>] = []
        var start = 0
        let total = rope.byteCount
        repeat {
            let end = chunkEnd(rope, start)
            for m in matches(in: rope, start..<end, limit: limit - out.count) { out.append(m.range) }
            start = end
        } while start < total && out.count < limit && !isCancelled()
        return out
    }

    /// The next match after `offset` (or at it, when `acceptAt`), searching forward or
    /// backward a chunk at a time, wrapping around the end when `wrap`. Returns the match and
    /// whether the search wrapped.
    /// With `endAfter` (Vim searches with an `e` offset), a forward match counts when it ends
    /// after that offset rather than when it starts after `offset`.
    public func find(in rope: Rope, from offset: Int, forward: Bool, wrap: Bool, acceptAt: Bool = false,
                     endAfter: Int? = nil) -> (Range<Int>, wrapped: Bool)? {
        func after(_ r: Range<Int>) -> Bool {
            if let e = endAfter { return r.upperBound > e || (r.isEmpty && r.lowerBound > offset) }
            return r.lowerBound > offset || (acceptAt && r.lowerBound == offset)
        }
        let total = rope.byteCount
        if forward {
            var start = rope.lineStart(containing: offset)
            while start < total || (start == total && start == 0) {
                let end = chunkEnd(rope, start)
                for m in matches(in: rope, start..<end) where after(m.range) {
                    return (m.range, false)
                }
                if end >= total { break }
                start = end
            }
            guard wrap else { return nil }
            start = 0
            while start <= offset {
                let end = chunkEnd(rope, start)
                if let m = matches(in: rope, start..<end).first(where: { !after($0.range) }) { return (m.range, true) }
                if end >= total { break }
                start = end
            }
            return nil
        } else {
            var end = min(total, rope.lineEnd(containing: offset) + 1)
            while true {
                let start = chunkStart(rope, end)
                if let m = matches(in: rope, start..<end).last(where: { $0.range.lowerBound < offset }) { return (m.range, false) }
                if start == 0 { break }
                end = start
            }
            guard wrap else { return nil }
            end = total
            while end > 0 || total == 0 {
                let start = chunkStart(rope, end)
                if let m = matches(in: rope, start..<end).last(where: { $0.range.lowerBound >= offset }) { return (m.range, true) }
                if start == 0 { break }
                end = start
            }
            return nil
        }
    }

    private func chunkEnd(_ rope: Rope, _ start: Int) -> Int {
        let target = min(rope.byteCount, start + Self.chunkSize)
        if target >= rope.byteCount { return rope.byteCount }
        return min(rope.byteCount, rope.lineEnd(containing: target) + 1)
    }

    private func chunkStart(_ rope: Rope, _ end: Int) -> Int {
        if end <= Self.chunkSize { return 0 }
        return rope.lineStart(containing: end - Self.chunkSize)
    }
}

/// A match: its byte range, ICU's result (for groups), and the chunk it was found in (whose
/// string the result's ranges refer to).
public struct RopeMatch {
    public let range: Range<Int>
    public let result: NSTextCheckingResult
    public let map: ChunkMap
}

/// A chunk of text as an NSString, with UTF-16 to byte offset conversion.
public final class ChunkMap: @unchecked Sendable {
    public let string: NSString
    public let base: Int
    public let utf16Count: Int
    /// Byte offset of each UTF-16 index (nil when the text is ASCII, where they're equal).
    private let offsets: [Int32]?

    public init(bytes: [UInt8], base: Int) {
        self.base = base
        string = String(decoding: bytes, as: UTF8.self) as NSString
        utf16Count = string.length
        if bytes.allSatisfy({ $0 < 0x80 }) {
            offsets = nil
        } else {
            var o: [Int32] = []
            o.reserveCapacity(bytes.count + 1)
            var i = 0
            while i < bytes.count {
                let len = utf8Length(bytes[i])
                o.append(Int32(i))
                if len == 4 { o.append(Int32(i)) }
                i += len
            }
            o.append(Int32(bytes.count))
            offsets = o
        }
    }

    public func byteOffset(_ u: Int) -> Int {
        guard let offsets else { return base + u }
        return base + Int(offsets[min(max(u, 0), offsets.count - 1)])
    }

    public func byteRange(_ r: NSRange) -> Range<Int> {
        byteOffset(r.location)..<byteOffset(r.location + r.length)
    }

    public func substring(_ r: NSRange) -> String {
        guard r.location != NSNotFound else { return "" }
        return string.substring(with: r)
    }
}

/// What the Find bar looks for: the text as typed, or a regular expression in ICU's syntax (as
/// in other Mac apps, not Vim's), ignoring case unless asked.
public struct FindQuery: Equatable, Sendable {
    public var text: String
    public var matchCase: Bool
    /// Only where the match doesn't run on into a longer word: when it starts with a letter,
    /// digit or underscore, none right before it, and when it ends with one, none right after.
    /// So "cat" isn't found in "concat", but "(x)" is found in "f(x)".
    public var wholeWord: Bool
    public var regex: Bool

    public init(_ text: String = "", matchCase: Bool = false, wholeWord: Bool = false, regex: Bool = false) {
        self.text = text
        self.matchCase = matchCase
        self.wholeWord = wholeWord
        self.regex = regex
    }

    /// The search, or nil when there's nothing to look for or the expression doesn't compile.
    public func compiled() -> RopeRegex? {
        guard !text.isEmpty else { return nil }
        var pattern = regex ? text : NSRegularExpression.escapedPattern(for: text)
        if wholeWord {
            // At each end, either the match's own character or its neighbor outside isn't part
            // of a word (this also works for a regular expression, whose ends aren't known).
            let w = "[\\p{L}\\p{M}\\p{N}_]"
            pattern = "(?:(?<!\(w))|(?!\(w)))(?:\(pattern))(?:(?!\(w))|(?<!\(w)))"
        }
        var options: NSRegularExpression.Options = [.anchorsMatchLines]
        if !matchCase { options.insert(.caseInsensitive) }
        return (try? NSRegularExpression(pattern: pattern, options: options)).map { RopeRegex($0) }
    }

    /// The text that replaces `match`: `replacement` as typed, or for a regular expression with
    /// `$1` and the like filled in from the match (`\$` for a dollar sign).
    public func replacement(_ replacement: String, for match: RopeMatch, in search: RopeRegex) -> String {
        guard regex else { return replacement }
        return search.regex.replacementString(for: match.result, in: match.map.string as String, offset: 0, template: replacement)
    }
}
