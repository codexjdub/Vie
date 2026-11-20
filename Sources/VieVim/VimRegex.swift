import Foundation
import VieText

/// A Vim search pattern compiled for NSRegularExpression (ICU).
///
/// Vim patterns are translated: magic-mode escaping (`\(`, `\|`, `\+`, `\{n,m}`; `\v` very magic
/// and `\V` very nomagic), `\<` `\>` word boundaries, Vim classes (`\a`, `\l`, `\u`, `\x`, `\h`),
/// `\c` / `\C` case flags, `\zs` / `\ze`, and `\@=` style look-arounds on a group. A match
/// never crosses into a new chunk of lines, so patterns spanning many lines can be missed.
struct VimPattern {
    let source: String
    let regex: NSRegularExpression
    /// ICU group holding the text after `\zs` (the part that counts as the match).
    let zsGroup: Int?
    /// ICU group number for each Vim group (index 0 unused).
    let groupMap: [Int]

    enum Failure: Error { case invalid(String) }

    /// Compiles `source`. `ignoreCase` and `smartCase` are the options; `\c` and `\C` override
    /// them, and smart case applies only when `useSmartCase` (not for `*` and `#`).
    init(_ source: String, ignoreCase: Bool, smartCase: Bool, useSmartCase: Bool = true, lastReplacement: String? = nil) throws {
        let t = Translator(Array(source), lastReplacement: lastReplacement)
        t.run()
        var fold = ignoreCase
        if ignoreCase && smartCase && useSmartCase && t.hasUpper { fold = false }
        if let forced = t.caseOverride { fold = forced }
        var options: NSRegularExpression.Options = [.anchorsMatchLines]
        if fold { options.insert(.caseInsensitive) }
        do {
            regex = try NSRegularExpression(pattern: t.out, options: options)
        } catch {
            throw Failure.invalid(source)
        }
        self.source = source
        zsGroup = t.zsGroup
        groupMap = t.groupMap
    }

    /// The range that counts as the match (the `\zs` part when there is one).
    func matchRange(_ m: NSTextCheckingResult) -> NSRange {
        if let g = zsGroup {
            let r = m.range(at: g)
            if r.location != NSNotFound { return r }
        }
        return m.range
    }

    func group(_ m: NSTextCheckingResult, _ vimGroup: Int) -> NSRange {
        if vimGroup == 0 { return matchRange(m) }
        guard vimGroup < groupMap.count else { return NSRange(location: NSNotFound, length: 0) }
        return m.range(at: groupMap[vimGroup])
    }
}

/// Characters ICU treats specially outside a set.
private let icuSpecial: Set<Character> = ["\\", "^", "$", ".", "|", "?", "*", "+", "(", ")", "[", "]", "{", "}"]

private final class Translator {
    let p: [Character]
    let lastReplacement: String?
    var i = 0
    var out = ""
    var magic = 2          // 0 \V, 1 \M, 2 \m, 3 \v
    var caseOverride: Bool?
    var hasUpper = false
    var zsGroup: Int?
    var groupMap = [0]
    var icuGroups = 0
    var closers: [String] = []
    /// Where the last atom starts in `out`, for quantifiers and look-arounds.
    var atomStart: String.Index?
    var groupStarts: [String.Index] = []
    /// True right after the start of a branch (where `^` is an anchor and `*` is literal).
    var atBranchStart = true

    init(_ p: [Character], lastReplacement: String?) {
        self.p = p
        self.lastReplacement = lastReplacement
    }

    func run() {
        // Smart case looks at letters that aren't part of an escape.
        var k = 0
        while k < p.count {
            if p[k] == "\\" { k += 2; continue }
            if p[k].isUppercase { hasUpper = true }
            k += 1
        }
        while i < p.count {
            let c = p[i]
            i += 1
            if c == "\\" && i < p.count {
                let n = p[i]
                i += 1
                escaped(n)
            } else if c == "\\" {
                literal("\\")
            } else {
                plain(c)
            }
        }
        out += closers.reversed().joined()
    }

    /// Whether `c` is special without a backslash at the current magic level.
    func isMagic(_ c: Character) -> Bool {
        switch magic {
        case 3: return "()|+?={@%<>.*[~^$".contains(c)
        case 2: return ".*[~^$".contains(c)
        case 1: return "^$".contains(c)
        default: return false
        }
    }

