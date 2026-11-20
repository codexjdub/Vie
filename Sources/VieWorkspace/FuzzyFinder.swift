import Foundation

/// Finds every file in a folder that git doesn't ignore, for ⌘P. Doesn't descend into
/// ignored folders, `.git`, or symlinked folders (which could loop).
public enum PathScanner {
    /// Paths relative to the folder, in no particular order. Stops after `limit` files.
    public static func scan(_ context: IgnoreContext, folder: URL, limit: Int = 1_000_000) -> [String] {
        var out: [String] = []
        out.reserveCapacity(4096)
        let folder = folder.standardizedFileURL.resolvingSymlinksInPath()
        func walk(_ url: URL, _ rel: String, _ repoRel: String, _ rules: IgnoreStack) {
            for e in Directory.list(url) {
                if out.count >= limit { return }
                let repoPath = repoRel.isEmpty ? e.name : repoRel + "/" + e.name
                if rules.isIgnored(repoPath, isDirectory: e.isDirectory) { continue }
                let path = rel.isEmpty ? e.name : rel + "/" + e.name
                if e.isDirectory {
                    if e.isSymlink { continue }
                    let child = url.appendingPathComponent(e.name)
                    walk(child, path, repoPath, rules.entering(child, relativePath: repoPath))
                } else {
                    out.append(path)
                }
            }
        }
        walk(folder, "", context.prefix, context.stack)
        return out
    }
}

/// One result of a fuzzy search.
public struct FuzzyMatch: Sendable, Equatable {
    /// Index into the index's paths.
    public let index: Int
    public let score: Int
}

/// Paths packed for fast fuzzy matching: one byte array, offsets, and a bit mask per path of
/// the characters it contains (to skip paths that can't match without looking at them).
///
/// Scoring follows fzf's: points per matched character, bonuses for matches at word starts
/// (after `/`, `_`, `-`, `.`, a space, or at a camelCase hump) and for consecutive runs,
/// penalties for gaps; the best alignment is found with dynamic programming (fzf's "v2").
/// Matches entirely inside the file name get an extra bonus, so `main` finds `main.swift`
/// before `domain/x.swift`. Ties go to shorter paths. Queries are case-insensitive unless
/// they contain a capital letter.
public final class FuzzyIndex: Sendable {
    public let count: Int
    private let bytes: [UInt8]
    private let starts: [Int32]
    private let nameStarts: [Int32]
    private let masks: [UInt64]

    public init(paths: [String]) {
        var bytes: [UInt8] = []
        var starts: [Int32] = [0]
        var nameStarts: [Int32] = []
        var masks: [UInt64] = []
        bytes.reserveCapacity(paths.count * 48)
        starts.reserveCapacity(paths.count + 1)
        nameStarts.reserveCapacity(paths.count)
        masks.reserveCapacity(paths.count)
        for p in paths {
            var mask: UInt64 = 0
            var name = 0
            var i = 0
            for b in p.utf8 {
                bytes.append(b)
                mask |= Self.bit(b)
                if b == 0x2F { name = i + 1 }
                i += 1
            }
            starts.append(Int32(bytes.count))
            nameStarts.append(Int32(name))
            masks.append(mask)
        }
        self.bytes = bytes
        self.starts = starts
        self.nameStarts = nameStarts
        self.masks = masks
        count = paths.count
    }

    public func path(_ index: Int) -> String {
        bytes.withUnsafeBufferPointer { b in
            String(decoding: UnsafeBufferPointer(rebasing: b[Int(starts[index])..<Int(starts[index + 1])]), as: UTF8.self)
        }
    }

    private static func bit(_ b: UInt8) -> UInt64 {
        switch b {
        case 0x61...0x7A: 1 << UInt64(b - 0x61)
        case 0x41...0x5A: 1 << UInt64(b - 0x41)
        case 0x30...0x39: 1 << UInt64(26 + b - 0x30)
        case 0x2E: 1 << 36
        case 0x5F: 1 << 37
        case 0x2D: 1 << 38
        case 0x2F: 1 << 39
        case 0x20: 1 << 40
        case 0x80...: 1 << 42
        default: 1 << 41
        }
    }

