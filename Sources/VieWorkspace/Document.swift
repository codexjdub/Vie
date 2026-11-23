import Foundation
import VieText

public enum DocumentError: Error, Equatable, LocalizedError {
    /// A save was asked for while the last one is still being written.
    case saveInProgress

    public var errorDescription: String? {
        switch self {
        case .saveInProgress: "The document is still being saved. Try again in a moment."
        }
    }
}

/// A buffer and the file it came from: reading, saving, and noticing changes on disk.
/// M3's workspace will hold many of these per window.
@MainActor
public final class Document {
    public let buffer: Buffer
    public private(set) var fileURL: URL?
    public private(set) var format: TextFormat
    public private(set) var hadMixedLineEndings = false
    public private(set) var indentation: Indentation
    public private(set) var isSaving = false
    /// Called when the file may have changed on disk (also after our own saves; `checkDisk`
    /// tells which).
    public var onDiskChange: (() -> Void)?

    private var fingerprint: FileFingerprint?
    /// The file on disk as last read or saved (or seen changed); nil if there was none.
    public var diskFingerprint: FileFingerprint? { fingerprint }
    private var watcher: FileWatcher?

    public var displayName: String { fileURL?.lastPathComponent ?? "Untitled" }
    public var isDirty: Bool { buffer.isDirty }

    /// An empty, untitled document.
    public init() {
        buffer = Buffer()
        format = .utf8
        indentation = .spaces(4)
    }

    /// Opens a file. A path that doesn't exist yet gives an empty document that saves there.
    public init(contentsOf url: URL) throws {
        let url = url.standardizedFileURL
        if FileManager.default.fileExists(atPath: url.path) {
            let decoded = try TextFile.read(contentsOf: url)
            buffer = Buffer(rope: decoded.rope)
            format = decoded.format
            hadMixedLineEndings = decoded.hadMixedLineEndings
            indentation = Indentation.detect(in: decoded.rope) ?? .spaces(4)
            fingerprint = FileFingerprint(url: url)
        } else {
            buffer = Buffer()
            format = .utf8
            indentation = .spaces(4)
        }
        fileURL = url
        startWatching()
    }

    public func close() {
        watcher?.stop()
        watcher = nil
    }

    // MARK: - Saving

    /// Writes the text to `url` (default: the document's file) in `format` (default: the
    /// format it was read in). Encoding and writing happen off the main thread on a snapshot,
    /// so typing continues during a long save; edits made meanwhile leave the document dirty.
    /// Throws `DocumentError.saveInProgress` while an earlier save is still being written.
    public func save(to url: URL? = nil, format newFormat: TextFormat? = nil) async throws {
        guard !isSaving else { throw DocumentError.saveInProgress }
        guard let target = (url ?? fileURL)?.standardizedFileURL else { return }
        let format = newFormat ?? self.format
        let snapshot = buffer.rope
        let state = buffer.beginSave()
        isSaving = true
        defer { isSaving = false }
        try await Task.detached(priority: .userInitiated) {
            try FileWriter.write(TextFile.encode(snapshot, as: format), to: target)
        }.value
        buffer.markSaved(at: state)
        self.format = format
        hadMixedLineEndings = false
        if target != fileURL {
            fileURL = target
            startWatching()
        }
        fingerprint = FileFingerprint(url: target)
    }

    /// Writes the text to `url` without making it the document's file (Vim's `:w other.txt`).
    public func writeCopy(to url: URL) async throws {
        let snapshot = buffer.rope, format = self.format
        try await Task.detached(priority: .userInitiated) {
            try FileWriter.write(TextFile.encode(snapshot, as: format), to: url.standardizedFileURL)
        }.value
    }

    /// Follows the file to `url` after it was renamed or moved (from the sidebar): later saves
    /// go there. The text, unsaved changes included, stays as it is.
    public func moved(to url: URL) {
        let url = url.standardizedFileURL
        guard url != fileURL else { return }
        fileURL = url
        fingerprint = FileFingerprint(url: url)
        startWatching()
    }

    // MARK: - Changes on disk

    public enum DiskState { case unchanged, changed, missing }

    /// Compares the file on disk with what was last read or saved, and records the new state,
    /// so each outside change is reported once.
    public func checkDisk() -> DiskState {
        guard let url = fileURL, !isSaving else { return .unchanged }
        watcher?.reopenIfNeeded()
        let now = FileFingerprint(url: url)
        guard now != fingerprint else { return .unchanged }
        fingerprint = now
        return now == nil ? .missing : .changed
    }

    /// Re-reads the file. The new text replaces the old as one undoable change, so unsaved
    /// edits lost by reloading can be brought back with Undo.
    public func reload() throws {
        guard let url = fileURL else { return }
        let decoded = try TextFile.read(contentsOf: url)
        buffer.replaceAll(with: decoded.rope)
        buffer.markSaved()
        format = decoded.format
        hadMixedLineEndings = decoded.hadMixedLineEndings
        fingerprint = FileFingerprint(url: url)
    }

    private func startWatching() {
        watcher?.stop()
        guard let url = fileURL else { return }
        watcher = FileWatcher(url: url) { [weak self] in self?.onDiskChange?() }
    }
}
