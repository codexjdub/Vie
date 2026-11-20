import Foundation

/// Git's ignore rules, matched the way git matches them: `.gitignore` files, the repository's
/// `info/exclude` and the global excludes file, with git's precedence (a deeper file beats a
/// shallower one, a later line beats an earlier one) and its glob rules (a port of git's
/// wildmatch.c and the pattern parsing in dir.c). Paths are relative to the repository root,
/// as UTF-8 bytes with `/` separators.
public struct IgnorePattern: Sendable, Equatable {
    /// The glob, without a leading `!` or trailing `/`.
    let glob: [UInt8]
    /// `!pattern`: re-includes what an earlier pattern excluded.
    let negative: Bool
    /// `pattern/`: matches directories only.
    let mustBeDirectory: Bool
    /// No slash in the pattern: it matches the last path component, at any depth.
    let basenameOnly: Bool
    /// Leading characters with no glob specials, compared directly before globbing.
    let literalPrefix: Int

    /// Parses one line of an ignore file, or returns nil for blank lines and comments.
    public init?(line: Substring) {
        var p = Array(line.utf8)
        if p.last == 0x0D { p.removeLast() } // CRLF files
        // Trailing spaces are dropped unless escaped with a backslash.
        while let last = p.last, last == 0x20 {
            var backslashes = 0, i = p.count - 2
            while i >= 0 && p[i] == 0x5C { backslashes += 1; i -= 1 }
            if backslashes % 2 == 1 { break }
            p.removeLast()
        }
        guard let first = p.first, first != 0x23 /* # */ else { return nil }
        var negative = false
        if first == 0x21 /* ! */ {
            negative = true
            p.removeFirst()
        }
        var mustBeDirectory = false
        if p.last == 0x2F {
            mustBeDirectory = true
            p.removeLast()
        }
        guard !p.isEmpty else { return nil }
        self.negative = negative
        self.mustBeDirectory = mustBeDirectory
        basenameOnly = !p.contains(0x2F)
        if !basenameOnly && p.first == 0x2F { p.removeFirst() }
        glob = p
        literalPrefix = p.firstIndex { $0 == 0x2A || $0 == 0x3F || $0 == 0x5B || $0 == 0x5C } ?? p.count
    }

    /// Whether the pattern matches `path`, which lies under `base` (the ignore file's
    /// directory, "" for the root) and whose last component starts at `nameStart`.
    func matches(_ path: [UInt8], nameStart: Int, isDirectory: Bool, base: [UInt8], caseFold: Bool) -> Bool {
        if mustBeDirectory && !isDirectory { return false }
        if basenameOnly {
            return path.withUnsafeBufferPointer { b in
                glob.withUnsafeBufferPointer { g in
                    Self.literalMatch(g, b, from: nameStart, prefix: literalPrefix, caseFold: caseFold)
                        && Wildmatch.match(g, b, from: nameStart, pathname: false, caseFold: caseFold)
                }
            }
        }
        var start = 0
        if !base.isEmpty {
            guard path.count > base.count, path[base.count] == 0x2F,
                  Self.equal(path, 0, base, caseFold: caseFold) else { return false }
            start = base.count + 1
        }
        return path.withUnsafeBufferPointer { b in
            glob.withUnsafeBufferPointer { g in
                Self.literalMatch(g, b, from: start, prefix: literalPrefix, caseFold: caseFold)
                    && Wildmatch.match(g, b, from: start, pathname: true, caseFold: caseFold)
            }
        }
    }

    /// Quick rejection: the pattern's literal prefix must start the text.
    private static func literalMatch(_ g: UnsafeBufferPointer<UInt8>, _ t: UnsafeBufferPointer<UInt8>, from: Int, prefix: Int, caseFold: Bool) -> Bool {
        guard prefix > 0 else { return true }
        guard t.count - from >= prefix else { return false }
        for i in 0..<prefix where !Wildmatch.same(g[i], t[from + i], caseFold) { return false }
        return true
    }

    private static func equal(_ a: [UInt8], _ offset: Int, _ b: [UInt8], caseFold: Bool) -> Bool {
        for i in 0..<b.count where !Wildmatch.same(a[offset + i], b[i], caseFold) { return false }
        return true
    }
}

/// The patterns of one ignore file and the directory they apply to.
public struct IgnoreList: Sendable, Equatable {
    /// Directory relative to the repository root ("" for the root or for repository-wide lists).
    public let base: [UInt8]
    public let patterns: [IgnorePattern]

