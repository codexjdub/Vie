import Foundation

/// Size, modification time and inode of a file: enough to tell whether it changed on disk.
public struct FileFingerprint: Equatable, Codable, Sendable {
    public let size: Int64
    public let modified: Int64 // nanoseconds since 1970
    public let inode: UInt64

    /// Nil if the file doesn't exist (or can't be read).
    public init?(url: URL) {
        var st = stat()
        guard stat(url.path, &st) == 0 else { return nil }
        size = Int64(st.st_size)
        modified = Int64(st.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(st.st_mtimespec.tv_nsec)
        inode = UInt64(st.st_ino)
    }
}

/// Watches one file and calls `onChange` (debounced) when it's written, replaced, renamed or
/// deleted. Keeps working across atomic saves, which replace the file with a new one: after
/// such an event it reopens the path.
@MainActor
public final class FileWatcher {
    private let path: String
    private let onChange: @MainActor () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var pending = false
    private var needsReopen = false
    private var stopped = false

    public init(url: URL, onChange: @escaping @MainActor () -> Void) {
        path = url.path
        self.onChange = onChange
        reopen()
    }

    public func stop() {
        stopped = true
        source?.cancel()
        source = nil
    }

    /// Starts watching again if the file was missing when last checked (it may exist now).
    public func reopenIfNeeded() {
        if source == nil && !stopped { reopen() }
    }

    private func reopen() {
        source?.cancel()
        source = nil
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        let s = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .attrib, .delete, .rename, .revoke], queue: .main)
        s.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.handleEvent() }
        }
        s.setCancelHandler { close(fd) }
        s.resume()
        source = s
    }

    private func handleEvent() {
        guard let flags = source?.data else { return }
        if !flags.isDisjoint(with: [.delete, .rename, .revoke]) { needsReopen = true }
        guard !pending else { return }
        pending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            MainActor.assumeIsolated { self?.fire() }
        }
    }

    private func fire() {
        pending = false
        guard !stopped else { return }
        if needsReopen {
            needsReopen = false
            reopen()
        }
        onChange()
    }
}

/// Safe file writing.
public enum FileWriter {
    /// Writes `data` to `url` atomically: a crash or full disk never leaves a half-written file.
    /// An existing file keeps its permissions and other metadata, and writing to a symlink
    /// updates the file it points to rather than replacing the link.
    public static func write(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        let target = url.resolvingSymlinksInPath()
        guard fm.fileExists(atPath: target.path) else {
            try data.write(to: target, options: .atomic)
            return
        }
        let dir = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: target, create: true)
        defer { try? fm.removeItem(at: dir) }
        let temp = dir.appendingPathComponent(target.lastPathComponent)
        try data.write(to: temp)
        _ = try fm.replaceItemAt(target, withItemAt: temp)
    }
}
