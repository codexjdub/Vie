import Foundation
import Testing
import VieText
@testable import VieWorkspace

@MainActor
@Suite struct DocumentTests {
    private let dir: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("vie-doc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func file(_ name: String, _ contents: Data) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try contents.write(to: url)
        return url
    }

    private func text(_ d: Document) -> String { d.buffer.rope.string(in: 0..<d.buffer.rope.byteCount) }

    private func type(_ s: String, into d: Document, at offset: Int? = nil) {
        let at = offset ?? d.buffer.rope.byteCount
        d.buffer.replace(at..<at, with: Array(s.utf8), kind: .typing)
    }

    @Test func editAndSave() async throws {
        let url = try file("a.txt", Data("hello\n".utf8))
        let d = try Document(contentsOf: url)
        defer { d.close() }
        type("world\n", into: d)
        #expect(d.isDirty)
        try await d.save()
        #expect(!d.isDirty)
        #expect(try Data(contentsOf: url) == Data("hello\nworld\n".utf8))
        #expect(d.checkDisk() == .unchanged) // our own save isn't an outside change
    }

    @Test func keepsEncodingAndLineEndings() async throws {
        let original = try #require("一行目\r\n二行目\r\n".data(using: .shiftJIS))
        let url = try file("sjis.txt", original)
        let d = try Document(contentsOf: url)
        defer { d.close() }
        #expect(d.format == TextFormat(encoding: .shiftJIS, lineEnding: .crlf))
        type("三行目\n", into: d)
        try await d.save()
        #expect(try Data(contentsOf: url) == "一行目\r\n二行目\r\n三行目\r\n".data(using: .shiftJIS))
    }

    @Test func unrepresentableTextFailsWithoutWriting() async throws {
        let original = try #require("日本語\n".data(using: .shiftJIS))
        let url = try file("sjis2.txt", original)
        let d = try Document(contentsOf: url)
        defer { d.close() }
        type("🚀", into: d)
        await #expect(throws: TextFileError.unrepresentable(.shiftJIS)) { try await d.save() }
        #expect(try Data(contentsOf: url) == original)
        #expect(d.isDirty)
        try await d.save(format: TextFormat(encoding: .utf8, lineEnding: .lf))
        #expect(try Data(contentsOf: url) == Data("日本語\n🚀".utf8))
    }

    @Test func savingKeepsPermissions() async throws {
        let url = try file("script.sh", Data("#!/bin/sh\n".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        let d = try Document(contentsOf: url)
        defer { d.close() }
        type("echo hi\n", into: d)
        try await d.save()
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(mode == 0o755)
    }

    @Test func savingThroughASymlinkKeepsTheLink() async throws {
        let target = try file("real.txt", Data("real\n".utf8))
        let link = dir.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let d = try Document(contentsOf: link)
        defer { d.close() }
        type("more\n", into: d)
        try await d.save()
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == target.path)
        #expect(try Data(contentsOf: target) == Data("real\nmore\n".utf8))
    }

    @Test func newPathIsCreatedOnSave() async throws {
        let url = dir.appendingPathComponent("new.txt")
        let d = try Document(contentsOf: url)
        defer { d.close() }
        #expect(d.buffer.rope.isEmpty && d.displayName == "new.txt")
        #expect(d.checkDisk() == .unchanged)
        type("fresh", into: d)
        try await d.save()
        #expect(try Data(contentsOf: url) == Data("fresh".utf8))
    }

    @Test func saveAsMovesTheDocument() async throws {
        let d = Document()
        defer { d.close() }
        type("untitled text", into: d)
        let url = dir.appendingPathComponent("saved-as.txt")
        try await d.save(to: url)
        #expect(d.fileURL == url.standardizedFileURL && !d.isDirty)
        #expect(try Data(contentsOf: url) == Data("untitled text".utf8))
    }

    @Test func outsideChangesAreDetectedAndReloadIsUndoable() async throws {
        let url = try file("shared.txt", Data("line one\nline two\n".utf8))
        let d = try Document(contentsOf: url)
        defer { d.close() }
        type("my edit\n", into: d)
        try Data("line one\nchanged elsewhere\n".utf8).write(to: url)
        #expect(d.checkDisk() == .changed)
        #expect(d.checkDisk() == .unchanged) // reported once
        try d.reload()
        #expect(text(d) == "line one\nchanged elsewhere\n")
        #expect(!d.isDirty)
        d.buffer.undo()
        #expect(text(d) == "line one\nline two\nmy edit\n")
    }

    @Test func deletedFileIsReported() throws {
        let url = try file("gone.txt", Data("x".utf8))
        let d = try Document(contentsOf: url)
        defer { d.close() }
        try FileManager.default.removeItem(at: url)
        #expect(d.checkDisk() == .missing)
    }

    @Test func watcherFiresOnAtomicReplace() async throws {
        let url = try file("watched.txt", Data("v1".utf8))
        let d = try Document(contentsOf: url)
        defer { d.close() }
        var fired = 0
        d.onDiskChange = { fired += 1 }
        try Data("v2".utf8).write(to: url, options: .atomic) // replaces the file, as most editors do
        for _ in 0..<40 where fired == 0 { try await Task.sleep(for: .milliseconds(25)) }
        #expect(fired >= 1)
        #expect(d.checkDisk() == .changed)
        // Still watching the new file after the replace.
        fired = 0
        try Data("v3".utf8).write(to: url, options: .atomic)
        for _ in 0..<40 where fired == 0 { try await Task.sleep(for: .milliseconds(25)) }
        #expect(fired >= 1)
    }
}
