import AppKit
import Foundation
import Testing
import VieEditor
import VieText
import VieVim
import VieWorkspace
@testable import Vie

/// Workspace windows without clicking: tabs, Vim's buffer commands, registers shared across
/// tabs, and saving and restoring the session.
@MainActor
@Suite struct WorkspaceWindowTests {
    private let dir: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("vie-ws-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, text) in [("a.txt", "alpha\n"), ("b.txt", "beta\n"), ("src/main.swift", "let x = 1\n")] {
            let url = dir.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
    }

    private func window(folder: Bool = true) -> WorkspaceWindowController {
        WorkspaceWindowController(folder: folder ? dir : nil, size: NSSize(width: 900, height: 600), vimEnabled: true, vimSession: VimSession())
    }

    private func vim(_ w: WorkspaceWindowController, _ keys: String) {
        w.activeView?.vim?.handle(keys: VimKey.parse(keys))
    }

    private func names(_ w: WorkspaceWindowController) -> [String] { w.tabs.map(\.title) }

    /// The first responder up the chain from `start` that implements `action`: the one AppKit
    /// validates a menu item with and sends its action to.
    private func firstResponder(to action: Selector, from start: NSResponder?) -> NSResponder? {
        var responder = start
        while let r = responder, !r.responds(to: action) { responder = r.nextResponder }
        return responder
    }

    private func descendant<T: NSView>(_ type: T.Type, of view: NSView?) -> T? {
        for sub in view?.subviews ?? [] {
            if let found = sub as? T ?? descendant(type, of: sub) { return found }
        }
        return nil
    }

    /// Lets queued main-thread work (deferred closes) run.
    private func settle() async throws {
        for _ in 0..<5 { try await Task.sleep(for: .milliseconds(20)) }
    }

    @Test func opensFilesInTabsAndReusesThem() throws {
        let w = window()
        defer { w.close() }
        w.open(dir.appendingPathComponent("a.txt"))
        w.open(dir.appendingPathComponent("b.txt"))
        #expect(names(w) == ["a.txt", "b.txt"])
        #expect(w.activeIndex == 1)
        w.open(dir.appendingPathComponent("a.txt"))
        #expect(names(w) == ["a.txt", "b.txt"])
        #expect(w.activeIndex == 0)
        #expect(w.statusBar.editor === w.activeView)
        #expect(w.window?.title == "a.txt")
    }

    @Test func anUntouchedUntitledTabGivesWay() throws {
        let w = window(folder: false)
        defer { w.close() }
        w.newTab(nil)
        #expect(names(w) == ["Untitled"])
        w.open(dir.appendingPathComponent("a.txt"))
        #expect(names(w) == ["a.txt"])
    }

    @Test func bufferCommandsSwitchTabs() async throws {
        let w = window()
        defer { w.close() }
        for f in ["a.txt", "b.txt", "src/main.swift"] { w.open(dir.appendingPathComponent(f)) }
        vim(w, ":b 1<CR>")
        #expect(w.activeIndex == 0)
        vim(w, ":bn<CR>")
        #expect(w.activeIndex == 1)
        vim(w, "gt")
        #expect(w.activeIndex == 2)
        vim(w, "gt")
        #expect(w.activeIndex == 0)
        vim(w, "gT")
        #expect(w.activeIndex == 2)
        vim(w, ":b main<CR>")
        #expect(w.activeTab?.title == "main.swift")
        vim(w, ":b .txt<CR>")
        #expect(w.activeView?.vim?.message == "E93: More than one match for .txt")
        vim(w, ":ls<CR>")
        let list = w.activeView?.vim?.message ?? ""
        #expect(list.contains("3 %a \"src/main.swift\""))
        #expect(list.contains("1 # \"a.txt\""))
        vim(w, ":e notes.md<CR>")
        #expect(w.activeTab?.document.fileURL?.lastPathComponent == "notes.md")
        #expect(w.tabs.count == 4)
        vim(w, ":q<CR>")
        try await settle()
        #expect(w.tabs.count == 3)
    }

    @Test func registersCarryAcrossTabs() throws {
        let w = window()
        defer { w.close() }
        w.open(dir.appendingPathComponent("a.txt"))
        vim(w, "yiw")
        w.open(dir.appendingPathComponent("b.txt"))
        vim(w, "P")
        #expect(w.activeTab?.document.buffer.rope.string(in: 0..<10) == "alphabeta\n")
        #expect(w.window?.isDocumentEdited == true)
    }