    /// The result of a search: the best `limit` matches, best first, and every matching index
    /// (pass it to the next search when the query only got longer).
    public struct Results: Sendable {
        public let query: String
        public let top: [FuzzyMatch]
        public let all: [Int32]
        public let caseSensitive: Bool
    }

    /// Searches all paths, or only `previous` matches when the query extends their query.
    public func search(_ query: String, limit: Int = 100, previous: Results? = nil) -> Results {
        let q = Array(query.utf8).filter { $0 != 0x20 }
        let caseSensitive = q.contains { $0 >= 0x41 && $0 <= 0x5A }
        if q.isEmpty {
            let all = (0..<count).map { Int32($0) }
            let top = (0..<min(limit, count)).map { FuzzyMatch(index: $0, score: 0) }
            return Results(query: query, top: top, all: all, caseSensitive: caseSensitive)
        }
        let pattern = caseSensitive ? q : q.map(Self.lower)
        let qmask = pattern.reduce(UInt64(0)) { $0 | Self.bit($1) }
        let narrowing = previous.flatMap { p in
            !p.query.isEmpty && query.hasPrefix(p.query) && p.caseSensitive == caseSensitive ? p.all : nil
        }
        let candidateCount = narrowing?.count ?? count
        let chunks = min(max(1, candidateCount / 256), ProcessInfo.processInfo.activeProcessorCount * 4)
        let perChunk = (candidateCount + chunks - 1) / chunks
        let lists = UnsafeMutableBufferPointer<[Int32]>.allocate(capacity: chunks)
        let tops = UnsafeMutableBufferPointer<[FuzzyMatch]>.allocate(capacity: chunks)
        lists.initialize(repeating: [])
        tops.initialize(repeating: [])
        defer {
            lists.deinitialize()
            lists.deallocate()
            tops.deinitialize()
            tops.deallocate()
        }
        nonisolated(unsafe) let listsOut = lists, topsOut = tops
        DispatchQueue.concurrentPerform(iterations: chunks) { c in
            let lo = c * perChunk, hi = min(candidateCount, lo + perChunk)
            guard lo < hi else { return }
            var found: [Int32] = []
            var heap = TopK(limit: limit)
            var scratch = Scratch()
            bytes.withUnsafeBufferPointer { text in
                pattern.withUnsafeBufferPointer { pat in
                    for k in lo..<hi {
                        let i = narrowing.map { Int($0[k]) } ?? k
                        guard masks[i] & qmask == qmask else { continue }
                        let s = Int(starts[i]), e = Int(starts[i + 1])
                        guard let score = Self.score(text, s, e, Int(nameStarts[i]), pat, caseSensitive, &scratch) else { continue }
                        found.append(Int32(i))
                        heap.insert(FuzzyMatch(index: i, score: score), length: e - s)
                    }
                }
            }
            listsOut[c] = found
            topsOut[c] = heap.items.map(\.match)
        }
        var all: [Int32] = []
        all.reserveCapacity(lists.reduce(0) { $0 + $1.count })
        for l in lists { all.append(contentsOf: l) }
        var best = tops.flatMap { $0 }
        best.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            let la = starts[a.index + 1] - starts[a.index], lb = starts[b.index + 1] - starts[b.index]
            if la != lb { return la < lb }
            return a.index < b.index
        }
        return Results(query: query, top: Array(best.prefix(limit)), all: all, caseSensitive: caseSensitive)
    }

    /// Byte offsets (within the path) of the characters a match used, for highlighting.
    public func positions(of index: Int, query: String) -> [Int] {
        let q = Array(query.utf8).filter { $0 != 0x20 }
        let caseSensitive = q.contains { $0 >= 0x41 && $0 <= 0x5A }
        let pattern = caseSensitive ? q : q.map(Self.lower)
        let s = Int(starts[index]), e = Int(starts[index + 1])
        let path = Array(bytes[s..<e])
        return Self.align(path, pattern, caseSensitive)
    }

    // MARK: - Scoring

    static let scoreMatch = 16
    static let gapStart = -3
    static let gapExtension = -1
    static let bonusBoundary = scoreMatch / 2
    static let bonusNonWord = scoreMatch / 2
    static let bonusCamel = bonusBoundary + gapExtension
    static let bonusConsecutive = -(gapStart + gapExtension)
    static let bonusFirstCharMultiplier = 2
    static let bonusBoundaryWhite = bonusBoundary + 2
    static let bonusBoundaryDelimiter = bonusBoundary + 1
    static let bonusFileName = scoreMatch * 2

    private enum CharClass: Int { case white, nonWord, delimiter, lower, upper, number }

    private static func lower(_ b: UInt8) -> UInt8 { b >= 0x41 && b <= 0x5A ? b | 0x20 : b }

    private static func charClass(_ b: UInt8) -> CharClass {
        switch b {
        case 0x61...0x7A: .lower
        case 0x41...0x5A: .upper
        case 0x30...0x39: .number
        case 0x20, 0x09: .white
        case 0x2F, 0x2C, 0x3A, 0x3B, 0x7C: .delimiter
        case 0x80...: .lower // letters in other scripts
        default: .nonWord
        }
    }

    private static func bonus(_ prev: CharClass, _ cur: CharClass) -> Int {
        if cur.rawValue > CharClass.delimiter.rawValue {
            switch prev {
            case .white: return bonusBoundaryWhite
            case .delimiter: return bonusBoundaryDelimiter
            case .nonWord: return bonusBoundary
            default: break
            }
        }
        if (prev == .lower && cur == .upper) || (prev != .number && cur == .number) { return bonusCamel }
        switch cur {
        case .nonWord, .delimiter: return bonusNonWord
        case .white: return bonusBoundaryWhite
        default: return 0
        }
    }

    /// Reusable rows for the alignment, so scoring allocates nothing per path.
    struct Scratch {
        var score: [Int32] = []
        var prevScore: [Int32] = []
        var run: [Int32] = []
        var prevRun: [Int32] = []
        var bonus: [Int32] = []
        /// Per pattern character, the first and last column it can match.
        var lo: [Int] = []
        var hi: [Int] = []
    }

    private static let impossible: Int32 = -1_000_000

    /// Best score for the pattern in text[s..<e], or nil if it doesn't match.
    private static func score(_ t: UnsafeBufferPointer<UInt8>, _ s: Int, _ e: Int, _ nameStart: Int,
                              _ p: UnsafeBufferPointer<UInt8>, _ caseSensitive: Bool, _ scratch: inout Scratch) -> Int? {
        let m = p.count
        @inline(__always) func at(_ i: Int) -> UInt8 { caseSensitive ? t[i] : lower(t[i]) }
        // Forward: the earliest place each pattern character can be (greedy left to right).
        if scratch.lo.count < m {
            scratch.lo = Array(repeating: 0, count: m)
            scratch.hi = Array(repeating: 0, count: m)
        }
        var pi = 0, i = s
        while i < e && pi < m {
            if at(i) == p[pi] {
                scratch.lo[pi] = i
                pi += 1
            }
            i += 1
        }
        guard pi == m else { return nil }
        // Backward: the latest place each can be (greedy right to left).
        i = e - 1
        pi = m - 1
        while pi >= 0 {
            if at(i) == p[pi] {
                scratch.hi[pi] = i
                pi -= 1
            }
            i -= 1
        }
        let first = scratch.lo[0]
        let base = first
        let n = scratch.hi[m - 1] - first + 1
        for r in 0..<m {
            scratch.lo[r] -= base
            scratch.hi[r] -= base
        }

        if scratch.bonus.count < n {
            let size = max(n, 64)
            scratch.score = Array(repeating: 0, count: size)
            scratch.prevScore = Array(repeating: 0, count: size)
            scratch.run = Array(repeating: 0, count: size)
            scratch.prevRun = Array(repeating: 0, count: size)
            scratch.bonus = Array(repeating: 0, count: size)
        }
        var prevClass: CharClass = base > s ? charClass(t[base - 1]) : .delimiter
        for j in 0..<n {
            let c = charClass(t[base + j])
            scratch.bonus[j] = Int32(bonus(prevClass, c))
            prevClass = c
        }

        var best = impossible
        // Row 0: the first pattern character, with the first-character multiplier. Each row
        // only covers the columns its character can occupy.
        for j in scratch.lo[0]...scratch.hi[0] {
            if at(base + j) == p[0] {
                scratch.prevScore[j] = Int32(scoreMatch) + scratch.bonus[j] * Int32(bonusFirstCharMultiplier)
                scratch.prevRun[j] = scratch.bonus[j]
                if m == 1 && scratch.prevScore[j] > best { best = scratch.prevScore[j] }
            } else {
                scratch.prevScore[j] = impossible
            }
        }
        // Rows 1...: each character either continues a run or follows a gap.
        var row = 1
        while row < m {
            let pc = p[row]
            let plo = scratch.lo[row - 1], phi = scratch.hi[row - 1]
            let lo = scratch.lo[row], hi = scratch.hi[row]
            var gap = impossible // best score for a match at j after a gap of at least one
            var j = plo + 1
            while j <= hi {
                let k = j - 2
                if k >= plo && k <= phi {
                    let open = scratch.prevScore[k] == impossible ? impossible : scratch.prevScore[k] + Int32(gapStart)
                    let extend = gap == impossible ? impossible : gap + Int32(gapExtension)
                    gap = max(open, extend)
                } else if gap != impossible {
                    gap += Int32(gapExtension)
                }
                if j < lo {
                    j += 1
                    continue
                }
                guard at(base + j) == pc else {
                    scratch.score[j] = impossible
                    j += 1
                    continue
                }
                let b = scratch.bonus[j]
                var value = impossible, run: Int32 = 0
                if j - 1 <= phi, scratch.prevScore[j - 1] != impossible {
                    var firstBonus = scratch.prevRun[j - 1]
                    if b >= Int32(bonusBoundary) && b > firstBonus { firstBonus = b }
                    value = scratch.prevScore[j - 1] + Int32(scoreMatch) + max(b, firstBonus, Int32(bonusConsecutive))
                    run = firstBonus
                }
                if gap != impossible {
                    let g = gap + Int32(scoreMatch) + b
                    if g > value {
                        value = g
                        run = b
                    }
                }
                scratch.score[j] = value
                scratch.run[j] = run
                if row == m - 1 && value > best { best = value }
                j += 1
            }
            swap(&scratch.score, &scratch.prevScore)
            swap(&scratch.run, &scratch.prevRun)
            row += 1
        }
        guard best != impossible else { return nil }
        var total = Int(best)
        // Whole query inside the file name.
        if first >= s + nameStart || inName(t, s + nameStart, e, p, caseSensitive) { total += bonusFileName }
        return total
    }

    private static func inName(_ t: UnsafeBufferPointer<UInt8>, _ from: Int, _ e: Int, _ p: UnsafeBufferPointer<UInt8>, _ caseSensitive: Bool) -> Bool {
        var pi = 0, i = from
        while i < e && pi < p.count {
            let c = caseSensitive ? t[i] : lower(t[i])
            if c == p[pi] { pi += 1 }
            i += 1
        }
        return pi == p.count
    }

    /// The same alignment as `score`, keeping full matrices to recover the positions.
    static func align(_ text: [UInt8], _ p: [UInt8], _ caseSensitive: Bool) -> [Int] {
        let n = text.count, m = p.count
        guard m > 0, n > 0 else { return [] }
        let t = caseSensitive ? text : text.map(lower)
        var bonusRow = [Int](repeating: 0, count: n)
        var prevClass = CharClass.delimiter
        for j in 0..<n {
            let c = charClass(text[j])
            bonusRow[j] = bonus(prevClass, c)
            prevClass = c
        }
        let none = Int.min / 4
        var score = [[Int]](repeating: [Int](repeating: none, count: n), count: m)
        var run = [[Int]](repeating: [Int](repeating: 0, count: n), count: m)
        var from = [[Int]](repeating: [Int](repeating: -1, count: n), count: m) // previous match column
        for j in 0..<n where t[j] == p[0] {
            score[0][j] = scoreMatch + bonusRow[j] * bonusFirstCharMultiplier
            run[0][j] = bonusRow[j]
        }
        if m > 1 {
            for row in 1..<m {
                var gap = none, gapFrom = -1
                for j in 0..<n {
                    if j >= 2 {
                        let open = score[row - 1][j - 2] == none ? none : score[row - 1][j - 2] + gapStart
                        let extend = gap == none ? none : gap + gapExtension
                        if open >= extend { gap = open; gapFrom = j - 2 } else { gap = extend }
                    }
                    guard t[j] == p[row] else { continue }
                    let b = bonusRow[j]
                    if j >= 1, score[row - 1][j - 1] != none {
                        var firstBonus = run[row - 1][j - 1]
                        if b >= bonusBoundary && b > firstBonus { firstBonus = b }
                        score[row][j] = score[row - 1][j - 1] + scoreMatch + max(b, firstBonus, bonusConsecutive)
                        run[row][j] = firstBonus
                        from[row][j] = j - 1
                    }
                    if gap != none, gap + scoreMatch + b > score[row][j] {
                        score[row][j] = gap + scoreMatch + b
                        run[row][j] = b
                        from[row][j] = gapFrom
                    }
                }
            }
        }
        var j = (0..<n).max { score[m - 1][$0] < score[m - 1][$1] } ?? 0
        guard score[m - 1][j] != none else { return [] }
        var out = [Int](repeating: 0, count: m)
        for row in stride(from: m - 1, through: 0, by: -1) {
            out[row] = j
            j = from[row][j]
        }
        return out
    }
}

