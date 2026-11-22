import Foundation
import VieText

/// Copies of unsaved text, so a crash, a force quit or a power cut loses at most the last
/// second or so of typing.
///
/// While a document has unsaved changes, its text is copied to a file in `directory` a moment
/// after an edit (a second, plus a second per 10 MB), and again after later edits, at most that
/// often. The copy goes once the document has no unsaved changes (saved, undone to what's on
/// disk, reloaded) or stops being tracked (its tab closed). After a normal quit the app empties
/// the folder (`removeAll`), so whatever is there at launch is what a crash left.
///
/// Each copy is one line of JSON saying which file the text belongs to (none for an untitled
/// buffer), then the text as the buffer holds it: UTF-8 with `\n` line endings.
@MainActor
public final class Recovery {
    public struct Backup: Sendable {
        /// The copy's file name, which the session uses to find it again.
        public let id: String
        /// The file the text belongs to; nil for an untitled buffer.
        public let path: String?
        public let text: Rope

        public init(id: String, path: String?, text: Rope) {
            self.id = id
            self.path = path
            self.text = text
        }
    }

    public let directory: URL
    /// A copy was made or removed: the session, which refers to copies, is worth saving.
    public var onChange: (() -> Void)?

    private let delay: Double
    private let queue = DispatchQueue(label: "io.github.codexjdub.vie.recovery")
    private var entries: [ObjectIdentifier: Entry] = [:]
    private var stopped = false

    private final class Entry {
        var id: String
        weak var document: Document?
        /// The buffer version the copy on disk holds; nil when there's no copy.
        var written: Int?
        /// Bumped when a copy is removed, so a write that finishes after it doesn't count.
        var generation = 0
        var writing = false
        var pending: DispatchWorkItem?

        init(id: String, document: Document) {
            self.id = id
            self.document = document
        }
    }

    private struct Header: Codable {
        var path: String?
    }

    /// `delay` is the wait after an edit for small files (tests shorten it).
    public init(directory: URL, delay: Double = 1) {
        self.directory = directory
        self.delay = delay
    }

    // MARK: - Tracking documents

    /// Starts keeping a copy of `document` whenever it has unsaved changes.
    public func track(_ document: Document) {
        let key = ObjectIdentifier(document)
        guard entries[key] == nil else { return }
        let entry = Entry(id: UUID().uuidString, document: document)
        entries[key] = entry
        document.buffer.addObserver(self) { [weak self] _ in
            guard let self, let entry = self.entries[key] else { return }
            self.schedule(entry)
        }
        if document.isDirty { schedule(entry) }
    }

    /// Stops keeping a copy, and removes the one there is: the document was closed, so its
    /// unsaved changes, if any, were thrown away.
    public func untrack(_ document: Document) {
        guard let entry = entries.removeValue(forKey: ObjectIdentifier(document)) else { return }
        document.buffer.removeObserver(self)
        entry.pending?.cancel()
        if entry.written != nil || entry.writing { removeFile(entry.id) }
    }

    /// Checks the document again soon: after a save, which leaves the text as it was, so no
    /// edit says so.
    public func refresh(_ document: Document) {
        guard let entry = entries[ObjectIdentifier(document)] else { return }
        schedule(entry, after: 0)
    }

    /// The name of the document's copy, if it has one.
    public func backupID(for document: Document) -> String? {
        guard let entry = entries[ObjectIdentifier(document)], entry.written != nil else { return nil }
        return entry.id
    }

    /// Puts a copy's text into `document`, replacing the text as one change (so Undo goes
    /// back to the file on disk), and keeps the copy as the document's.
    public func recover(_ backup: Backup, into document: Document) {
        track(document)
        guard let entry = entries[ObjectIdentifier(document)] else { return }
        document.buffer.replaceAll(with: backup.text)
        if entry.written != nil && entry.id != backup.id { removeFile(entry.id) }
        entry.id = backup.id
        entry.written = document.buffer.version
        entry.generation += 1
        // The same text as on disk leaves the document clean, and the copy is removed.
        schedule(entry, after: 0)
    }

    // MARK: - The folder