    public init(base: String, text: String) {
        self.base = Array(base.utf8)
        patterns = text.split(separator: "\n", omittingEmptySubsequences: true).compactMap(IgnorePattern.init(line:))
    }

    /// Reads an ignore file; nil if it doesn't exist or has no patterns.
    public static func load(_ url: URL, base: String) -> IgnoreList? {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        let list = IgnoreList(base: base, text: String(decoding: data, as: UTF8.self))
        return list.patterns.isEmpty ? nil : list
    }
}

/// The ignore lists that apply inside one directory: repository-wide lists first, then the
/// `.gitignore` of each directory from the root down. Cheap to extend while walking a tree.
public struct IgnoreStack: Sendable, Equatable {
    public private(set) var lists: [IgnoreList]
    public let caseFold: Bool

    public init(lists: [IgnoreList] = [], caseFold: Bool = false) {
        self.lists = lists
        self.caseFold = caseFold
    }

    /// The stack for a subdirectory: this one plus its `.gitignore`, if it has one.
    public func entering(_ directory: URL, relativePath: String) -> IgnoreStack {
        guard let list = IgnoreList.load(directory.appendingPathComponent(".gitignore"), base: relativePath) else { return self }
        var s = self
        s.lists.append(list)
        return s
    }

    /// Whether git ignores `path` (relative to the repository root). The caller is responsible
    /// for the rule that nothing inside an ignored directory can be re-included: walkers
    /// don't descend into ignored directories.
    public func isIgnored(_ path: String, isDirectory: Bool) -> Bool {
        isIgnored(Array(path.utf8), isDirectory: isDirectory)
    }

    public func isIgnored(_ path: [UInt8], isDirectory: Bool) -> Bool {
        let nameStart = (path.lastIndex(of: 0x2F) ?? -1) + 1
        for list in lists.reversed() {
            for p in list.patterns.reversed() where p.matches(path, nameStart: nameStart, isDirectory: isDirectory, base: list.base, caseFold: caseFold) {
                return !p.negative
            }
        }
        return false
    }
}

/// Where a folder sits in git terms: its repository (if any) and the ignore rules that apply
/// at the folder itself.
public struct IgnoreContext: Sendable {
    /// The repository's top folder, or the folder itself when it isn't in a repository.
    public let root: URL
    /// The folder's path relative to `root` ("" when they're the same).
    public let prefix: String
    /// Rules in force inside the folder (repository-wide lists plus `.gitignore` files from
    /// `root` down to and including the folder).
    public let stack: IgnoreStack
    /// The same without the folder's own `.gitignore` (so it can be re-read when it changes).
    public let outerStack: IgnoreStack
    public let isRepository: Bool

    /// - Parameter globalExcludes: the global excludes file; by default git's
    ///   (`$XDG_CONFIG_HOME/git/ignore`, else `~/.config/git/ignore`).
    public init(folder: URL, globalExcludes: URL? = IgnoreContext.defaultGlobalExcludes) {
        let folder = folder.standardizedFileURL.resolvingSymlinksInPath()
        var repo: URL?
        var dir = folder.path
        while true {
            if FileManager.default.fileExists(atPath: (dir as NSString).appendingPathComponent(".git")) {
                repo = URL(fileURLWithPath: dir)
                break
            }
            let parent = (dir as NSString).deletingLastPathComponent
            if parent == dir || parent.isEmpty { break }
            dir = parent
        }
        isRepository = repo != nil
        root = repo ?? folder
        let rel = String(folder.path.dropFirst(root.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        prefix = rel

        var lists: [IgnoreList] = []
        var caseFold = false
        if let repo {
            if let global = globalExcludes, let list = IgnoreList.load(global, base: "") { lists.append(list) }
            let gitDir = Self.gitDirectory(repo)
            if let list = IgnoreList.load(gitDir.appendingPathComponent("info/exclude"), base: "") { lists.append(list) }
            caseFold = Self.ignoreCase(gitDir.appendingPathComponent("config"))
        }
        var stack = IgnoreStack(lists: lists, caseFold: caseFold)
        var outer = stack
        stack = stack.entering(root, relativePath: "")
        var path = ""
        for part in rel.split(separator: "/") {
            outer = stack
            path = path.isEmpty ? String(part) : path + "/" + part
            stack = stack.entering(root.appendingPathComponent(path), relativePath: path)
        }
        self.stack = stack
        outerStack = outer
    }

    public static var defaultGlobalExcludes: URL? {
        if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            return URL(fileURLWithPath: xdg).appendingPathComponent("git/ignore")
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/git/ignore")
    }

    /// `.git` is usually a folder, but in worktrees and submodules it's a file naming the real one.
    private static func gitDirectory(_ repo: URL) -> URL {
        let dotGit = repo.appendingPathComponent(".git")
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDir), !isDir.boolValue,
           let text = try? String(contentsOf: dotGit, encoding: .utf8), text.hasPrefix("gitdir:") {
            let path = text.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespacesAndNewlines)
            return path.hasPrefix("/") ? URL(fileURLWithPath: path) : repo.appendingPathComponent(path)
        }
        return dotGit
    }

