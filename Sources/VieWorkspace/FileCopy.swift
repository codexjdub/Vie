import Foundation

/// Copies files and folders as Finder does (a clone on the same APFS disk, links copied as
/// links, attributes kept), reporting progress and stopping when asked. It runs on the thread
/// that calls it: the file tree calls it off the main thread. A copy is made under a hidden
/// name first (`partialPrefix`) and renamed into place when it's whole, so nothing half copied
/// ever has the final name, and nothing is replaced.
public enum FileCopy {
    /// The start of the names partial copies have while they're made; the tree doesn't list them.
    public static let partialPrefix = ".vie-partial-"

    /// The bytes in the regular files at and under `urls`, for a progress total (links count as
    /// nothing; their targets aren't copied). Gives what it counted so far once `isCancelled`.
    public static func size(of urls: [URL], isCancelled: () -> Bool = { false }) -> Int64 {
        var total: Int64 = 0
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isSymbolicLink != true else { continue }
            if values.isRegularFile == true {
                total += Int64(values.fileSize ?? 0)
                continue
            }
            guard values.isDirectory == true,
                  let walk = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [],
                                                            errorHandler: { _, _ in true }) else { continue }
            for case let item as URL in walk {
                if isCancelled() { return total }
                if let v = try? item.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), v.isRegularFile == true {
                    total += Int64(v.fileSize ?? 0)
                }
            }
        }
        return total
    }

    /// Copies `source` to `target`, which must not exist. `progress` gets the bytes of this
    /// item copied so far. Returns false if stopped (`isCancelled`), leaving nothing behind;
    /// throws if it fails, leaving nothing behind either.
    public static func copy(_ source: URL, to target: URL, progress: @escaping (Int64) -> Void,
                            isCancelled: @escaping () -> Bool) throws -> Bool {
        let folder = target.deletingLastPathComponent()
        let partial = folder.appendingPathComponent(partialPrefix + UUID().uuidString)
        let context = Context(progress: progress, isCancelled: isCancelled)
        let state = copyfile_state_alloc()
        defer { copyfile_state_free(state) }
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), unsafeBitCast(statusCallback, to: UnsafeRawPointer.self))
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), Unmanaged.passUnretained(context).toOpaque())
        let flags = COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_CLONE | COPYFILE_EXCL | COPYFILE_NOFOLLOW_SRC
        let result = withExtendedLifetime(context) { copyfile(source.path, partial.path, state, copyfile_flags_t(flags)) }
        let code = errno
        guard result == 0, !context.cancelled else {
            try? FileManager.default.removeItem(at: partial)
            if context.cancelled { return false }
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: target.path,
                                                           NSUnderlyingErrorKey: POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)])
        }
        // Into place only if the name is still free: a rename never replaces what's there.
        guard renamex_np(partial.path, target.path, UInt32(RENAME_EXCL)) == 0 else {
            let code = errno
            try? FileManager.default.removeItem(at: partial)
            throw CocoaError(code == EEXIST ? .fileWriteFileExists : .fileWriteUnknown, userInfo: [NSFilePathErrorKey: target.path])
        }
        progress(context.completed)
        return true
    }

    /// What the status callback needs: where to report, when to stop, and the bytes so far.
    private final class Context {
        let progress: (Int64) -> Void
        let isCancelled: () -> Bool
        var cancelled = false
        /// Bytes of the files finished, and of the one being copied.
        var completed: Int64 = 0
        var current: Int64 = 0

        init(progress: @escaping (Int64) -> Void, isCancelled: @escaping () -> Bool) {
            self.progress = progress
            self.isCancelled = isCancelled
        }

        /// Whether to go on; false once asked to stop.
        func goOn() -> Bool {
            if !cancelled && isCancelled() { cancelled = true }
            return !cancelled
        }
    }

    /// copyfile's status callback: counts bytes as files and their data are copied, and quits
    /// when asked to stop (checked before each file and between chunks of a big one).
    private static let statusCallback: copyfile_callback_t = { what, stage, state, source, _, ctx in
        guard let ctx else { return COPYFILE_CONTINUE }
        let context = Unmanaged<Context>.fromOpaque(ctx).takeUnretainedValue()
        switch (what, stage) {
        case (COPYFILE_RECURSE_FILE, COPYFILE_START), (COPYFILE_RECURSE_DIR, COPYFILE_START):
            if !context.goOn() { return COPYFILE_QUIT }
        case (COPYFILE_RECURSE_FILE, COPYFILE_FINISH):
            var st = stat()
            if let source, lstat(source, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG { context.completed += Int64(st.st_size) }
            context.current = 0
            context.progress(context.completed)
        case (COPYFILE_COPY_DATA, COPYFILE_PROGRESS):
            var copied: off_t = 0
            copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &copied)
            context.current = Int64(copied)
            context.progress(context.completed + context.current)
            if !context.goOn() { return COPYFILE_QUIT }
        default:
            break
        }
        return COPYFILE_CONTINUE
    }

    /// Each item at and under `url` with its size and change time, to tell whether anything
    /// in it changed (or came or went) while it was being copied.
    public static func snapshot(of url: URL) -> [String: [Int64]] {
        func entry(_ u: URL) -> [Int64] {
            var st = stat()
            guard lstat(u.path, &st) == 0 else { return [] }
            return [Int64(st.st_size), Int64(st.st_mtimespec.tv_sec), Int64(st.st_mtimespec.tv_nsec), Int64(st.st_ino)]
        }
        var out = ["": entry(url)]
        guard let walk = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil, options: [],
                                                        errorHandler: { _, _ in true }) else { return out }
        let base = url.standardizedFileURL.path.count + 1
        for case let item as URL in walk {
            out[String(item.standardizedFileURL.path.dropFirst(base))] = entry(item)
        }
        return out
    }
}