    @Test func quitRefusesUnsavedChangesUnlessForced() async throws {
        let w = window()
        defer { w.close() }
        w.open(dir.appendingPathComponent("a.txt"))
        w.open(dir.appendingPathComponent("b.txt"))
        vim(w, "x")
        vim(w, ":q<CR>")
        try await settle()
        #expect(w.tabs.count == 2)
        #expect(w.activeView?.vim?.messageIsError == true)
        vim(w, ":bd!<CR>")
        try await settle()
        #expect(names(w) == ["a.txt"])
    }

    @Test func writeSavesAndReports() async throws {
        let w = window()
        defer { w.close() }
        w.open(dir.appendingPathComponent("a.txt"))
        vim(w, "x:w<CR>")
        for _ in 0..<50 where w.activeView?.vim?.message?.contains("written") != true {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(try String(contentsOf: dir.appendingPathComponent("a.txt"), encoding: .utf8) == "lpha\n")
        #expect(w.activeView?.vim?.message == "\"a.txt\" 2L, 5B written")
        #expect(w.window?.isDocumentEdited == false)
    }

    @Test func sessionStateRoundTrips() throws {
        let w = window()
        w.open(dir.appendingPathComponent("a.txt"))
        w.open(dir.appendingPathComponent("src/main.swift"))
        vim(w, "w")
        w.open(dir.appendingPathComponent("b.txt"))
        w.selectTab(1)
        let state = w.state()
        w.close()
        let data = try JSONEncoder().encode(SessionState(windows: [state]))
        let decoded = try JSONDecoder().decode(SessionState.self, from: data)

        let r = window()
        defer { r.close() }
        r.restore(decoded.windows[0])
        #expect(names(r) == ["a.txt", "main.swift", "b.txt"])
        #expect(r.activeTab?.title == "main.swift")
        #expect(r.activeView?.vim?.cursor == 4)
        #expect(decoded.windows[0].expanded.contains("src"))
    }

    @Test func treeAndIndexCoverTheFolder() async throws {
        let w = window()
        defer { w.close() }
        let tree = try #require(w.tree)
        #expect(tree.children(of: tree.root).map(\.name) == ["src", "a.txt", "b.txt"])
    }

    /// View ▸ Hide Sidebar (⌃⌘S) must reach this controller through the responder chain from
    /// the editor, as a key press does. Named `toggleSidebar:`, it was taken (and disabled) by
    /// the NSSplitView between the two.
    @Test func sidebarMenuItemReachesTheWindow() throws {
        let w = window()
        defer { w.close() }
        w.open(dir.appendingPathComponent("a.txt"))
        let item = try #require(MainMenu.build().items.compactMap(\.submenu).flatMap(\.items).first {
            $0.keyEquivalent == "s" && $0.keyEquivalentModifierMask == [.command, .control]
        })
        let action = try #require(item.action)
        #expect(firstResponder(to: action, from: w.activeView) === w)
        #expect(w.validateMenuItem(item))
        #expect(item.title == "Hide Sidebar")
        #expect(w.activeView?.tryToPerform(action, with: item) == true)
        #expect(w.sidebarWidth == nil)
        #expect(w.validateMenuItem(item))
        #expect(item.title == "Show Sidebar")
        #expect(w.activeView?.tryToPerform(action, with: item) == true)
        #expect(w.sidebarWidth == 240)
    }

    /// Space e in Vim's Normal mode shows and hides the sidebar; a window of loose files says
    /// it has none.
    @Test func spaceETogglesTheSidebar() throws {
        let w = window()
        defer { w.close() }
        w.open(dir.appendingPathComponent("a.txt"))
        vim(w, "<Space>e")
        #expect(w.sidebarWidth == nil)
        vim(w, "<Space>e")
        #expect(w.sidebarWidth == 240)
        let loose = window(folder: false)
        defer { loose.close() }
        loose.open(dir.appendingPathComponent("b.txt"))
        vim(loose, "<Space>e")
        #expect(loose.activeView?.vim?.message == "No folder open")
        #expect(loose.activeView?.vim?.messageIsError == true)
    }

    /// Every menu command this controller handles reaches it from the editor and from the
    /// file tree. A name AppKit also uses (`toggleSidebar:`, `selectNextTab:`) is taken by
    /// NSSplitView or NSWindow on the way, which leaves the menu item dead.
    @Test func menuCommandsReachTheWindow() throws {
        let w = window()
        defer { w.close() }
        w.open(dir.appendingPathComponent("a.txt"))
        let tree = try #require(descendant(NSOutlineView.self, of: w.window?.contentView))
        let actions = MainMenu.build().items.compactMap(\.submenu).flatMap(\.items).compactMap(\.action).filter { w.responds(to: $0) }
        #expect(actions.count >= 10)
        for action in actions {
            #expect(firstResponder(to: action, from: w.activeView) === w, "\(action) from the editor")
            #expect(firstResponder(to: action, from: tree) === w, "\(action) from the tree")
        }
    }

    /// ⌘1–⌘9 reach this controller from the editor and pick that tab; numbers past the last
    /// tab are disabled.
    @Test func numberedTabShortcuts() throws {
        let w = window()
        defer { w.close() }
        for name in ["a.txt", "b.txt", "src/main.swift"] { w.open(dir.appendingPathComponent(name)) }
        let items = MainMenu.build().items.compactMap(\.submenu).flatMap(\.items).filter {
            $0.keyEquivalentModifierMask == .command && Int($0.keyEquivalent) != nil
        }
        #expect(items.map(\.keyEquivalent) == (1...9).map(String.init))
        for item in items {
            let n = try #require(Int(item.keyEquivalent))
            let action = try #require(item.action)
            #expect(item.allowsKeyEquivalentWhenHidden)
            #expect(firstResponder(to: action, from: w.activeView) === w)
            #expect(w.validateMenuItem(item) == (n <= 3))
            if n <= 3 {
                #expect(w.activeView?.tryToPerform(action, with: item) == true)
                #expect(w.activeIndex == n - 1)
            }
        }
    }

    /// Holding ⌘ on its own shows the tab numbers after a moment; letting go hides them, and
    /// a quick shortcut never shows them.
    @Test func holdingCommandShowsTabNumbers() async throws {
        let w = window()
        defer { w.close() }
        w.open(dir.appendingPathComponent("a.txt"))
        w.open(dir.appendingPathComponent("b.txt"))
        w.commandKeyChanged(heldAlone: true)
        #expect(!w.showsTabNumbers)
        try await Task.sleep(for: .milliseconds(450))
        #expect(w.showsTabNumbers)
        w.commandKeyChanged(heldAlone: false)
        #expect(!w.showsTabNumbers)
        w.commandKeyChanged(heldAlone: true)
        w.commandKeyChanged(heldAlone: false)
        try await Task.sleep(for: .milliseconds(450))
        #expect(!w.showsTabNumbers)
    }
}

