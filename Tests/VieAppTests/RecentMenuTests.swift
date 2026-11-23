import AppKit
import Foundation
import Testing
@testable import Vie

/// File ▸ Open Recent, built from a list given in place of the system's.
@MainActor
@Suite struct RecentMenuTests {
    private let dir: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("vie-recent-\(UUID().uuidString)").resolvingSymlinksInPath()
        for name in ["a.txt", "app/src/main.swift", "lib/src/main.swift", "tools/main.swift", "notes/"] {
            let url = dir.appendingPathComponent(name)
            if name.hasSuffix("/") {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            } else {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data().write(to: url)
            }
        }
    }

    private func url(_ name: String) -> URL { dir.appendingPathComponent(name) }

    /// The menu as it looks when opened.
    private func build(_ urls: [URL], open: @escaping (URL) -> Void = { _ in }, clear: @escaping () -> Void = {}) -> RecentMenu {
        let recent = RecentMenu(urls: { urls }, open: open, clear: clear)
        recent.menuNeedsUpdate(recent.menu)
        return recent
    }

    /// What clicking the item does (without NSApp, which only some test runs have made).
    private func choose(_ item: NSMenuItem) {
        guard let target = item.target, let action = item.action else { return }
        _ = target.perform(action, with: item)
    }

    private func titles(_ recent: RecentMenu) -> [String] {
        recent.menu.items.map { $0.isSeparatorItem ? "—" : $0.title }
    }

    @Test func listsFilesAndFoldersThenClearMenu() throws {
        let recent = build([url("notes"), url("a.txt")])
        #expect(titles(recent) == ["notes", "a.txt", "—", "Clear Menu"])
        let first = recent.menu.items[0]
        #expect(first.representedObject as? URL == url("notes"))
        #expect(first.toolTip == (url("notes").path as NSString).abbreviatingWithTildeInPath)
        #expect(first.image?.size == NSSize(width: 16, height: 16) && first.preferredImageVisibility == .visible)
        #expect(recent.menu.items.last?.isEnabled == true)
    }

    /// Repeated names get as much of their folder as tells them apart.
    @Test func repeatedNamesShowTheirFolder() {
        #expect(RecentMenu.titles(for: [url("tools/main.swift"), url("a.txt"), url("app/src/main.swift")])
            == ["main.swift — tools", "a.txt", "main.swift — src"])
        #expect(RecentMenu.titles(for: [url("app/src/main.swift"), url("lib/src/main.swift"), url("tools/main.swift")])
            == ["main.swift — app/src", "main.swift — lib/src", "main.swift — tools"])
        #expect(RecentMenu.titles(for: [URL(fileURLWithPath: "/main.swift"), url("tools/main.swift")])
            == ["main.swift", "main.swift — tools"])
    }

    @Test func leavesOutWhatIsGone() {
        let recent = build([url("gone.txt"), url("a.txt"), URL(string: "https://example.com/x")!])
        #expect(titles(recent) == ["a.txt", "—", "Clear Menu"])
    }

    @Test func emptyListOffersADisabledClearMenu() {
        let recent = build([url("gone.txt")])
        #expect(titles(recent) == ["Clear Menu"])
        #expect(recent.menu.items.first?.isEnabled == false)
    }

    @Test func choosingOpensAndClearMenuClears() throws {
        var opened: [URL] = []
        var cleared = 0
        let recent = build([url("a.txt"), url("notes")], open: { opened.append($0) }, clear: { cleared += 1 })
        choose(recent.menu.items[1])
        #expect(opened == [url("notes")])
        choose(recent.menu.items[3])
        #expect(cleared == 1)
    }

    /// Opening the menu again shows the list as it is then.
    @Test func rebuildsEachTime() {
        var urls = [url("a.txt")]
        let recent = RecentMenu(urls: { urls }, open: { _ in }, clear: {})
        recent.menuNeedsUpdate(recent.menu)
        urls.insert(url("notes"), at: 0)
        recent.menuNeedsUpdate(recent.menu)
        #expect(titles(recent) == ["notes", "a.txt", "—", "Clear Menu"])
    }
}
