import CoreServices
import Foundation

/// One entry of a folder listing.
public struct DirectoryEntry: Sendable, Equatable {
    public let name: String
    public let isDirectory: Bool
    public let isSymlink: Bool
}

public enum Directory {
    /// Names never shown or indexed.
    public static let hiddenNames: Set<String> = [".git", ".DS_Store"]

    /// Lists a folder with readdir, which reports file types without a stat per entry.
    /// Symlinks are stat'ed to see whether they point to a folder. Unsorted.
    public static func list(_ url: URL) -> [DirectoryEntry] {
        guard let dir = opendir(url.path) else { return [] }
        defer { closedir(dir) }
        var out: [DirectoryEntry] = []
        while let ent = readdir(dir) {
            let name = withUnsafeBytes(of: ent.pointee.d_name) { raw in
                String(decoding: raw.prefix(Int(ent.pointee.d_namlen)), as: UTF8.self)
            }
            if name == "." || name == ".." || hiddenNames.contains(name) { continue }
            var isDir = ent.pointee.d_type == DT_DIR
            let isLink = ent.pointee.d_type == DT_LNK
            if isLink || ent.pointee.d_type == DT_UNKNOWN {
                var st = stat()
                if stat(url.appendingPathComponent(name).path, &st) == 0 { isDir = (st.st_mode & S_IFMT) == S_IFDIR }
            }
            out.append(DirectoryEntry(name: name, isDirectory: isDir, isSymlink: isLink))
        }
        return out
    }

    /// Finder's order: folders first, then names compared as Finder does ("file2" before "file10").
    public static func sorted(_ entries: [DirectoryEntry]) -> [DirectoryEntry] {
        entries.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
}

/// Watches a folder tree with FSEvents and reports the folders whose contents changed.
@MainActor
public final class FolderWatcher {
    private nonisolated(unsafe) var stream: FSEventStreamRef?
    fileprivate let handler: @MainActor (_ folders: [String], _ rescan: Bool) -> Void

    /// - Parameter handler: called on the main thread with changed folder paths (no trailing
    ///   slash); `rescan` is true when events were dropped and everything should be re-read.
    public init(path: String, latency: TimeInterval = 0.1, handler: @escaping @MainActor ([String], Bool) -> Void) {
        self.handler = handler
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            let drop = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
                                               | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged)
            var rescan = false
            for i in 0..<count where flags[i] & drop != 0 { rescan = true }
            let folders = list.map { $0.count > 1 && $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
            MainActor.assumeIsolated { watcher.handler(folders, rescan) }
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot)
        guard let s = FSEventStreamCreate(nil, callback, &context, [path] as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags) else { return }
        FSEventStreamSetDispatchQueue(s, .main)
        FSEventStreamStart(s)
        stream = s
    }

    public func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }

    deinit {
        if let s = stream {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
        }
    }
}

/// A file or folder in the tree. Folders list their children when first asked.
@MainActor
public final class FileNode {
    public let name: String
    public let url: URL
    public let isDirectory: Bool
    /// Ignored by git (shown dimmed). Everything inside an ignored folder is ignored too.
    public internal(set) var isIgnored: Bool
    public internal(set) weak var parent: FileNode?
    /// Nil until the folder has been listed.
    public internal(set) var children: [FileNode]?
    /// Path relative to the repository root, for matching ignore rules.
    let repoPath: String
    /// Rules that apply to this folder's children (set when it's listed).
    var childRules: IgnoreStack?

    init(name: String, url: URL, isDirectory: Bool, isIgnored: Bool, parent: FileNode?, repoPath: String) {
        self.name = name
        self.url = url
        self.isDirectory = isDirectory
        self.isIgnored = isIgnored
        self.parent = parent
        self.repoPath = repoPath
    }

    /// Path relative to the tree's root folder.
    public var relativePath: String {
        var parts: [String] = []
        var n: FileNode? = self
        while let node = n, node.parent != nil {
            parts.append(node.name)
            n = node.parent
        }
        return parts.reversed().joined(separator: "/")
    }
}

/// The folder tree shown in a workspace window: listed lazily (opening a 100,000-file
/// repository reads only its top folder), kept current with FSEvents, with git's ignore rules.
@MainActor
public final class FileTree {
    public let root: FileNode
    public let context: IgnoreContext
    /// Called after a folder's children were re-read (with that folder), or with the root
    /// after a full rescan.
    public var onChange: ((FileNode) -> Void)?
    /// Every batch of folder events, listed or not (for keeping a file index current).
    public var onEvents: ((_ folders: [String], _ rescan: Bool) -> Void)?
    private var watcher: FolderWatcher?

    public init(folder: URL, globalExcludes: URL? = IgnoreContext.defaultGlobalExcludes) {
        let url = folder.standardizedFileURL.resolvingSymlinksInPath()
        context = IgnoreContext(folder: url, globalExcludes: globalExcludes)
        root = FileNode(name: url.lastPathComponent, url: url, isDirectory: true, isIgnored: false, parent: nil, repoPath: context.prefix)
    }