    /// `core.ignorecase` from the repository's config (git sets it on case-insensitive disks).
    private static func ignoreCase(_ config: URL) -> Bool {
        guard let text = try? String(contentsOf: config, encoding: .utf8) else { return false }
        var inCore = false
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces).lowercased()
            if line.hasPrefix("[") { inCore = line.hasPrefix("[core]"); continue }
            guard inCore, line.hasPrefix("ignorecase") else { continue }
            let value = line.split(separator: "=").last?.trimmingCharacters(in: .whitespaces) ?? ""
            return value == "true" || value == "yes" || value == "on" || value == "1"
        }
        return false
    }
}

/// git's wildmatch: `*` and `?` don't cross `/` in pathname mode, `**` as a whole path
/// component matches any number of directories, `[...]` classes with ranges, `!`/`^`
/// negation and `[:alpha:]`-style names, backslash escapes.
enum Wildmatch {
    private enum Result { case match, noMatch, abortAll, abortToStarStar }

    static func same(_ a: UInt8, _ b: UInt8, _ caseFold: Bool) -> Bool {
        a == b || (caseFold && lower(a) == lower(b))
    }

    private static func lower(_ c: UInt8) -> UInt8 { c >= 0x41 && c <= 0x5A ? c | 0x20 : c }

    static func match(_ pattern: UnsafeBufferPointer<UInt8>, _ text: UnsafeBufferPointer<UInt8>, from: Int, pathname: Bool, caseFold: Bool) -> Bool {
        dowild(pattern, 0, text, from, pathname, caseFold) == .match
    }

    private static func isGlobSpecial(_ c: UInt8) -> Bool { c == 0x2A || c == 0x3F || c == 0x5B || c == 0x5C }