@MainActor
@Suite struct WorkspaceSnapshotTests {
    /// Draws a folder window with tabs and ⌘P open. Set VIE_SNAPSHOT_DIR to write a PNG.
    @Test func rendersWorkspaceWindow() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vie-snap-\(UUID().uuidString)").resolvingSymlinksInPath()
        for (name, text) in [("Sources/App/main.swift", "import Foundation\n\nprint(\"hello\")\n"), ("Sources/App/Model.swift", "struct Model {}\n"),
                             ("README.md", "# Demo\n"), ("build/out.o", "x"), (".gitignore", "build/\n"), ("Tests/AppTests.swift", "\n")] {
            let url = dir.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        let w = WorkspaceWindowController(folder: dir, size: NSSize(width: 1000, height: 560), vimEnabled: true, vimSession: VimSession())
        defer { w.close() }
        w.open(dir.appendingPathComponent("README.md"))
        w.open(dir.appendingPathComponent("Sources/App/main.swift"))
        w.activeView?.vim?.handle(keys: VimKey.parse("ix<Esc>"))
        for _ in 0..<100 where !w.isIndexReady { try await Task.sleep(for: .milliseconds(20)) }
        #expect(w.isIndexReady)
        w.openQuickly(nil)
        w.quickOpenType("mod")
        let view = try #require(w.window?.contentView)
        view.layoutSubtreeIfNeeded()
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        if let out = ProcessInfo.processInfo.environment["VIE_SNAPSHOT_DIR"], let png = rep.representation(using: .png, properties: [:]) {
            try png.write(to: URL(fileURLWithPath: out).appendingPathComponent("workspace.png"))
        }
    }
}