    func plain(_ c: Character) {
        if c == "^" || c == "$" {
            // Anchors only where Vim treats them as anchors; elsewhere literal.
            if c == "^" && atBranchStart && (magic >= 1 || i == 1) { emitAtom("^", anchor: true); return }
            if c == "$" && atBranchEnd() && (magic >= 1 || i == p.count) { emitAtom("$", anchor: true); return }
            literal(c)
            return
        }
        if isMagic(c) { special(c) } else { literal(c) }
    }

    func escaped(_ n: Character) {
        switch n {
        case "c": caseOverride = true
        case "C": caseOverride = false
        case "v": magic = 3
        case "m": magic = 2
        case "M": magic = 1
        case "V": magic = 0
        case "n": emitAtom("\\n")
        case "t": emitAtom("\\t")
        case "e": emitAtom("\\x{1b}")
        case "r": emitAtom("\\r")
        case "d", "D", "s", "S", "w", "W": emitAtom("\\" + String(n))
        case "a": emitAtom("[A-Za-z]")
        case "A": emitAtom("[^A-Za-z]")
        case "l": emitAtom("[a-z]")
        case "L": emitAtom("[^a-z]")
        case "u": emitAtom("[A-Z]")
        case "U": emitAtom("[^A-Z]")
        case "x": emitAtom("[0-9A-Fa-f]")
        case "X": emitAtom("[^0-9A-Fa-f]")
        case "o": emitAtom("[0-7]")
        case "O": emitAtom("[^0-7]")
        case "h": emitAtom("[A-Za-z_]")
        case "H": emitAtom("[^A-Za-z_]")
        case "i", "k": emitAtom("\\w")
        case "I", "K": emitAtom("[^\\W\\d]")
        case "f", "F": emitAtom("[\\w./~-]")
        case "p", "P": emitAtom("[^\\p{Cc}]")
        case "1", "2", "3", "4", "5", "6", "7", "8", "9":
            let g = n.wholeNumberValue!
            emitAtom(g < groupMap.count ? "\\\(groupMap[g])" : "")
        case "z":
            guard i < p.count else { return literal("z") }
            let z = p[i]
            i += 1
            if z == "s" {
                icuGroups += 1
                zsGroup = icuGroups
                out += "("
                closers.append(")")
                atBranchStart = true
            } else if z == "e" {
                out += "(?="
                closers.append(")")
            }
        case "<" where magic < 3, ">" where magic < 3, "(" where magic < 3, ")" where magic < 3,
             "|" where magic < 3, "+" where magic < 3, "?" where magic < 3, "=" where magic < 3,
             "{" where magic < 3, "@" where magic < 3, "%" where magic < 3:
            special(n)
        case ".", "*", "[", "~":
            if magic < 2 { special(n) } else { literal(n) }
        default:
            literal(n)
        }
    }

    func special(_ c: Character) {
        switch c {
        case "(":
            vimGroupOpen(capturing: true)
        case ")":
            guard let start = groupStarts.popLast() else { return literal(")") }
            out += ")"
            atomStart = start
            atBranchStart = false
        case "%":
            if i < p.count && p[i] == "(" {
                i += 1
                vimGroupOpen(capturing: false)
            } else {
                literal("%")
            }
        case "|":
            out += "|"
            atomStart = nil
            atBranchStart = true
        case "+": quantifier("+")
        case "?", "=": quantifier("?")
        case "*":
            if atBranchStart || atomStart == nil { literal("*") } else { quantifier("*") }
        case "{": braces()
        case "@": lookaround()
        case "<": emitAtom("\\b(?=\\w)")
        case ">": emitAtom("\\b(?<=\\w)")
        case ".": emitAtom(".")
        case "[": collection()
        case "~":
            var s = ""
            for ch in lastReplacement ?? "" { s += icuSpecial.contains(ch) ? "\\" + String(ch) : String(ch) }
            emitAtom(s.isEmpty ? "(?:)" : "(?:" + s + ")")
        default:
            literal(c)
        }
    }

    func vimGroupOpen(capturing: Bool) {
        groupStarts.append(out.endIndex)
        if capturing {
            icuGroups += 1
            groupMap.append(icuGroups)
            out += "("
        } else {
            out += "(?:"
        }
        atBranchStart = true
    }

