import Foundation
import QuartzCore
import VieText
import VieWorkspace

/// A synthetic repository for the workspace benchmarks, and the benchmark itself: listing the
/// tree's top folder, scanning every file for ⌘P, building the fuzzy index, and the time per
/// keystroke while typing queries.
@MainActor
enum RepoBench {
    private static let words = ["app", "core", "model", "view", "controller", "service", "util", "network", "store", "parser",
                                "render", "layout", "theme", "editor", "buffer", "search", "index", "session", "window", "config",
                                "auth", "cache", "event", "file", "folder", "image", "list", "table", "text", "user"]

    /// Writes `count` empty files in nested folders (about 10 per folder), plus an ignored
    /// `node_modules` and `build` with extra files, a `.gitignore`, and a `.git` folder.
    static func generate(path: String, count: Int) throws {
        let root = URL(fileURLWithPath: path)
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try Data("ref: refs/heads/main\n".utf8).write(to: root.appendingPathComponent(".git/HEAD"))
        try Data("node_modules/\nbuild/\n*.o\n".utf8).write(to: root.appendingPathComponent(".gitignore"))
        var rng = SeededGenerator(seed: 0xF11E)
        func word() -> String { words[rng.int(words.count)] }
        func camel() -> String { (0..<(1 + rng.int(3))).map { _ in word().capitalized }.joined() }
        var made = 0, folders = 0
        func makeFolder(_ url: URL, depth: Int, files: Int) throws {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            folders += 1
            for _ in 0..<files where made < count {
                let ext = ["swift", "ts", "md", "json", "c", "h"][rng.int(6)]
                let name = "\(camel())\(rng.int(1000)).\(ext)"
                if fm.createFile(atPath: url.appendingPathComponent(name).path, contents: nil) { made += 1 }
            }
        }
        // Breadth-first: top-level modules, then subfolders, until there are enough files.
        var queue: [(URL, Int)] = (0..<12).map { (root.appendingPathComponent("\(word())-\($0)"), 1) }
        while made < count, !queue.isEmpty {
            let (url, depth) = queue.removeFirst()
            try makeFolder(url, depth: depth, files: 8 + rng.int(6))
            if depth < 8 {
                for k in 0..<(2 + rng.int(3)) { queue.append((url.appendingPathComponent("\(word())\(k)"), depth + 1)) }
            }
        }
        for ignored in ["node_modules/pkg", "build/out"] {
            let dir = root.appendingPathComponent(ignored)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            for i in 0..<2000 { fm.createFile(atPath: dir.appendingPathComponent("f\(i).js").path, contents: nil) }
        }
        print("wrote \(made) files in \(folders) folders (plus 4000 ignored) to \(path)")
    }

    static func run(path: String) {
        let url = URL(fileURLWithPath: path)
        func ms(_ t0: CFTimeInterval) -> Double { (CACurrentMediaTime() - t0) * 1000 }

        var t0 = CACurrentMediaTime()
        let tree = FileTree(folder: url)
        let top = tree.children(of: tree.root)
        let treeMs = ms(t0)
        t0 = CACurrentMediaTime()
        if let first = top.first(where: \.isDirectory) {
            for child in tree.children(of: first) where child.isDirectory { tree.children(of: child) }
        }
        let expandMs = ms(t0)

        t0 = CACurrentMediaTime()
        let context = IgnoreContext(folder: url)
        let paths = PathScanner.scan(context, folder: url)
        let scanMs = ms(t0)
        t0 = CACurrentMediaTime()
        let index = FuzzyIndex(paths: paths)
        let indexMs = ms(t0)

        print("Vie workspace benchmark — \(url.lastPathComponent)")
        print(String(format: "tree         %.1f ms to list the top folder (%d entries); %.1f ms to expand a folder and its subfolders", treeMs, top.count, expandMs))
        print(String(format: "scan         %.0f ms for %@ files (background, for ⌘P)", scanMs, paths.count.formatted()))
        print(String(format: "index        %.0f ms to pack them for matching", indexMs))

        // Typing queries one character at a time, as in the ⌘P field.
        let queries = ["main", "viewcontroller", "srcutil", "netstore", "editorbuffer", "tst", "zzq"]
        var times: [Double] = []
        var firstKey: [Double] = []
        for _ in 0..<3 {
            for q in queries {
                var previous: FuzzyIndex.Results?
                var typed = ""
                for c in q {
                    typed.append(c)
                    let t = CACurrentMediaTime()
                    let r = index.search(typed, limit: 100, previous: previous)
                    let elapsed = ms(t)
                    if typed.count == 1 { firstKey.append(elapsed) } else { times.append(elapsed) }
                    previous = r
                }
            }
        }
        let all = (times + firstKey).sorted()
        func pct(_ p: Double) -> Double { all[min(all.count - 1, Int(Double(all.count) * p))] }
        print(String(format: "keystroke    p50 %.2f ms   p95 %.2f ms   max %.2f ms   (first key, all files: max %.2f ms)",
                     pct(0.5), pct(0.95), all.last ?? 0, firstKey.max() ?? 0))
        let sample = index.search("viewcontroller").top.prefix(3).map { index.path($0.index) }
        print("top for “viewcontroller”: " + sample.joined(separator: ", "))
    }
}
