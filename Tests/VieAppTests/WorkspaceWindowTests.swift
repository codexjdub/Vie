import AppKit
import Carbon.HIToolbox
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

    /// The file selected in the window's tree.
    private func selectedInTree(_ w: WorkspaceWindowController) -> URL? {
        guard let outline = descendant(NSOutlineView.self, of: w.window?.contentView), outline.selectedRow >= 0 else { return nil }
        return (outline.item(atRow: outline.selectedRow) as? FileNode)?.url
    }

    /// A key press sent to `view` (the tree reads the key code for Return and Esc).
    private func press(_ view: NSView, _ chars: String, _ keyCode: Int = kVK_ANSI_A, _ flags: NSEvent.ModifierFlags = []) throws {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                                  timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: view.window?.windowNumber ?? 0, context: nil, characters: chars,
                                                  charactersIgnoringModifiers: chars, isARepeat: false, keyCode: UInt16(keyCode)))
        view.keyDown(with: event)
    }

    /// A file in a folder of its own, outside `dir` and any git repository.
    private func fileElsewhere() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("vie-other-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("note.md")
        try Data("# Note\n".utf8).write(to: url)
        return url
    }

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

    /// A language picked by hand stays through saves and a restart; the others go by name.
    @Test func chosenLanguageIsKept() async throws {
        let w = window()
        w.open(dir.appendingPathComponent("a.txt"))
        w.open(dir.appendingPathComponent("src/main.swift"))
        w.open(dir.appendingPathComponent("b.txt"))
        #expect(w.activeView?.syntaxLanguage == nil)
        vim(w, ":set ft=python<CR>x:w<CR>")
        for _ in 0..<50 where w.activeView?.vim?.message?.contains("written") != true {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(w.activeView?.vim?.message?.contains("written") == true)
        #expect(w.activeView?.syntaxLanguage?.name == "python")
        w.selectTab(1)
        vim(w, ":set ft=<CR>")
        #expect(w.activeView?.syntaxLanguage == nil)
        let state = w.state()
        w.close()
        #expect(state.tabs.map(\.language) == [nil, "", "python"])
        let data = try JSONEncoder().encode(SessionState(windows: [state]))
        let decoded = try JSONDecoder().decode(SessionState.self, from: data)

        let r = window()
        defer { r.close() }
        r.restore(decoded.windows[0])
        // Tabs not shown yet keep their language for the next save of the session.
        #expect(r.state().tabs.map(\.language) == [nil, "", "python"])
        #expect(r.activeView?.syntaxLanguage == nil && r.activeView?.languageIsChosen == true)
        r.selectTab(0)
        #expect(r.activeView?.syntaxLanguage == nil && r.activeView?.languageIsChosen == false)
        r.selectTab(2)
        #expect(r.activeView?.syntaxLanguage?.name == "python")
        #expect(r.state().tabs.map(\.language) == [nil, "", "python"])
    }

    /// Sessions saved before languages were kept still load.
    @Test func sessionTabWithoutLanguageDecodes() throws {
        let json = #"{"path": "/x/a.txt", "cursor": 3, "topLine": 0}"#
        let tab = try JSONDecoder().decode(SessionState.Tab.self, from: Data(json.utf8))
        #expect(tab.cursor == 3 && tab.language == nil)
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

    /// The status bar's Vim switch shows whether Vim mode is on.
    @Test func statusBarVimSwitchFollowsVimMode() {
        let w = window()
        defer { w.close() }
        #expect(w.statusBar.vimSwitch == true)
        w.vimEnabled = false
        #expect(w.statusBar.vimSwitch == false)
        w.vimEnabled = true
        #expect(w.statusBar.vimSwitch == true)
    }

    /// Space e in Vim's Normal mode shows and hides the sidebar.
    @Test func spaceETogglesTheSidebar() throws {
        let w = window()
        defer { w.close() }
        w.open(dir.appendingPathComponent("a.txt"))
        vim(w, "<Space>e")
        #expect(w.sidebarWidth == nil)
        vim(w, "<Space>e")
        #expect(w.sidebarWidth == 240)
    }

    /// LazyVim's explorer keys. Space e shows the tree with the keyboard in it, on the current
    /// file; j and k move, l opens a folder and then moves into it, h closes it, and Return
    /// opens a file, back in the editor. ⌃H goes into the tree, ⌃L and Esc back out, and
    /// Space e from the tree hides it and goes back to the editor.
    @Test func treeKeysInVimMode() throws {
        let w = window()
        defer { w.close() }
        w.open(dir.appendingPathComponent("a.txt"))
        let tree = try #require(descendant(NSOutlineView.self, of: w.window?.contentView))
        w.setSidebar(width: nil)
        vim(w, "<Space>e")
        #expect(w.sidebarWidth == 240 && w.window?.firstResponder === tree)
        #expect(selectedInTree(w)?.lastPathComponent == "a.txt")
        try press(tree, "k")
        #expect(selectedInTree(w)?.lastPathComponent == "src")
        try press(tree, "l")
        try press(tree, "l")
        #expect(selectedInTree(w)?.lastPathComponent == "main.swift")
        try press(tree, "h")
        #expect(selectedInTree(w)?.lastPathComponent == "src" && tree.numberOfRows == 3)
        try press(tree, "j")
        try press(tree, "j")
        try press(tree, "\r", kVK_Return)
        #expect(w.activeTab?.title == "b.txt" && w.window?.firstResponder === w.activeView)

        vim(w, "<C-h>")
        #expect(w.window?.firstResponder === tree)
        try press(tree, "l", kVK_ANSI_L, .control)
        #expect(w.window?.firstResponder === w.activeView)
        vim(w, "<C-h>")
        try press(tree, "\u{1B}", kVK_Escape)
        #expect(w.window?.firstResponder === w.activeView)
        vim(w, "<C-h>")
        try press(tree, " ")
        try press(tree, "e")
        #expect(w.sidebarWidth == nil && w.window?.firstResponder === w.activeView)
        vim(w, "<C-h>") // nothing to go to while it's hidden
        #expect(w.window?.firstResponder === w.activeView)

        // View ▸ Show Sidebar leaves the keyboard where it is; hiding it from the tree goes
        // back to the editor.
        w.toggleFileTree(nil)
        #expect(w.sidebarWidth == 240 && w.window?.firstResponder === w.activeView)
        vim(w, "<C-h>")
        w.toggleFileTree(nil)
        #expect(w.sidebarWidth == nil && w.window?.firstResponder === w.activeView)
    }

    /// With Vim mode off the tree still opens with Return and gives the keyboard back with
    /// Esc; letters are the outline's (typing a name), not Vim keys.
    @Test func treeKeysWithVimModeOff() throws {
        let w = window()
        defer { w.close() }
        w.vimEnabled = false
        w.open(dir.appendingPathComponent("a.txt"))
        let tree = try #require(descendant(NSOutlineView.self, of: w.window?.contentView))
        w.window?.makeFirstResponder(tree)
        try press(tree, "k")
        #expect(selectedInTree(w)?.lastPathComponent == "a.txt")
        try press(tree, "\u{1B}", kVK_Escape)
        #expect(w.window?.firstResponder === w.activeView)
        w.window?.makeFirstResponder(tree)
        tree.selectRowIndexes([2], byExtendingSelection: false)
        try press(tree, "\r", kVK_Return)
        #expect(w.activeTab?.title == "b.txt" && w.window?.firstResponder === w.activeView)
    }

    /// Space e in a window of loose files shows the current file's project in the sidebar: the
    /// git repository holding it (not just the file's folder). The window keeps no folder of
    /// its own, and an untitled file has no project.
    @Test func spaceEInALooseWindowShowsTheProject() throws {
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let loose = window(folder: false)
        defer { loose.close() }
        loose.newTab(nil) // untitled
        vim(loose, "<Space>e")
        #expect(loose.activeView?.vim?.message == "No folder open: File ▸ Open… (⌘O) opens one")
        #expect(loose.activeView?.vim?.messageIsError == true)
        #expect(loose.sidebarWidth == nil)
        loose.open(dir.appendingPathComponent("b.txt"))
        loose.open(dir.appendingPathComponent("src/main.swift"))
        vim(loose, "<Space>e")
        #expect(loose.folder == nil && loose.tree?.root.url.path == dir.path && loose.sidebarWidth == 240)
        #expect(names(loose) == ["b.txt", "main.swift"])
        #expect(loose.window?.subtitle == dir.lastPathComponent)
        #expect(selectedInTree(loose)?.path == dir.appendingPathComponent("src/main.swift").path)
        vim(loose, "<Space>e")
        #expect(loose.sidebarWidth == nil && loose.window?.subtitle == "")
    }

    /// In a window of loose files the tree follows the current tab to its project, and a
    /// project shown before comes back with its folders as they were. While the sidebar is
    /// hidden the tree stays put, and it catches up when shown.
    @Test func looseWindowTreeFollowsTheTab() throws {
        let note = try fileElsewhere()
        let loose = window(folder: false)
        defer { loose.close() }
        loose.open(dir.appendingPathComponent("a.txt"))
        loose.open(note)
        loose.selectTab(0)
        vim(loose, "<Space>e")
        #expect(loose.tree?.root.url.path == dir.path)
        let tree = try #require(loose.tree)
        let src = try #require(tree.children(of: tree.root).first { $0.name == "src" })
        try #require(descendant(NSOutlineView.self, of: loose.window?.contentView)).expandItem(src)

        loose.selectTab(1)
        #expect(loose.tree?.root.url.path == note.deletingLastPathComponent().path && loose.sidebarWidth == 240)
        #expect(selectedInTree(loose)?.path == note.path)
        #expect(loose.window?.subtitle == note.deletingLastPathComponent().lastPathComponent)
        loose.selectTab(0)
        #expect(loose.tree?.root.url.path == dir.path)
        let again = try #require(loose.tree?.root.children?.first { $0.name == "src" })
        #expect(try #require(descendant(NSOutlineView.self, of: loose.window?.contentView)).isItemExpanded(again))

        vim(loose, "<Space>e")
        loose.selectTab(1)
        #expect(loose.tree?.root.url.path == dir.path && loose.sidebarWidth == nil)
        vim(loose, "<Space>e")
        #expect(loose.tree?.root.url.path == note.deletingLastPathComponent().path && loose.sidebarWidth == 240)
    }

    /// The tree selects the current file, and nothing when it isn't in the tree (rather than
    /// leaving another file selected).
    @Test func treeSelectsTheCurrentFileOrNothing() throws {
        let w = window()
        defer { w.close() }
        w.open(dir.appendingPathComponent("a.txt"))
        #expect(selectedInTree(w)?.path == dir.appendingPathComponent("a.txt").path)
        w.open(try fileElsewhere())
        #expect(selectedInTree(w) == nil)
        w.selectTab(0)
        w.newTab(nil)
        #expect(selectedInTree(w) == nil)
    }

    /// A window of loose files saves no folder; if its tree was showing, the restored window
    /// shows the current file's project again.
    @Test func looseWindowSessionKeepsTheTreeShowing() throws {
        let loose = window(folder: false)
        loose.open(dir.appendingPathComponent("a.txt"))
        vim(loose, "<Space>e")
        let state = loose.state()
        loose.close()
        #expect(state.folder == nil && state.sidebarWidth == 240)
        let r = window(folder: false)
        defer { r.close() }
        r.restore(state)
        #expect(r.folder == nil && r.tree?.root.url.path == dir.path && r.sidebarWidth == 240)
        #expect(selectedInTree(r)?.path == dir.appendingPathComponent("a.txt").path)
    }

    /// View ▸ Show Sidebar (⌃⌘S) in a window of loose files does the same as Space e. It's
    /// disabled while the file is untitled, which has no project.
    @Test func sidebarMenuItemInALooseWindowShowsTheProject() throws {
        let loose = window(folder: false)
        defer { loose.close() }
        loose.newTab(nil) // untitled
        let item = try #require(MainMenu.build().items.compactMap(\.submenu).flatMap(\.items).first {
            $0.action == #selector(WorkspaceWindowController.toggleFileTree(_:))
        })
        #expect(!loose.validateMenuItem(item))
        #expect(item.title == "Show Sidebar")
        loose.open(dir.appendingPathComponent("src/main.swift"))
        #expect(loose.validateMenuItem(item))
        #expect(loose.activeView?.tryToPerform(item.action!, with: item) == true)
        #expect(loose.folder == nil && loose.tree?.root.url.path == dir.appendingPathComponent("src").path)
        #expect(loose.validateMenuItem(item) && item.title == "Hide Sidebar")
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
            $0.action == #selector(WorkspaceWindowController.showTabNumber(_:))
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

    /// The font size reaches every tab, including ones opened later; ⌘+ (and ⌘=), ⌘− and ⌘0
    /// are in the View menu.
    @Test func fontSizeReachesEveryTab() throws {
        let w = window()
        defer { w.close() }
        w.open(dir.appendingPathComponent("a.txt"))
        w.open(dir.appendingPathComponent("b.txt"))
        w.editorFont.size = 18
        #expect(w.activeView?.fontSize == 18)
        w.open(dir.appendingPathComponent("a.txt"))
        #expect(w.activeView?.fontSize == 18)
        w.open(dir.appendingPathComponent("src/main.swift"))
        #expect(w.activeView?.fontSize == 18)
        let view = try #require(MainMenu.build().items.first { $0.title == "View" }?.submenu)
        let keys = view.items.filter { $0.keyEquivalentModifierMask == .command && !$0.keyEquivalent.isEmpty }.map { ($0.keyEquivalent, $0.action) }
        #expect(keys.map(\.0) == ["+", "=", "-", "0"])
        #expect(keys.map(\.1) == [#selector(AppDelegate.increaseFontSize(_:)), #selector(AppDelegate.increaseFontSize(_:)),
                                  #selector(AppDelegate.decreaseFontSize(_:)), #selector(AppDelegate.resetFontSize(_:))])
        let equals = try #require(view.items.first { $0.keyEquivalent == "=" })
        #expect(equals.isHidden && equals.allowsKeyEquivalentWhenHidden)
    }

    /// The keys people press reach the font size items: ⌘= and ⌘⇧= (shown as ⌘+), ⌘−, ⌘0.
    @Test func fontSizeKeysMatchTheMenu() throws {
        final class Recorder: NSObject {
            var calls: [String] = []
            @objc func increaseFontSize(_ sender: Any?) { calls.append("+") }
            @objc func decreaseFontSize(_ sender: Any?) { calls.append("-") }
            @objc func resetFontSize(_ sender: Any?) { calls.append("0") }
        }
        _ = NSApplication.shared
        let recorder = Recorder()
        let view = try #require(MainMenu.build().items.first { $0.title == "View" }?.submenu)
        for item in view.items where item.action.map(recorder.responds(to:)) == true { item.target = recorder }
        func press(_ chars: String, _ code: UInt16, _ flags: NSEvent.ModifierFlags) -> Bool {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                                         context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                         isARepeat: false, keyCode: code)!
            return view.performKeyEquivalent(with: event)
        }
        #expect(press("=", 24, .command))
        #expect(press("+", 24, [.command, .shift]))
        #expect(press("-", 27, .command))
        #expect(press("0", 29, .command))
        #expect(recorder.calls == ["+", "+", "-", "0"])
    }

    /// Holding ⌘ on its own shows the tab numbers after a moment; letting go hides them, and
    /// a quick shortcut never shows them.
    @Test func holdingCommandShowsTabNumbers() async throws {
        let w = window()
        defer { w.close() }
        w.open(dir.appendingPathComponent("a.txt"))
        w.open(dir.appendingPathComponent("b.txt"))
        let clock = ContinuousClock(), held = clock.now
        w.commandKeyChanged(heldAlone: true)
        #expect(!w.showsTabNumbers)
        // The numbers come after the 300 ms delay, or later when other tests keep the main
        // actor busy, so wait for them rather than a fixed time.
        while !w.showsTabNumbers && clock.now - held < .seconds(3) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(w.showsTabNumbers)
        #expect(clock.now - held >= .milliseconds(290))
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
        // A window per appearance, as the app gets one at launch.
        for (name, appearance) in [("workspace", NSAppearance.Name.darkAqua), ("workspace-light", .aqua)] {
            let w = WorkspaceWindowController(folder: dir, size: NSSize(width: 1000, height: 560), vimEnabled: true, vimSession: VimSession())
            defer { w.close() }
            w.window?.appearance = NSAppearance(named: appearance)
            w.open(dir.appendingPathComponent("README.md"))
            w.open(dir.appendingPathComponent("Sources/App/main.swift"))
            w.activeView?.vim?.handle(keys: VimKey.parse("ix<Esc>"))
            for _ in 0..<100 where !w.isIndexReady { try await Task.sleep(for: .milliseconds(20)) }
            #expect(w.isIndexReady)
            for _ in 0..<200 where w.activeView?.syntax?.isReady != true { try await Task.sleep(for: .milliseconds(10)) }
            #expect(w.activeView?.syntax?.language.name == "swift")
            w.openQuickly(nil)
            w.quickOpenType("mod")
            let view = try #require(w.window?.contentView)
            view.layoutSubtreeIfNeeded()
            let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            if let out = ProcessInfo.processInfo.environment["VIE_SNAPSHOT_DIR"], let png = rep.representation(using: .png, properties: [:]) {
                try png.write(to: URL(fileURLWithPath: out).appendingPathComponent("\(name).png"))
            }
        }
    }
}