    /// Every copy in the folder (at launch, before anything is tracked).
    public func backups() -> [Backup] {
        let directory = directory
        return queue.sync {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            return names.sorted().compactMap { name in
                guard !name.hasPrefix("."), let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else { return nil }
                return Self.decode(data, id: name)
            }
        }
    }

    /// Removes every copy and makes no more (a normal quit: unsaved changes were saved or
    /// thrown away).
    public func removeAll() {
        stopped = true
        for entry in entries.values {
            entry.pending?.cancel()
            entry.pending = nil
        }
        let directory = directory
        queue.sync {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            for name in names { try? FileManager.default.removeItem(at: directory.appendingPathComponent(name)) }
        }
    }

    /// Waits for copies being written or removed (for tests).
    public func flush() async {
        let queue = queue
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in queue.async { c.resume() } }
        await Task.yield()
    }

    // MARK: - Writing

    private func schedule(_ entry: Entry, after seconds: Double? = nil) {
        guard !stopped, let document = entry.document else { return }
        if let pending = entry.pending {
            // A write is already waiting; only a check sooner than it replaces it.
            guard seconds != nil else { return }
            pending.cancel()
        }
        let wait = seconds ?? delay * (1 + Double(document.buffer.rope.byteCount) / 10_000_000)
        let key = ObjectIdentifier(document)
        let work = DispatchWorkItem { [weak self] in
            guard let self, let entry = self.entries[key] else { return }
            entry.pending = nil
            self.update(entry)
        }
        entry.pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: work)
    }

    /// Writes the copy if the text changed since the last one, or removes it if there are no
    /// unsaved changes.
    private func update(_ entry: Entry) {
        guard !stopped, let document = entry.document, entries[ObjectIdentifier(document)] === entry else { return }
        guard document.isDirty else {
            if entry.written != nil || entry.writing {
                entry.written = nil
                entry.generation += 1
                removeFile(entry.id)
                onChange?()
            }
            return
        }
        let version = document.buffer.version
        // A write in progress checks again when it's done.
        guard version != entry.written, !entry.writing else { return }
        entry.writing = true
        let generation = entry.generation, isNew = entry.written == nil
        // A snapshot: encoding a big file takes a while, so it happens off the main thread.
        let rope = document.buffer.rope, path = document.fileURL?.path
        let url = directory.appendingPathComponent(entry.id)
        let directory = directory
        queue.async { [weak self] in
            var ok = true
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try Self.encode(rope, path: path).write(to: url, options: .atomic)
            } catch {
                ok = false
                NSLog("Vie: couldn't keep a copy of unsaved changes: \(error.localizedDescription)")
            }
            Task { @MainActor in self?.wrote(entry: url.lastPathComponent, ok: ok, version: version, generation: generation, isNew: isNew) }
        }
    }

    private func wrote(entry id: String, ok: Bool, version: Int, generation: Int, isNew: Bool) {
        guard let entry = entries.values.first(where: { $0.id == id }) else { return }
        entry.writing = false
        if ok && entry.generation == generation {
            entry.written = version
            if isNew { onChange?() }
        }
        // Edits made meanwhile, or a save, get their turn.
        if let document = entry.document, document.buffer.version != entry.written || !document.isDirty { schedule(entry) }
    }

    private func removeFile(_ id: String) {
        let url = directory.appendingPathComponent(id)
        queue.async { try? FileManager.default.removeItem(at: url) }
    }

    // MARK: - Format

    nonisolated static func encode(_ text: Rope, path: String?) -> Data {
        var data = (try? JSONEncoder().encode(Header(path: path))) ?? Data("{}".utf8)
        data.append(0x0A)
        data.reserveCapacity(data.count + text.byteCount)
        text.forEachChunk { data.append($0) }
        return data
    }

    nonisolated static func decode(_ data: Data, id: String) -> Backup? {
        guard let newline = data.firstIndex(of: 0x0A),
              let header = try? JSONDecoder().decode(Header.self, from: data[data.startIndex..<newline]) else { return nil }
        let body = data[(newline + 1)...]
        return Backup(id: id, path: header.path, text: Rope(bytes: Data(body)))
    }
}