    func emitAtom(_ s: String, anchor: Bool = false) {
        atomStart = anchor ? nil : out.endIndex
        out += s
        atBranchStart = anchor && s == "^" ? atBranchStart : false
    }

    func literal(_ c: Character) {
        emitAtom(icuSpecial.contains(c) ? "\\" + String(c) : String(c))
    }

    func quantifier(_ q: String) {
        guard atomStart != nil else { return literal(Character(q)) }
        out += q
        atBranchStart = false
    }

    /// `\{n,m}`, `\{-n,m}` (lazy), `\{}`.
    func braces() {
        var body = ""
        while i < p.count && p[i] != "}" {
            if p[i] == "\\" && i + 1 < p.count && p[i + 1] == "}" { i += 1; break }
            body.append(p[i])
            i += 1
        }
        if i < p.count && p[i] == "}" { i += 1 }
        var lazy = false
        if body.hasPrefix("-") { lazy = true; body.removeFirst() }
        guard atomStart != nil else { return }
        let parts = body.split(separator: ",", omittingEmptySubsequences: false).map { String($0) }
        var q: String
        if body.isEmpty { q = "*" }
        else if parts.count == 1 { q = "{\(parts[0])}" }
        else { q = "{\(parts[0].isEmpty ? "0" : parts[0]),\(parts[1])}" }
        if lazy { q += "?" }
        out += q
    }

    /// `\@=`, `\@!`, `\@<=`, `\@<!`, `\@>` after an atom.
    func lookaround() {
        guard let start = atomStart else { return literal("@") }
        var kind = ""
        if i < p.count && p[i] == "=" { kind = "?="; i += 1 }
        else if i < p.count && p[i] == "!" { kind = "?!"; i += 1 }
        else if i < p.count && p[i] == ">" { kind = "?>"; i += 1 }
        else if i + 1 < p.count && p[i] == "<" && p[i + 1] == "=" { kind = "?<="; i += 2 }
        else if i + 1 < p.count && p[i] == "<" && p[i + 1] == "!" { kind = "?<!"; i += 2 }
        else { return literal("@") }
        let atom = String(out[start...])
        out.removeSubrange(start...)
        out += "(" + kind + atom + ")"
        atomStart = start
    }

    /// `[...]`: copied with ICU's set metacharacters escaped. Without a closing `]` the `[`
    /// is literal.
    func collection() {
        var j = i
        var body = ""
        if j < p.count && p[j] == "^" { body += "^"; j += 1 }
        if j < p.count && p[j] == "]" { body += "\\]"; j += 1 }
        var closed = false
        while j < p.count {
            let c = p[j]
            if c == "]" { closed = true; j += 1; break }
            if c == "[" && j + 1 < p.count && p[j + 1] == ":", let end = findClassEnd(j) {
                body += String(p[j...end])
                j = end + 1
                continue
            }
            if c == "\\" && j + 1 < p.count {
                let n = p[j + 1]
                switch n {
                case "e": body += "\\x{1b}"
                case "t": body += "\\t"
                case "r": body += "\\r"
                case "n": body += "\\n"
                case "d": body += "\\d"
                case "s": body += "\\s"
                case "\\", "]", "^", "-": body += "\\" + String(n)
                default: body += "\\\\" + (n == "[" || n == "&" ? "\\" : "") + String(n)
                }
                j += 2
                continue
            }
            if c == "[" || c == "&" || c == "{" || c == "}" { body += "\\" + String(c) } else { body.append(c) }
            j += 1
        }
        guard closed else { return literal("[") }
        i = j
        emitAtom("[" + body + "]")
    }

    private func findClassEnd(_ j: Int) -> Int? {
        var k = j + 2
        while k + 1 < p.count {
            if p[k] == ":" && p[k + 1] == "]" { return k + 1 }
            if !p[k].isLetter { return nil }
            k += 1
        }
        return nil
    }

    /// Whether a `$` at the current position ends a branch.
    func atBranchEnd() -> Bool {
        if i >= p.count { return true }
        if p[i] == "\\" && i + 1 < p.count { return p[i + 1] == "|" || p[i + 1] == ")" || p[i + 1] == "n" }
        if magic == 3 { return p[i] == "|" || p[i] == ")" }
        return false
    }
}