    /// The folder's children, listing it first if needed.
    @discardableResult
    public func children(of node: FileNode) -> [FileNode] {
        if let c = node.children { return c }
        guard node.isDirectory else { return [] }
        let c = list(node)
        node.children = c
        return c
    }

    private func rules(for node: FileNode) -> IgnoreStack {
        if let r = node.childRules { return r }
        let parentRules = node.parent.map { rules(for: $0) } ?? context.outerStack
        let r = node.isIgnored ? parentRules : parentRules.entering(node.url, relativePath: node.repoPath)
        node.childRules = r
        return r
    }

    private func list(_ node: FileNode, reusing old: [FileNode] = []) -> [FileNode] {
        let rules = rules(for: node)
        let byName = Dictionary(old.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        return Directory.sorted(Directory.list(node.url)).map { e in
            let path = node.repoPath.isEmpty ? e.name : node.repoPath + "/" + e.name
            let ignored = node.isIgnored || rules.isIgnored(path, isDirectory: e.isDirectory)
            if let existing = byName[e.name], existing.isDirectory == e.isDirectory {
                if existing.isIgnored != ignored {
                    existing.isIgnored = ignored
                    existing.childRules = nil
                    if existing.children != nil { refreshRules(existing) }
                }
                return existing
            }
            return FileNode(name: e.name, url: node.url.appendingPathComponent(e.name), isDirectory: e.isDirectory,
                            isIgnored: ignored, parent: node, repoPath: path)
        }
    }

    /// Re-reads a listed folder, keeping existing child nodes (and their expansion).
    public func reload(_ node: FileNode) {
        guard node.isDirectory, let old = node.children else { return }
        node.childRules = nil
        node.children = list(node, reusing: old)
        refreshRules(node)
    }

    /// Recomputes ignore flags below a folder whose rules changed (a `.gitignore` edit).
    private func refreshRules(_ node: FileNode) {
        let rules = rules(for: node)
        for child in node.children ?? [] {
            let ignored = node.isIgnored || rules.isIgnored(child.repoPath, isDirectory: child.isDirectory)
            if ignored != child.isIgnored || child.childRules != nil {
                child.isIgnored = ignored
                child.childRules = nil
                if child.children != nil { refreshRules(child) }
            }
        }
    }

    /// An item's path with the folders above it resolved (/tmp is /private/tmp), the item
    /// itself left as it is: a link is its own item, not the one it points to.
    public nonisolated static func canonicalPath(_ url: URL) -> String {
        let url = url.standardizedFileURL
        return url.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(url.lastPathComponent).path
    }

    /// The names from the root down to `url`, or nil if it isn't inside the tree; empty for
    /// the root itself (also when the root was opened through a link to it).
    private func parts(to url: URL) -> [Substring]? {
        let path = Self.canonicalPath(url), rootPath = root.url.path
        if path == rootPath || url.standardizedFileURL.resolvingSymlinksInPath().path == rootPath { return [] }
        guard path.hasPrefix(rootPath + "/") else { return nil }
        return path.dropFirst(rootPath.count + 1).split(separator: "/")
    }

    /// The listed node for a URL inside the tree, or nil if it (or a folder above it) hasn't
    /// been listed.
    public func node(for url: URL) -> FileNode? {
        guard let parts = parts(to: url) else { return nil }
        var node = root
        for part in parts {
            guard let next = node.children?.first(where: { $0.name == part }) else { return nil }
            node = next
        }
        return node
    }

    /// Lists the folders down to `url` so its node exists (for revealing a file).
    @discardableResult
    public func expand(to url: URL) -> FileNode? {
        guard let parts = parts(to: url) else { return nil }
        var node = root
        for part in parts {
            guard let next = children(of: node).first(where: { $0.name == part }) else { return nil }
            node = next
        }
        return node
    }

    // MARK: - Watching

    public func startWatching() {
        guard watcher == nil else { return }
        watcher = FolderWatcher(path: root.url.path) { [weak self] folders, rescan in
            self?.foldersChanged(folders, rescan: rescan)
        }
    }

    public func stopWatching() {
        watcher?.stop()
        watcher = nil
    }

    func foldersChanged(_ folders: [String], rescan: Bool) {
        onEvents?(folders, rescan)
        if rescan {
            reloadAll(root)
            onChange?(root)
            return
        }
        for path in Set(folders) {
            guard let node = node(for: URL(fileURLWithPath: path)), node.children != nil else { continue }
            reload(node)
            onChange?(node)
        }
    }

    private func reloadAll(_ node: FileNode) {
        guard node.children != nil else { return }
        reload(node)
        for c in node.children ?? [] where c.children != nil { reloadAll(c) }
    }
}
