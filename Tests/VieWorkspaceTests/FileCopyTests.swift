import Foundation
import Testing
@testable import VieWorkspace

/// Copying as Finder does, with progress and stopping, never leaving a partial copy behind.
@Suite final class FileCopyTests {
    private let dir: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("vie-copy-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("src/sub"), withIntermediateDirectories: true)
        try Data(repeating: 7, count: 300_000).write(to: dir.appendingPathComponent("src/big.bin"))
        try Data("a\n".utf8).write(to: dir.appendingPathComponent("src/sub/a.txt"))
        try FileManager.default.createSymbolicLink(atPath: dir.appendingPathComponent("src/link.txt").path, withDestinationPath: "sub/a.txt")
    }

    deinit { try? FileManager.default.removeItem(at: dir) }

    private func partials() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasPrefix(FileCopy.partialPrefix) }
    }

    /// A folder is copied whole, its link as a link; the progress ends at the size of its
    /// regular files, which is what `size(of:)` counts.
    @Test func copiesFoldersWithProgress() throws {
        let src = dir.appendingPathComponent("src"), copy = dir.appendingPathComponent("copy")
        #expect(FileCopy.size(of: [src]) == 300_002)
        var last: Int64 = 0
        #expect(try FileCopy.copy(src, to: copy, progress: { last = $0 }, isCancelled: { false }))
        #expect(last == 300_002 && partials().isEmpty)
        #expect((try? Data(contentsOf: copy.appendingPathComponent("sub/a.txt"))) == Data("a\n".utf8))
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: copy.appendingPathComponent("link.txt").path)) == "sub/a.txt")
    }

    /// Stopping part way gives false and leaves nothing: no copy, no partial one.
    @Test func stopsAndLeavesNothing() throws {
        let copy = dir.appendingPathComponent("copy")
        var reported = false
        #expect(try !FileCopy.copy(dir.appendingPathComponent("src"), to: copy, progress: { _ in reported = true },
                                   isCancelled: { reported }))
        #expect(!FileManager.default.fileExists(atPath: copy.path) && partials().isEmpty)
    }

    /// A name that's taken is refused, and what's there is left as it was (not copied into).
    @Test func refusesATakenName() throws {
        let taken = dir.appendingPathComponent("taken")
        try FileManager.default.createDirectory(at: taken, withIntermediateDirectories: true)
        #expect(throws: CocoaError.self) {
            try FileCopy.copy(self.dir.appendingPathComponent("src"), to: taken, progress: { _ in }, isCancelled: { false })
        }
        #expect((try? FileManager.default.contentsOfDirectory(atPath: taken.path)) == [] && partials().isEmpty)
    }

    /// Partial copies aren't listed; a snapshot sees a file changed or added inside a folder.
    @Test func hidesPartialsAndSeesChanges() throws {
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(FileCopy.partialPrefix + "x"), withIntermediateDirectories: true)
        #expect(Directory.list(dir).map(\.name).sorted() == ["src"])
        let src = dir.appendingPathComponent("src")
        let before = FileCopy.snapshot(of: src)
        #expect(FileCopy.snapshot(of: src) == before)
        try Data("changed\n".utf8).write(to: src.appendingPathComponent("sub/a.txt"))
        #expect(FileCopy.snapshot(of: src) != before)
        let again = FileCopy.snapshot(of: src)
        try Data().write(to: src.appendingPathComponent("new.txt"))
        #expect(FileCopy.snapshot(of: src) != again)
    }
}