// MARK: - Searching the rope

extension VimPattern {
    /// Matches in `range` of `rope`, as byte ranges. The range should start at a line start.
    func matches(in rope: Rope, _ range: Range<Int>, limit: Int = .max) -> [(range: Range<Int>, result: NSTextCheckingResult, map: ChunkMap)] {
        let bytes = rope.bytes(in: range)
        let map = ChunkMap(bytes: bytes, base: range.lowerBound)
        var out: [(Range<Int>, NSTextCheckingResult, ChunkMap)] = []
        regex.enumerateMatches(in: map.string as String, options: [], range: NSRange(location: 0, length: map.utf16Count)) { m, _, stop in
            guard let m else { return }
            let r = matchRange(m)
            out.append((map.byteRange(r), m, map))
            if out.count >= limit { stop.pointee = true }
        }
        return out
    }

    /// The next match after `offset` (or at it, when `acceptAt`), searching forward or
    /// backward line chunk by line chunk, wrapping around the end when `wrap`. Returns the
    /// match and whether the search wrapped.
    /// With `endAfter` (searches with an `e` offset), a forward match counts when it ends
    /// after that offset rather than when it starts after `offset`.
    func find(in rope: Rope, from offset: Int, forward: Bool, wrap: Bool, acceptAt: Bool = false, endAfter: Int? = nil) -> (Range<Int>, wrapped: Bool)? {
        func after(_ r: Range<Int>) -> Bool {
            if let e = endAfter { return r.upperBound > e || (r.isEmpty && r.lowerBound > offset) }
            return r.lowerBound > offset || (acceptAt && r.lowerBound == offset)
        }
        let chunk = 256 * 1024
        let total = rope.byteCount
        if forward {
            var start = rope.lineStart(containing: offset)
            while start < total || (start == total && start == 0) {
                let end = chunkEnd(rope, start, chunk)
                for m in matches(in: rope, start..<end) where after(m.range) {
                    return (m.range, false)
                }
                if end >= total { break }
                start = end
            }
            guard wrap else { return nil }
            start = 0
            while start <= offset {
                let end = chunkEnd(rope, start, chunk)
                if let m = matches(in: rope, start..<end).first(where: { !after($0.range) }) { return (m.range, true) }
                if end >= total { break }
                start = end
            }
            return nil
        } else {
            var end = min(total, rope.lineEnd(containing: offset) + 1)
            while true {
                let start = chunkStart(rope, end, chunk)
                if let m = matches(in: rope, start..<end).last(where: { $0.range.lowerBound < offset }) { return (m.range, false) }
                if start == 0 { break }
                end = start
            }
            guard wrap else { return nil }
            end = total
            while end > 0 || total == 0 {
                let start = chunkStart(rope, end, chunk)
                if let m = matches(in: rope, start..<end).last(where: { $0.range.lowerBound >= offset }) { return (m.range, true) }
                if start == 0 { break }
                end = start
            }
            return nil
        }
    }

    private func chunkEnd(_ rope: Rope, _ start: Int, _ size: Int) -> Int {
        let target = min(rope.byteCount, start + size)
        if target >= rope.byteCount { return rope.byteCount }
        return min(rope.byteCount, rope.lineEnd(containing: target) + 1)
    }

    private func chunkStart(_ rope: Rope, _ end: Int, _ size: Int) -> Int {
        if end <= size { return 0 }
        return rope.lineStart(containing: end - size)
    }
}

/// A chunk of text as an NSString, with UTF-16 to byte offset conversion.
final class ChunkMap {
    let string: NSString
    let base: Int
    let utf16Count: Int
    /// Byte offset of each UTF-16 index (nil when the text is ASCII, where they're equal).
    private let offsets: [Int32]?

    init(bytes: [UInt8], base: Int) {
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

    func byteOffset(_ u: Int) -> Int {
        guard let offsets else { return base + u }
        return base + Int(offsets[min(max(u, 0), offsets.count - 1)])
    }

    func byteRange(_ r: NSRange) -> Range<Int> {
        byteOffset(r.location)..<byteOffset(r.location + r.length)
    }

    func substring(_ r: NSRange) -> String {
        guard r.location != NSNotFound else { return "" }
        return string.substring(with: r)
    }
}