/// Keeps the best `limit` matches seen (ties to shorter paths).
private struct TopK {
    let limit: Int
    var items: [(match: FuzzyMatch, length: Int)] = []

    init(limit: Int) {
        self.limit = limit
        items.reserveCapacity(limit + 1)
    }

    private func better(_ a: (match: FuzzyMatch, length: Int), _ b: (match: FuzzyMatch, length: Int)) -> Bool {
        if a.match.score != b.match.score { return a.match.score > b.match.score }
        if a.length != b.length { return a.length < b.length }
        return a.match.index < b.match.index
    }

    /// A min-heap on "better": the root is the worst kept match.
    mutating func insert(_ m: FuzzyMatch, length: Int) {
        let item = (match: m, length: length)
        if items.count < limit {
            items.append(item)
            var i = items.count - 1
            while i > 0 {
                let parent = (i - 1) / 2
                guard better(items[parent], items[i]) else { break }
                items.swapAt(parent, i)
                i = parent
            }
        } else if limit > 0, better(item, items[0]) {
            items[0] = item
            var i = 0
            while true {
                let l = 2 * i + 1, r = l + 1
                var worst = i
                if l < items.count && better(items[worst], items[l]) { worst = l }
                if r < items.count && better(items[worst], items[r]) { worst = r }
                if worst == i { break }
                items.swapAt(worst, i)
                i = worst
            }
        }
    }
}
