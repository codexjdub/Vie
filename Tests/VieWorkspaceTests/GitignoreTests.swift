import Foundation
import Testing
@testable import VieWorkspace

/// Checks the ignore rules against git itself: the same tree, the same ignore files, and
/// `git ls-files --others` (with and without `--ignored`) as the answer.
@Suite struct GitignoreTests {
    private let dir: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("vie-ignore-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func write(_ path: String, _ text: String = "x") throws {
        let url = dir.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    @discardableResult
    private func git(_ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = args
        p.currentDirectoryURL = dir
        var env = ProcessInfo.processInfo.environment
        env["GIT_CONFIG_GLOBAL"] = dir.appendingPathComponent("test-gitconfig").path
        env["GIT_CONFIG_NOSYSTEM"] = "1"
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    private func gitFiles(ignored: Bool) throws -> Set<String> {
        let out = try git(["ls-files", "-z", "--others", "--exclude-standard"] + (ignored ? ["--ignored"] : []))
        return Set(out.split(separator: "\0").map(String.init))
    }

    /// Our answer: walk the tree, not descending into ignored folders (everything under one
    /// counts as ignored), as git does.
    private func ourFiles(_ context: IgnoreContext) -> (included: Set<String>, ignored: Set<String>) {
        var included = Set<String>(), ignored = Set<String>()
        func walk(_ url: URL, _ rel: String, _ stack: IgnoreStack, parentIgnored: Bool) {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
            for name in names where name != ".git" {
                let child = url.appendingPathComponent(name)
                let path = rel.isEmpty ? name : rel + "/" + name
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: child.path, isDirectory: &isDir)
                let ignoredHere = parentIgnored || stack.isIgnored(path, isDirectory: isDir.boolValue)
                if isDir.boolValue {
                    walk(child, path, ignoredHere ? stack : stack.entering(child, relativePath: path), parentIgnored: ignoredHere)
                } else if ignoredHere {
                    ignored.insert(path)
                } else {
                    included.insert(path)
                }
            }
        }
        walk(context.root, context.prefix, context.stack, parentIgnored: false)
        return (included, ignored)
    }

    private func makeTree() throws {
        try write(".gitignore", """
            # a comment
            *.log
            !keep.log
            build/
            /root-only.txt
            docs/**/*.tmp
            **/cache
            a?c.txt
            [abc]x.txt
            [!d]y.txt
            [[:digit:]]z.txt
            \\#hash.txt
            trailing.txt   \n\
            space\\
            dir/*.md
            nested/deep/
            Mixed.TXT
            just-dir/
            foo/**
            !foo/kept.txt
            """)
        try write("sub/.gitignore", "*.o\n!important.o\n/local.txt\nbuild\n")
        try write("info-exclude-me.txt")
        try write("global.swp")
        let files = [
            "a.log", "keep.log", "sub/b.log", "sub/keep.log",
            "build/out.txt", "src/build/out.txt", "src/build.txt",
            "root-only.txt", "sub/root-only.txt",
            "docs/x.tmp", "docs/a/b/c.tmp", "docs/a/keep.txt", "other/x.tmp",
            "cache/a", "src/deep/cache/b", "src/cachefile",
            "abc.txt", "axc.txt", "abbc.txt",
            "ax.txt", "bx.txt", "dx.txt", "ay.txt", "dy.txt", "1z.txt", "az.txt",
            "#hash.txt", "hash.txt",
            "trailing.txt", "space ", "space",
            "dir/a.md", "dir/sub/b.md", "other/dir/c.md",
            "nested/deep/x", "nested/deeper/x", "x/nested/deep/y",
            "mixed.txt",
            "just-dir", "sub2/just-dir/f",
            "foo/a", "foo/b/c", "foo/kept.txt",
            "sub/x.o", "sub/important.o", "sub/deeper/y.o", "x.o",
            "sub/local.txt", "sub/deeper/local.txt", "local.txt",
            "sub/build/z", "sub/q/build",
            "plain.txt", "src/main.swift",
        ]
        for f in files { try write(f) }
    }

    private func check(caseFold: Bool) throws {
        try makeTree()
        try git(["init", "-q"])
        try git(["config", "core.ignorecase", caseFold ? "true" : "false"])
        let global = dir.appendingPathComponent("test-global-ignore")
        try Data("*.swp\ntest-*\n".utf8).write(to: global)
        try Data("[core]\n\texcludesFile = \(global.path)\n".utf8).write(to: dir.appendingPathComponent("test-gitconfig"))
        try Data("info-exclude-me.txt\n".utf8).write(to: dir.appendingPathComponent(".git/info/exclude"))

        let context = IgnoreContext(folder: dir, globalExcludes: global)
        #expect(context.isRepository)
        #expect(context.stack.caseFold == caseFold)
        let ours = ourFiles(context)
        let included = try gitFiles(ignored: false), ignored = try gitFiles(ignored: true)
        #expect(!included.isEmpty && !ignored.isEmpty)
        #expect(ours.included.subtracting(included).sorted() == [], "we include, git ignores")
        #expect(included.subtracting(ours.included).sorted() == [], "git includes, we ignore")
        #expect(ours.ignored == ignored)
    }

    @Test func matchesGitCaseSensitive() throws { try check(caseFold: false) }

    @Test func matchesGitCaseInsensitive() throws { try check(caseFold: true) }

    @Test func subfolderOfARepositoryUsesTheParentRules() throws {
        try write(".gitignore", "*.gen\nsub/skip/\n")
        try write("sub/a.gen")
        try write("sub/skip/b.txt")
        try write("sub/c.txt")
        try git(["init", "-q"])
        let context = IgnoreContext(folder: dir.appendingPathComponent("sub"), globalExcludes: nil)
        #expect(context.root.path == dir.path)
        #expect(context.prefix == "sub")
        #expect(context.stack.isIgnored("sub/a.gen", isDirectory: false))
        #expect(context.stack.isIgnored("sub/skip", isDirectory: true))
        #expect(!context.stack.isIgnored("sub/c.txt", isDirectory: false))
    }

    @Test func wildmatchCases() {
        func m(_ p: String, _ t: String, pathname: Bool = true, fold: Bool = false) -> Bool {
            let pb = Array(p.utf8), tb = Array(t.utf8)
            return pb.withUnsafeBufferPointer { pp in tb.withUnsafeBufferPointer { tp in
                Wildmatch.match(pp, tp, from: 0, pathname: pathname, caseFold: fold)
            } }
        }
        #expect(m("foo", "foo"))
        #expect(!m("foo", "bar"))
        #expect(m("*", "foo"))
        #expect(!m("*", "foo/bar"))
        #expect(m("*", "foo/bar", pathname: false))
        #expect(m("**", "foo/bar"))
        #expect(m("foo/**/bar", "foo/bar"))
        #expect(m("foo/**/bar", "foo/a/b/bar"))
        #expect(!m("foo/**/bar", "foo/abar"))
        #expect(m("**/foo", "a/b/foo"))
        #expect(m("**/foo", "foo"))
        #expect(m("foo/**", "foo/a/b"))
        #expect(!m("foo/**", "foo"))
        #expect(m("f?o", "fxo"))
        #expect(!m("f?o", "f/o"))
        #expect(m("[a-c]x", "bx"))
        #expect(!m("[!a-c]x", "bx"))
        #expect(m("[^a-c]x", "dx"))
        #expect(m("[[:alpha:]]1", "q1"))
        #expect(m("\\*", "*"))
        #expect(!m("\\*", "a"))
        #expect(m("*.TXT", "a.txt", fold: true))
        #expect(m("[A-C]", "b", fold: true))
        #expect(m("a*b*c", "aXbYc"))
        #expect(!m("a*/c", "a/b/c"))
        #expect(m("a*/c", "ax/c"))
    }
}