    private static func dowild(_ p: UnsafeBufferPointer<UInt8>, _ pStart: Int, _ t: UnsafeBufferPointer<UInt8>, _ tStart: Int,
                               _ pathname: Bool, _ fold: Bool) -> Result {
        var pi = pStart, ti = tStart
        func pc(_ i: Int) -> UInt8 { i < p.count ? p[i] : 0 }
        func tc(_ i: Int) -> UInt8 { i < t.count ? t[i] : 0 }
        while pi < p.count {
            var pch = p[pi]
            var tch = tc(ti)
            if ti >= t.count && pch != 0x2A { return .abortAll }
            if fold { tch = lower(tch); pch = lower(pch) }
            switch pch {
            case 0x3F: // ?
                if pathname && tch == 0x2F { return .noMatch }
            case 0x2A: // *
                var matchSlash: Bool
                pi += 1
                if pc(pi) == 0x2A {
                    let prev = pi - 2
                    while pc(pi) == 0x2A { pi += 1 }
                    if (prev < pStart || p[prev] == 0x2F) && (pi >= p.count || p[pi] == 0x2F || (pc(pi) == 0x5C && pc(pi + 1) == 0x2F)) {
                        if pc(pi) == 0x2F && dowild(p, pi + 1, t, ti, pathname, fold) == .match { return .match }
                        matchSlash = true
                    } else {
                        matchSlash = !pathname
                    }
                } else {
                    matchSlash = !pathname
                }
                if pi >= p.count {
                    // Trailing "**" matches everything; trailing "*" only if no slash is left.
                    if !matchSlash {
                        var k = ti
                        while k < t.count { if t[k] == 0x2F { return .noMatch }; k += 1 }
                    }
                    return .match
                } else if !matchSlash && p[pi] == 0x2F {
                    // One "*" before a slash matches the rest of this path component.
                    var k = ti
                    while k < t.count && t[k] != 0x2F { k += 1 }
                    if k >= t.count { return .noMatch }
                    ti = k
                    break
                }
                while true {
                    if ti >= t.count { break }
                    if !isGlobSpecial(p[pi]) {
                        // Skip ahead to the next occurrence of the literal after the star.
                        let want = fold ? lower(p[pi]) : p[pi]
                        var c: UInt8 = 0
                        while ti < t.count {
                            c = fold ? lower(t[ti]) : t[ti]
                            if !matchSlash && c == 0x2F { break }
                            if c == want { break }
                            ti += 1
                        }
                        if ti >= t.count || c != want { return .noMatch }
                    }
                    let r = dowild(p, pi, t, ti, pathname, fold)
                    if r != .noMatch {
                        if !matchSlash || r != .abortToStarStar { return r }
                    } else if !matchSlash && tc(ti) == 0x2F {
                        return .abortToStarStar
                    }
                    ti += 1
                }
                return .abortAll
            case 0x5B: // [
                pi += 1
                var c = pc(pi)
                var negated = false
                if c == 0x21 || c == 0x5E { negated = true; pi += 1; c = pc(pi) }
                var prev: UInt8 = 0
                var matched = false
                repeat {
                    if pi >= p.count { return .abortAll }
                    if c == 0x5C {
                        pi += 1
                        c = pc(pi)
                        if pi >= p.count { return .abortAll }
                        if same(tch, c, fold) { matched = true }
                    } else if c == 0x2D && prev != 0 && pi + 1 < p.count && p[pi + 1] != 0x5D {
                        pi += 1
                        c = p[pi]
                        if c == 0x5C {
                            pi += 1
                            if pi >= p.count { return .abortAll }
                            c = p[pi]
                        }
                        let raw = tc(ti)
                        if raw <= c && raw >= prev { matched = true }
                        else if fold, raw >= 0x61 && raw <= 0x7A, (raw - 0x20) <= c && (raw - 0x20) >= prev { matched = true }
                        else if fold, raw >= 0x41 && raw <= 0x5A, (raw | 0x20) <= c && (raw | 0x20) >= prev { matched = true }
                        c = 0
                    } else if c == 0x5B && pc(pi + 1) == 0x3A {
                        // [:class:]
                        var k = pi + 2
                        while k < p.count && p[k] != 0x5D { k += 1 }
                        if k >= p.count { return .abortAll }
                        let nameEnd = k - 1
                        if nameEnd < pi + 2 || p[nameEnd] != 0x3A {
                            // Not a class after all: a literal "[".
                            if tch == 0x5B { matched = true }
                        } else {
                            let name = String(decoding: UnsafeBufferPointer(rebasing: p[(pi + 2)..<nameEnd]), as: UTF8.self)
                            guard let test = classTest(name) else { return .abortAll }
                            if test(tc(ti)) { matched = true }
                            pi = k
                            c = 0
                        }
                    } else if same(tch, c, fold) {
                        matched = true
                    }
                    prev = c
                    pi += 1
                    c = pc(pi)
                } while c != 0x5D
                if matched == negated || (pathname && tch == 0x2F) { return .noMatch }
            case 0x5C: // backslash: the next character is literal
                pi += 1
                var lit = pc(pi)
                if fold { lit = lower(lit) }
                if tch != lit { return .noMatch }
            default:
                if tch != pch { return .noMatch }
            }
            ti += 1
            pi += 1
        }
        return ti >= t.count ? .match : .noMatch
    }

    private static func classTest(_ name: String) -> ((UInt8) -> Bool)? {
        func isUpper(_ c: UInt8) -> Bool { c >= 0x41 && c <= 0x5A }
        func isLower(_ c: UInt8) -> Bool { c >= 0x61 && c <= 0x7A }
        func isDigit(_ c: UInt8) -> Bool { c >= 0x30 && c <= 0x39 }
        switch name {
        case "alnum": return { isUpper($0) || isLower($0) || isDigit($0) }
        case "alpha": return { isUpper($0) || isLower($0) }
        case "blank": return { $0 == 0x20 || $0 == 0x09 }
        case "cntrl": return { $0 < 0x20 || $0 == 0x7F }
        case "digit": return isDigit
        case "graph": return { $0 > 0x20 && $0 < 0x7F }
        case "lower": return isLower
        case "print": return { $0 >= 0x20 && $0 < 0x7F }
        case "punct": return { $0 > 0x20 && $0 < 0x7F && !(isUpper($0) || isLower($0) || isDigit($0)) }
        case "space": return { $0 == 0x20 || ($0 >= 0x09 && $0 <= 0x0D) }
        case "upper": return isUpper
        case "xdigit": return { isDigit($0) || ($0 >= 0x41 && $0 <= 0x46) || ($0 >= 0x61 && $0 <= 0x66) }
        default: return nil
        }
    }
}
