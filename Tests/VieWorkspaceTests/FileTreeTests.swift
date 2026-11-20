import Foundation
import Testing
@testable import VieWorkspace

@MainActor
@Suite struct FileTreeTests {
    private let dir: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("vie-tree-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func write(_ path: String, _ text: String = "x") throws {
        let url = dir.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func names(_ nodes: [FileNode]) -> [String] {
        nodes.map { ($0.isDirectory ? $0.name + "/" : $0.name) + ($0.isIgnored ? " (ignored)" : "") }
    }

    @Test func listsLazilyInFinderOrderWithIgnoredFilesMarked() throws {
        try write(".gitignore", "*.log\nbuild/\n")
        for f in ["file10.txt", "file2.txt", "b/x.txt", "a.log", "build/out", "Zeta/y", ".hidden", ".DS_Store", ".git/HEAD"] {
            try write(f)
        }
        let tree = FileTree(folder: dir, globalExcludes: nil)
        #expect(tree.root.children == nil)
        let top = tree.children(of: tree.root)
        #expect(names(top) == ["b/", "build/ (ignored)", "Zeta/", ".gitignore", ".hidden", "a.log (ignored)", "file2.txt", "file10.txt"])
        let build = try #require(top.first { $0.name == "build" })
        #expect(build.children == nil)
        #expect(names(tree.children(of: build)) == ["out (ignored)"])
        #expect(top.first { $0.name == "b" }?.children == nil) // still not listed
    }

    @Test func reloadKeepsNodesAndFollowsGitignoreChanges() throws {
        try write("src/a.swift")
        try write("src/gen/b.swift")
        let tree = FileTree(folder: dir, globalExcludes: nil)
        let src = try #require(tree.children(of: tree.root).first)
        let gen = try #require(tree.children(of: src).first { $0.name == "gen" })
        tree.children(of: gen)
        try write("src/new.swift")
        try write(".gitignore", "gen/\n")
        tree.reload(tree.root)
        tree.reload(src)
        #expect(tree.children(of: tree.root).first === src)
        #expect(names(src.children ?? []) == ["gen/ (ignored)", "a.swift", "new.swift"])
        #expect(src.children?.first === gen)
        #expect(gen.children?.first?.isIgnored == true)
        try FileManager.default.removeItem(at: dir.appendingPathComponent(".gitignore"))
        tree.reload(tree.root)
        #expect(gen.isIgnored == false)
        #expect(gen.children?.first?.isIgnored == false)
    }

    @Test func expandFindsDeepNodes() throws {
        try write("a/b/c/d.txt")
        let tree = FileTree(folder: dir, globalExcludes: nil)
        #expect(tree.node(for: dir.appendingPathComponent("a/b")) == nil)
        let d = try #require(tree.expand(to: dir.appendingPathComponent("a/b/c/d.txt")))
        #expect(d.relativePath == "a/b/c/d.txt")
        #expect(tree.node(for: dir.appendingPathComponent("a/b/c")) === d.parent)
    }

    @Test func watchingReportsNewFiles() async throws {
        try write("sub/a.txt")
        let tree = FileTree(folder: dir, globalExcludes: nil)
        let sub = try #require(tree.children(of: tree.root).first)
        tree.children(of: sub)
        var changed: [String] = []
        tree.onChange = { changed.append($0.relativePath) }
        tree.startWatching()
        defer { tree.stopWatching() }
        try await Task.sleep(for: .milliseconds(200))
        try write("sub/b.txt")
        for _ in 0..<40 where !(sub.children ?? []).contains(where: { $0.name == "b.txt" }) {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(names(sub.children ?? []) == ["a.txt", "b.txt"])
        #expect(changed.contains("sub"))
    }

    @Test func scannerSkipsIgnoredFolders() throws {
        try write(".gitignore", "node_modules/\n*.o\n")
        for f in ["src/a.swift", "src/a.o", "node_modules/x/y.js", "README.md", ".git/config"] { try write(f) }
        let context = IgnoreContext(folder: dir, globalExcludes: nil)
        let paths = PathScanner.scan(context, folder: dir).sorted()
        #expect(paths == [".gitignore", "README.md", "src/a.swift"])
    }
}

@Suite struct FuzzyTests {
    private let paths = [
        "src/domain/x.swift",
        "src/main.swift",
        "Sources/Vie/MainMenu.swift",
        "docs/maintenance.md",
        "Sources/VieEditor/EditorView.swift",
        "Sources/VieText/Rope.swift",
        "Tests/VieEditorTests/EditorViewTests.swift",
        "a/m/a/i/n.txt",
    ]

    private func top(_ query: String, _ index: FuzzyIndex? = nil) -> [String] {
        let index = index ?? FuzzyIndex(paths: paths)
        return index.search(query).top.map { index.path($0.index) }
    }

    @Test func fileNameMatchesComeFirst() {
        let r = top("main")
        #expect(r.first == "src/main.swift")
        #expect(r.contains("src/domain/x.swift"))
        #expect(r.firstIndex(of: "a/m/a/i/n.txt")! > r.firstIndex(of: "docs/maintenance.md")!)
    }

    @Test func wordStartsAndCamelHumpsScoreHigher() {
        #expect(top("edv").first == "Sources/VieEditor/EditorView.swift")
        #expect(top("rope").first == "Sources/VieText/Rope.swift")
    }

    @Test func capitalsMakeTheQueryCaseSensitive() {
        let r = top("Main")
        #expect(r == ["Sources/Vie/MainMenu.swift"])
        #expect(top("zzz").isEmpty)
    }

    @Test func narrowingGivesTheSameResults() {
        var words: [String] = []
        var rng = SystemRandomNumberGenerator()
        let parts = ["src", "lib", "view", "model", "test", "util", "main", "app", "core", "net"]
        for i in 0..<5000 {
            let depth = Int.random(in: 1...4, using: &rng)
            words.append((0..<depth).map { _ in parts.randomElement(using: &rng)! }.joined(separator: "/") + "/file\(i).swift")
        }
        let index = FuzzyIndex(paths: words)
        let a = index.search("vi")
        let b = index.search("vimo", previous: a)
        let c = index.search("vimo")
        #expect(b.top == c.top)
        #expect(Set(b.all) == Set(c.all))
    }

    @Test func positionsShowTheMatch() {
        let index = FuzzyIndex(paths: paths)
        #expect(index.positions(of: 1, query: "main") == [4, 5, 6, 7])
        #expect(index.positions(of: 4, query: "edv") == [18, 19, 24])
    }
}
