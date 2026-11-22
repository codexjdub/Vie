import Foundation
import Testing
import VieText
@testable import VieWorkspace

/// Copies of unsaved text: made a moment after an edit, kept up to date, removed once there's
/// nothing unsaved, and put back after a crash.
@MainActor
@Suite struct RecoveryTests {
    private let dir: URL
    private let folder: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("vie-recovery-\(UUID().uuidString)")
        folder = dir.appendingPathComponent("Recovery")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func recovery() -> Recovery { Recovery(directory: folder, delay: 0.01) }

    private func file(_ name: String, _ text: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func text(_ rope: Rope) -> String { rope.string(in: 0..<rope.byteCount) }

    private func type(_ s: String, into d: Document) {
        let at = d.buffer.rope.byteCount
        d.buffer.replace(at..<at, with: Array(s.utf8), kind: .typing)
    }

    /// Waits (up to a second) for `condition`, letting copies be written meanwhile.
    private func wait(for r: Recovery, until condition: () -> Bool) async throws {
        for _ in 0..<100 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
            await r.flush()
        }
    }

    @Test func copiesUnsavedTextUntilSaved() async throws {
        let url = try file("a.txt", "alpha\n")
        let r = recovery()
        let d = try Document(contentsOf: url)
        defer { d.close() }
        r.track(d)
        try await Task.sleep(for: .milliseconds(50))
        #expect(r.backups().isEmpty) // nothing unsaved, nothing copied

        var changes = 0
        r.onChange = { changes += 1 }
        type("beta\n", into: d)
        try await wait(for: r) { r.backupID(for: d) != nil }
        let backups = r.backups()
        #expect(backups.count == 1)
        #expect(backups.first?.id == r.backupID(for: d))
        #expect(backups.first?.path == url.path)
        #expect(backups.first.map { text($0.text) } == "alpha\nbeta\n")
        #expect(changes == 1)

        // Later edits rewrite the same copy.
        type("gamma\n", into: d)
        try await wait(for: r) { r.backups().first.map { text($0.text) } == "alpha\nbeta\ngamma\n" }
        #expect(r.backups().map { text($0.text) } == ["alpha\nbeta\ngamma\n"])
        #expect(changes == 1)

        try await d.save()
        r.refresh(d)
        try await wait(for: r) { r.backups().isEmpty }
        #expect(r.backups().isEmpty)
        #expect(r.backupID(for: d) == nil)
        #expect(changes == 2)
    }

    @Test func untitledTextHasNoPathAndGoesWhenUndone() async throws {
        let r = recovery()
        let d = Document()
        r.track(d)
        type("draft", into: d)
        try await wait(for: r) { !r.backups().isEmpty }
        #expect(r.backups().map(\.path) == [nil])
        #expect(r.backups().map { text($0.text) } == ["draft"])

        #expect(d.buffer.undo())
        #expect(!d.isDirty)
        try await wait(for: r) { r.backups().isEmpty }
        #expect(r.backups().isEmpty)
    }

    @Test func closingRemovesTheCopy() async throws {
        let r = recovery()
        let d = Document()
        r.track(d)
        type("draft", into: d)
        try await wait(for: r) { !r.backups().isEmpty }
        r.untrack(d)
        await r.flush()
        #expect(r.backups().isEmpty)
        type(" more", into: d)
        try await Task.sleep(for: .milliseconds(50))
        await r.flush()
        #expect(r.backups().isEmpty)
    }

    /// After a crash the copy goes back into the file's buffer as one change: Undo shows
    /// what's on disk, and the copy is kept until there's nothing unsaved.
    @Test func recoveredTextIsOneUndoableChange() async throws {
        let url = try file("a.txt", "alpha\n")
        let before = recovery()
        let d = try Document(contentsOf: url)
        before.track(d)
        type("beta\n", into: d)
        try await wait(for: before) { !before.backups().isEmpty }
        d.close() // the crash: no untrack, so the copy stays

        let r = recovery()
        let backup = try #require(r.backups().first)
        let reopened = try Document(contentsOf: url)
        defer { reopened.close() }
        r.recover(backup, into: reopened)
        #expect(text(reopened.buffer.rope) == "alpha\nbeta\n")
        #expect(reopened.isDirty)
        #expect(r.backupID(for: reopened) == backup.id)
        try await Task.sleep(for: .milliseconds(50))
        await r.flush()
        #expect(r.backups().map(\.id) == [backup.id])

        #expect(reopened.buffer.undo())
        #expect(text(reopened.buffer.rope) == "alpha\n")
        #expect(!reopened.isDirty)
        try await wait(for: r) { r.backups().isEmpty }
        #expect(r.backups().isEmpty)
    }

    /// A copy whose text is what's on disk (saved just before the crash) leaves nothing to do.
    @Test func recoveringTheSavedTextRemovesTheCopy() async throws {
        let url = try file("a.txt", "alpha\n")
        let r = recovery()
        let d = try Document(contentsOf: url)
        defer { d.close() }
        r.recover(Recovery.Backup(id: "old", path: url.path, text: Rope("alpha\n")), into: d)
        #expect(!d.isDirty && !d.buffer.canUndo)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try await wait(for: r) { r.backupID(for: d) == nil }
        #expect(r.backupID(for: d) == nil)
    }

    @Test func removeAllEmptiesTheFolderAndStops() async throws {
        let r = recovery()
        let d = Document()
        r.track(d)
        type("draft", into: d)
        try await wait(for: r) { !r.backups().isEmpty }
        r.removeAll()
        #expect(r.backups().isEmpty)
        type(" more", into: d)
        try await Task.sleep(for: .milliseconds(50))
        await r.flush()
        #expect(r.backups().isEmpty)
    }

    @Test func encodingRoundTripsAndSkipsJunk() throws {
        let data = Recovery.encode(Rope("one\ntwo\n"), path: "/x/a b.txt")
        let backup = try #require(Recovery.decode(data, id: "1"))
        #expect(backup.path == "/x/a b.txt" && text(backup.text) == "one\ntwo\n")
        #expect(Recovery.decode(Recovery.encode(Rope(""), path: nil), id: "2").map { $0.path == nil && $0.text.isEmpty } == true)
        #expect(Recovery.decode(Data("no header".utf8), id: "3") == nil)
        #expect(Recovery.decode(Data("[1]\ntext".utf8), id: "4") == nil)

        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: folder.appendingPathComponent("good"))
        try Data("junk".utf8).write(to: folder.appendingPathComponent("bad"))
        try Data().write(to: folder.appendingPathComponent(".DS_Store"))
        #expect(recovery().backups().map(\.id) == ["good"])
    }
}
