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

    /// ⌘P's panel is made when first asked for, not with every window (it costs launch ~4 ms).
    @Test func quickOpenIsMadeOnFirstUse() throws {
        let w = window(folder: true)
        defer { w.close() }
        w.open(dir.appendingPathComponent("a.txt"))
        #expect(w.madeQuickOpen == nil)
        w.openQuickly(nil)
        #expect(w.madeQuickOpen?.isShown == true)
        w.openQuickly(nil)
        #expect(w.madeQuickOpen?.isShown == false)
        #expect(w.window?.firstResponder === w.activeView)
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

    /// Tabs not shown since a restore keep their cursor and top line through the next save
    /// of the session (they used to come back at the top).
    @Test func unshownTabsKeepTheirPlace() throws {
        let w = window()
        w.open(dir.appendingPathComponent("a.txt"))
        vim(w, "$")
        w.open(dir.appendingPathComponent("b.txt"))
        let state = w.state()
        w.close()
        #expect(state.tabs.map(\.cursor) == [4, 0])

        let r = window()
        defer { r.close() }
        r.restore(state)
        #expect(r.activeTab?.title == "b.txt")
        #expect(r.state().tabs.map(\.cursor) == [4, 0])
        r.selectTab(0)
        #expect(r.activeView?.vim?.cursor == 4)
        #expect(r.state().tabs.map(\.cursor) == [4, 0])
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

    private func text(_ tab: EditorTab) -> String {
        let rope = tab.document.buffer.rope
        return rope.string(in: 0..<rope.byteCount)
    }

    private func recoveryFolder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("vie-recovery-\(UUID().uuidString)")
    }

    private func window(recovery: Recovery) -> WorkspaceWindowController {
        WorkspaceWindowController(folder: dir, size: NSSize(width: 900, height: 600), vimEnabled: true, vimSession: VimSession(),
                                  recovery: recovery)
    }

    /// After a crash the session's tabs come back with their unsaved text, untitled ones too,
    /// and Undo shows what's on disk. Closing tabs and windows removes their copies.
    @Test func crashRecoveryBringsBackUnsavedText() async throws {
        let folder = recoveryFolder()
        let r = Recovery(directory: folder, delay: 0.01)
        let w = window(recovery: r)
        w.open(dir.appendingPathComponent("a.txt"))
        vim(w, "ix<Esc>")
        w.open(dir.appendingPathComponent("b.txt"))
        w.newTab(nil)
        vim(w, "idraft<Esc>")
        w.selectTab(0)
        for _ in 0..<100 where r.backups().count < 2 {
            try await Task.sleep(for: .milliseconds(10))
            await r.flush()
        }
        let state = w.state()
        #expect(state.tabs.map(\.path) == [dir.appendingPathComponent("a.txt").path, dir.appendingPathComponent("b.txt").path, nil])
        #expect(state.tabs.map { $0.backup != nil } == [true, false, true])
        #expect(state.active == 0)
        let data = try JSONEncoder().encode(SessionState(windows: [state]))
        let decoded = try JSONDecoder().decode(SessionState.self, from: data)

        // What a crash leaves behind.
        let left = recoveryFolder()
        try FileManager.default.copyItem(at: folder, to: left)
        _ = await w.closeTab(at: 2, force: true)
        await r.flush()
        #expect(r.backups().count == 1)
        w.close()
        await r.flush()
        #expect(r.backups().isEmpty)

        let after = Recovery(directory: left, delay: 0.01)
        let backups = Dictionary(uniqueKeysWithValues: after.backups().map { ($0.id, $0) })
        #expect(backups.count == 2)
        let restored = window(recovery: after)
        defer { restored.close() }
        #expect(restored.restore(decoded.windows[0], backups: backups) == Set(backups.keys))
        #expect(names(restored) == ["a.txt", "b.txt", "Untitled"])
        #expect(restored.tabs.map(text) == ["xalpha\n", "beta\n", "draft"])
        #expect(restored.tabs.map(\.document.isDirty) == [true, false, true])
        #expect(restored.activeTab?.title == "a.txt")
        #expect(restored.state().tabs.map(\.backup) == decoded.windows[0].tabs.map(\.backup))

        vim(restored, "u")
        #expect(text(restored.tabs[0]) == "alpha\n")
        #expect(!restored.tabs[0].document.isDirty)
        for _ in 0..<100 where after.backups().count > 1 {
            try await Task.sleep(for: .milliseconds(10))
            await after.flush()
        }
        #expect(after.backups().map(\.path) == [nil])
    }

    /// Copies the session didn't list open in their file's tab, or in an untitled one.
    @Test func copiesTheSessionMissedOpenInTabs() throws {
        let w = window(recovery: Recovery(directory: recoveryFolder(), delay: 0.01))
        defer { w.close() }
        w.recover(Recovery.Backup(id: "1", path: dir.appendingPathComponent("a.txt").path, text: Rope("changed\n")))
        w.recover(Recovery.Backup(id: "2", path: nil, text: Rope("draft")))
        #expect(names(w) == ["a.txt", "Untitled"])
        #expect(w.tabs.map(text) == ["changed\n", "draft"])
        #expect(w.tabs.allSatisfy { $0.document.isDirty })
        #expect(w.activeTab?.title == "Untitled")
    }

    /// Without a copy, an untitled tab isn't part of the session.
    @Test func untitledTabsWithoutACopyAreLeftOut() {
        let w = window(recovery: Recovery(directory: recoveryFolder(), delay: 10))
        defer { w.close() }
        w.open(dir.appendingPathComponent("a.txt"))
        w.newTab(nil)
        vim(w, "idraft<Esc>")
        let state = w.state()
        #expect(state.tabs.map(\.path) == [dir.appendingPathComponent("a.txt").path])
        #expect(state.active == nil)
    }

    private func contents(_ name: String) -> String? {
        (try? Data(contentsOf: dir.appendingPathComponent(name))).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Waits (up to two seconds) for `condition`, letting saves and closes finish.
    private func settle(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
    }

    /// The ⌘P panel searches a rebuilt index from scratch: the last results point into the
    /// old one (searching a smaller index with them used to crash).
    @Test func quickOpenSurvivesAnIndexRebuild() {
        let q = QuickOpenController()
        q.index = FuzzyIndex(paths: (0..<2000).map { "dir/file\($0).swift" })
        q.show(in: NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600)))
        q.type("f")
        #expect(q.numberOfRows(in: NSTableView()) == 100)
        q.index = FuzzyIndex(paths: (0..<50).map { "new/file\($0).swift" })
        #expect(q.numberOfRows(in: NSTableView()) == 50)
    }

    /// ⌘P with nothing typed lists the open files, then the closed ones; opening a closed file
    /// again goes back to where it was.
    @Test func quickOpenListsClosedFiles() async throws {
        let w = window()
        defer { w.close() }
        for name in ["a.txt", "b.txt", "src/main.swift"] { w.open(dir.appendingPathComponent(name)) }
        w.selectTab(1)
        vim(w, "$")
        #expect(await w.closeTab(at: 1))
        #expect(await w.closeTab(at: 0))
        w.newTab(nil)
        let untitled = try #require(w.activeIndex)
        #expect(await w.closeTab(at: untitled))
        w.openQuickly(nil)
        let panel = try #require(w.madeQuickOpen)
        #expect(panel.shownRows == ["src/main.swift", "a.txt (closed)", "b.txt (closed)"])
        panel.dismiss()

        let b = dir.appendingPathComponent("b.txt")
        w.open(b)
        #expect(w.activeView?.vim?.cursor == 3)
        #expect(w.closedFiles.map(\.path) == [dir.appendingPathComponent("a.txt").path])
        let reopened = try #require(w.activeIndex)
        #expect(await w.closeTab(at: reopened))

        // Renamed in the sidebar; deleted by another app.
        let a = dir.appendingPathComponent("a.txt"), c = dir.appendingPathComponent("c.txt")
        try FileManager.default.moveItem(at: a, to: c)
        w.renamed(a, c)
        try FileManager.default.removeItem(at: b)
        w.openQuickly(nil)
        #expect(panel.shownRows == ["src/main.swift", "c.txt (closed)"])
    }

    /// Before the folder is indexed, typing filters the open and the closed files.
    @Test func quickOpenFiltersClosedFilesWhileIndexing() {
        let q = QuickOpenController()
        q.recent = ["a.txt", "b.txt"]
        q.closed = ["lib/a.md", "c.txt"]
        q.show(in: NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600)))
        #expect(q.shownRows == ["a.txt", "b.txt", "lib/a.md (closed)", "c.txt (closed)"])
        q.type("a")
        #expect(q.shownRows == ["a.txt", "lib/a.md (closed)"])
    }

    @Test func closedFilesAreKeptInTheSession() async throws {
        let w = window()
        w.open(dir.appendingPathComponent("a.txt"))
        w.open(dir.appendingPathComponent("b.txt"))
        vim(w, "$")
        w.open(dir.appendingPathComponent("src/main.swift"))
        w.selectTab(1)
        #expect(await w.closeTab(at: 1))
        let state = w.state()
        w.close()
        let decoded = try JSONDecoder().decode(SessionState.self, from: JSONEncoder().encode(SessionState(windows: [state])))

        let r = window()
        defer { r.close() }
        r.restore(decoded.windows[0])
        #expect(r.closedFiles.map(\.path) == [dir.appendingPathComponent("b.txt").path])
        // a.txt hasn't been shown since the restore, but it's open.
        r.openQuickly(nil)
        #expect(r.madeQuickOpen?.shownRows == ["src/main.swift", "a.txt", "b.txt (closed)"])
        r.madeQuickOpen?.dismiss()
        r.open(dir.appendingPathComponent("b.txt"))
        #expect(r.activeView?.vim?.cursor == 3)
        #expect(r.closedFiles.isEmpty)
        #expect(r.state().closed == nil)
    }

    /// A session saved before closed files were kept still loads.
    @Test func sessionWithoutClosedFilesDecodes() throws {
        let json = #"{"tabs": [], "expanded": []}"#
        let window = try JSONDecoder().decode(SessionState.Window.self, from: Data(json.utf8))
        #expect(window.closed == nil && window.tabs.isEmpty)
    }

    /// The status bar shows each tab's encoding and line endings; the subtitle only the folder.
    @Test func statusBarShowsTheFileFormat() throws {
        try Data("one\r\ntwo\r\n".utf8).write(to: dir.appendingPathComponent("crlf.txt"))
        try Data("one\ntwo\r\nthree\r\n".utf8).write(to: dir.appendingPathComponent("mixed.txt"))
        let w = window()
        defer { w.close() }
        w.open(dir.appendingPathComponent("a.txt"))
        #expect(w.statusBar.fileFormat == "UTF-8 · LF")
        w.open(dir.appendingPathComponent("crlf.txt"))
        #expect(w.statusBar.fileFormat == "UTF-8 · CRLF")
        w.open(dir.appendingPathComponent("mixed.txt"))
        #expect(w.statusBar.fileFormat == "UTF-8 · CRLF (mixed)" && w.statusBar.fileFormatNote?.contains("CRLF") == true)
        #expect(w.window?.subtitle == dir.lastPathComponent)
        w.selectTab(0)
        #expect(w.statusBar.fileFormat == "UTF-8 · LF")
    }

    /// The status bar's menu changes the line endings and encoding for the next save, and
    /// reads the file again in another encoding.
    @Test func fileFormatMenuChangesTheFormat() async throws {
        let w = window()
        defer { w.close() }
        w.open(dir.appendingPathComponent("a.txt"))
        let menu = try #require(w.fileFormatMenu())
        #expect(menu.items.first { $0.state == .on }?.title == "LF (macOS, Linux)")
        w.chooseLineEnding(try #require(menu.items.first { $0.title == "CRLF (Windows)" }))
        #expect(w.tabs[0].document.isDirty && w.statusBar.fileFormat == "UTF-8 · CRLF")
        let latin1 = try #require(TextEncoding.all.firstIndex { $0.encoding == .isoLatin1 })
        let saveWith = try #require(menu.items.first { $0.title == "Save with Encoding" }?.submenu)
        #expect(saveWith.items.first { $0.state == .on }?.title == TextEncoding.all[0].title)
        w.saveWithEncoding(try #require(saveWith.items.first { $0.tag == latin1 }))
        #expect(w.statusBar.fileFormat == "Latin-1 · CRLF")
        #expect(await w.save(w.tabs[0], as: false))
        #expect(!w.tabs[0].document.isDirty && contents("a.txt") == "alpha\r\n")

        try Data([0x82, 0xA0, 0x0A]).write(to: dir.appendingPathComponent("j.txt"))
        w.open(dir.appendingPathComponent("j.txt"))
        let reopen = try #require(w.fileFormatMenu()?.items.first { $0.title == "Reopen with Encoding" })
        #expect(reopen.isEnabled)
        w.reopenWithEncoding(try #require(reopen.submenu?.items.first { $0.tag == latin1 }))
        #expect(w.statusBar.fileFormat == "Latin-1 · LF" && w.activeView?.rope.byteCount == 5)
        w.newTab(nil)
        #expect(w.fileFormatMenu()?.items.first { $0.title == "Reopen with Encoding" }?.isEnabled == false)
    }

    @Test func vimSetsTheFileFormat() throws {
        let w = window()
        defer { w.close() }
        w.open(dir.appendingPathComponent("a.txt"))
        vim(w, ":set ff?<CR>")
        #expect(w.activeView?.vim?.message == "  fileformat=unix")
        vim(w, ":set ff=dos fenc=latin1<CR>")
        #expect(w.statusBar.fileFormat == "Latin-1 · CRLF" && w.tabs[0].document.isDirty)
        vim(w, ":set fenc?<CR>")
        #expect(w.activeView?.vim?.message == "  fileencoding=latin1")
        vim(w, ":q<CR>")
        #expect(w.activeView?.vim?.message?.hasPrefix("E37") == true)
        vim(w, ":set ff=windows<CR>")
        #expect(w.activeView?.vim?.message == "E474: Invalid argument: ff=windows")
        vim(w, ":set ff=unix fenc=utf-8<CR>")
        #expect(!w.tabs[0].document.isDirty)
        vim(w, ":set bomb<CR>")
        #expect(w.statusBar.fileFormat == "UTF-8 with BOM · LF" && w.tabs[0].document.isDirty)
        vim(w, ":set bomb?<CR>")
        #expect(w.activeView?.vim?.message == "  bomb")
        vim(w, ":set nobomb<CR>")
        #expect(!w.tabs[0].document.isDirty)

        try Data([0x82, 0xA0, 0x0A]).write(to: dir.appendingPathComponent("j.txt"))
        vim(w, ":e ++enc=latin1 j.txt<CR>")
        #expect(w.activeTab?.title == "j.txt" && w.statusBar.fileFormat == "Latin-1 · LF")
        #expect(w.activeView?.vim?.message == "\"j.txt\" read as Latin-1")
        vim(w, ":e ++enc=klingon<CR>")
        #expect(w.activeView?.vim?.message == "E474: Invalid argument: ++enc=klingon")
    }

    /// Save As offers the encoding and line endings, set to the file's.
    @Test func saveAsChoosesTheFormat() {
        let c = FormatChooser(TextFormat(encoding: .shiftJIS, lineEnding: .crlf))
        #expect(c.format == TextFormat(encoding: .shiftJIS, lineEnding: .crlf))
        #expect(c.encodingPopUp.titleOfSelectedItem == "Japanese (Shift JIS)")
        #expect(c.lineEndingPopUp.titleOfSelectedItem == "CRLF (Windows)")
        c.encodingPopUp.selectItem(withTag: 1)
        c.lineEndingPopUp.selectItem(at: 0)
        #expect(c.format == TextFormat(encoding: .utf8, hasBOM: true, lineEnding: .lf))
        #expect(c.view.frame.width > 200 && c.view.frame.height > 50)
        // UTF-32, which Vie reads but doesn't offer, stays as it is.
        let other = FormatChooser(TextFormat(encoding: .utf32LittleEndian, hasBOM: true))
        #expect(other.encodingPopUp.selectedTag() == -1)
        #expect(other.format == TextFormat(encoding: .utf32LittleEndian, hasBOM: true))
    }

    /// A tab dragged within the bar moves there; dragged to another window it moves with its
    /// unsaved changes and undo history, and its Vim commands go to the new window.
    @Test func tabsMoveWithinAndBetweenWindows() async throws {
        let w = window()
        defer { w.close() }
        for name in ["a.txt", "b.txt", "src/main.swift"] { w.open(dir.appendingPathComponent(name)) }
        w.selectTab(1)
        w.moveTab(from: 1, to: 2)
        #expect(names(w) == ["a.txt", "main.swift", "b.txt"] && w.activeTab?.title == "b.txt")
        w.moveTab(from: 0, to: 2)
        #expect(names(w) == ["main.swift", "b.txt", "a.txt"] && w.activeTab?.title == "b.txt")
        vim(w, "ix<Esc>")

        let other = window(folder: false)
        defer { other.close() }
        other.open(try fileElsewhere())
        other.takeTab(at: 1, from: w, to: 0)
        #expect(names(w) == ["main.swift", "a.txt"] && w.activeTab?.title == "main.swift")
        #expect(names(other) == ["b.txt", "note.md"] && other.activeTab?.title == "b.txt")
        #expect(other.activeTab?.document.isDirty == true)
        vim(other, "u")
        #expect(other.activeView.map { $0.rope.string(in: 0..<$0.rope.byteCount) } == "beta\n")
        vim(other, ":ls<CR>")
        #expect(other.activeView?.vim?.message?.contains("note.md") == true)

        // A file open in both windows stays where it is; its tab here is shown.
        w.open(dir.appendingPathComponent("b.txt"))
        other.selectTab(1)
        other.takeTab(at: try #require(w.tabIndex(for: dir.appendingPathComponent("b.txt"))), from: w, to: 0)
        #expect(names(w) == ["main.swift", "b.txt", "a.txt"] && names(other) == ["b.txt", "note.md"])
        #expect(other.activeTab?.title == "b.txt")

        // A window of loose files closes when its last tab leaves.
        let loose = window(folder: false)
        var closed = false
        loose.onClose = { _ in closed = true }
        loose.open(try fileElsewhere())
        w.takeTab(at: 0, from: loose, to: 0)
        try await settle { closed }
        #expect(closed && names(w).first == "note.md")
    }

    /// New File never empties a file that's already there.
    @Test func newFileDoesNotOverwrite() throws {
        let existing = dir.appendingPathComponent("a.txt")
        #expect(throws: (any Error).self) { try FileTreeController.createEmptyFile(at: existing) }
        #expect(contents("a.txt") == "alpha\n")
        try FileTreeController.createEmptyFile(at: dir.appendingPathComponent("new/empty.txt"))
        #expect(contents("new/empty.txt") == "")
    }

    /// `:x!` writes changes before closing, as `:x` does (it used to throw them away).
    @Test func exitWithBangWritesChanges() async throws {
        let w = window()
        defer { w.close() }
        w.open(dir.appendingPathComponent("a.txt"))
        w.open(dir.appendingPathComponent("b.txt"))
        vim(w, "ix<Esc>:x!<CR>")
        try await settle { w.tabs.count == 1 }
        #expect(names(w) == ["a.txt"])
        #expect(contents("b.txt") == "xbeta\n")
    }

    /// `:wq other.txt` writes a copy but, as in Vim, a buffer with changes of its own stays
    /// open; `:wq!` closes it.
    @Test func writeQuitToAnotherFileKeepsAChangedBuffer() async throws {
        let w = window()
        defer { w.close() }
        w.open(dir.appendingPathComponent("a.txt"))
        vim(w, "ix<Esc>:wq copy.txt<CR>")
        try await settle { w.activeView?.vim?.message?.hasPrefix("E37") == true }
        #expect(w.activeView?.vim?.message?.hasPrefix("E37") == true)
        #expect(contents("copy.txt") == "xalpha\n")
        #expect(contents("a.txt") == "alpha\n")
        #expect(names(w) == ["a.txt"] && w.activeTab?.document.isDirty == true)
        vim(w, ":wq! copy.txt<CR>")
        try await settle { w.tabs.isEmpty }
        #expect(w.tabs.isEmpty)
    }

    /// After a crash, a tab whose file changed or was deleted meanwhile (a `git checkout`,
    /// say) still gets its unsaved text back, and is marked to say so; Undo shows the file as
    /// it is now. Tabs whose file is as it was aren't marked.
    @Test func recoveryNoticesFilesChangedSinceTheCrash() async throws {
        let folder = recoveryFolder()
        let r = Recovery(directory: folder, delay: 0.01)
        let w = window(recovery: r)
        for name in ["a.txt", "b.txt", "src/main.swift"] {
            w.open(dir.appendingPathComponent(name))
            vim(w, "ix<Esc>")
        }
        for _ in 0..<100 where r.backups().count < 3 {
            try await Task.sleep(for: .milliseconds(10))
            await r.flush()
        }
        let state = w.state()
        let left = recoveryFolder()
        try FileManager.default.copyItem(at: folder, to: left)
        w.close()

        try Data("checked out\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        try FileManager.default.removeItem(at: dir.appendingPathComponent("b.txt"))
        let after = Recovery(directory: left, delay: 0.01)
        let restored = window(recovery: after)
        defer { restored.close() }
        restored.restore(state, backups: Dictionary(uniqueKeysWithValues: after.backups().map { ($0.id, $0) }))
        #expect(names(restored) == ["a.txt", "b.txt", "main.swift"])
        #expect(restored.tabs.map(text) == ["xalpha\n", "xbeta\n", "xlet x = 1\n"])
        #expect(restored.tabs.map(\.recoveryWarning) == [.changed, .deleted, nil])
        restored.selectTab(0)
        vim(restored, "u")
        #expect(text(restored.tabs[0]) == "checked out\n")
    }

    /// Naming an untitled tab with `:w` counts as Save As (Open Recent lists the file); a copy
    /// written with `:w other` doesn't, nor does a plain save.
    @Test func namingAnUntitledTabIsReported() async throws {
        let w = window()
        defer { w.close() }
        var named: [URL] = []
        w.onSaveAs = { named.append($0) }
        w.newTab(nil)
        vim(w, "ix<Esc>:w new.txt<CR>")
        try await settle { !named.isEmpty }
        #expect(named == [dir.appendingPathComponent("new.txt")])
        vim(w, ":w copy.txt<CR>")
        try await settle { contents("copy.txt") != nil }
        #expect(contents("copy.txt") == "x")
        vim(w, "iy<Esc>:w<CR>")
        try await settle { contents("new.txt") == "yx" }
        #expect(contents("new.txt") == "yx")
        #expect(named.count == 1)
    }

    /// Renaming in the sidebar: tabs follow their files, unsaved changes included, and the
    /// current tab stays current (renaming another tab's file used to leave none).
    @Test func tabsFollowRenamedFiles() async throws {
        let fm = FileManager.default
        let w = window()
        defer { w.close() }
        w.open(dir.appendingPathComponent("a.txt"))
        w.open(dir.appendingPathComponent("b.txt"))
        vim(w, "ix<Esc>")
        w.open(dir.appendingPathComponent("src/main.swift"))
        w.selectTab(0)
        let b = dir.appendingPathComponent("b.txt"), c = dir.appendingPathComponent("c.txt")
        try fm.moveItem(at: b, to: c)
        w.renamed(b, c)
        #expect(w.activeTab?.title == "a.txt")
        #expect(names(w) == ["a.txt", "c.txt", "main.swift"])
        #expect(w.tabs[1].document.isDirty)
        #expect(await w.save(w.tabs[1], as: false))
        #expect(contents("c.txt") == "xbeta\n")
        #expect(!fm.fileExists(atPath: b.path))

        let src = dir.appendingPathComponent("src"), lib = dir.appendingPathComponent("lib")
        try fm.moveItem(at: src, to: lib)
        w.renamed(src, lib)
        #expect(w.tabs[2].document.fileURL == lib.appendingPathComponent("main.swift"))
        #expect(w.activeTab?.title == "a.txt")
    }

    /// The tree's rows: the file's row selected and the outline given the keyboard.
    private func selectInTree(_ w: WorkspaceWindowController, _ name: String) throws -> NSOutlineView {
        let tree = try #require(descendant(NSOutlineView.self, of: w.window?.contentView))
        let node = try #require(w.tree?.node(for: dir.appendingPathComponent(name)))
        tree.selectRowIndexes([tree.row(forItem: node)], byExtendingSelection: false)
        w.window?.makeFirstResponder(tree)
        return tree
    }

    /// Renaming in the tree: r (Vim mode) puts a field on the row with the name selected up to
    /// the extension; Return renames the file, its tab follows, also in another window, and the
    /// keyboard stays in the tree. Esc leaves the name as it was; a taken name is refused.
    @Test func renamesInPlace() throws {
        let w = window()
        defer { w.close() }
        let loose = window(folder: false)
        defer { loose.close() }
        w.onFileMoved = { from, to in [w, loose].forEach { $0.renamed(from, to) } }
        var errors: [Error] = []
        w.sidebar?.onError = { errors.append($0) }
        loose.open(dir.appendingPathComponent("b.txt"))
        let tree = try selectInTree(w, "b.txt")
        try press(tree, "r")
        let field = try #require(w.window?.firstResponder as? NSTextView)
        #expect(field.string == "b.txt" && field.selectedRange() == NSRange(location: 0, length: 1))
        field.insertText("c", replacementRange: field.selectedRange())
        field.insertNewline(nil)
        #expect(contents("c.txt") == "beta\n" && contents("b.txt") == nil)
        #expect(loose.activeTab?.document.fileURL == dir.appendingPathComponent("c.txt"))
        #expect(w.window?.firstResponder === tree && selectedInTree(w)?.lastPathComponent == "c.txt")
        #expect(w.window?.undoManager?.undoActionName == "Rename")

        try press(tree, "r")
        let again = try #require(w.window?.firstResponder as? NSTextView)
        again.insertText("zzz", replacementRange: again.selectedRange())
        again.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        #expect(contents("c.txt") != nil && contents("zzz.txt") == nil)
        #expect(w.window?.firstResponder === tree)

        try press(tree, "r")
        let taken = try #require(w.window?.firstResponder as? NSTextView)
        taken.insertText("a", replacementRange: taken.selectedRange())
        taken.insertNewline(nil)
        #expect(errors.first as? FileTreeError == .nameTaken("a.txt"))
        #expect(contents("a.txt") == "alpha\n" && contents("c.txt") == "beta\n")
    }

    /// Dropping in the tree: from a tree a move (⌥ a copy), from Finder a copy; not a folder into
    /// itself, nor a move to where the item is. A moved file's tab follows, unsaved changes
    /// included; copies get Finder's names when theirs is taken; a move never replaces.
    @Test func dropsMoveAndCopy() throws {
        let w = window()
        defer { w.close() }
        let side = try #require(w.sidebar)
        var errors: [Error] = []
        side.onError = { errors.append($0) }
        let a = dir.appendingPathComponent("a.txt"), b = dir.appendingPathComponent("b.txt")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("src/inner"), withIntermediateDirectories: true)
        let src = try #require(side.tree.expand(to: dir.appendingPathComponent("src")))
        let inner = try #require(side.tree.expand(to: dir.appendingPathComponent("src/inner")))
        let root = side.tree.root
        #expect(side.dropOperation([b], into: src, fromTree: true, allowed: [.move, .copy]) == .move)
        #expect(side.dropOperation([b], into: src, fromTree: true, allowed: .copy) == .copy)
        #expect(side.dropOperation([b], into: src, fromTree: false, allowed: [.copy, .move, .link, .generic]) == .copy)
        #expect(side.dropOperation([b], into: root, fromTree: true, allowed: [.move, .copy]) == [])
        #expect(side.dropOperation([b], into: root, fromTree: true, allowed: .copy) == .copy)
        #expect(side.dropOperation([src.url], into: src, fromTree: true, allowed: [.move, .copy]) == [])
        #expect(side.dropOperation([src.url], into: inner, fromTree: false, allowed: .copy) == [])

        w.open(b)
        vim(w, "ix<Esc>")
        let moved = side.drop([b], into: src, copying: false)
        #expect(moved == [src.url.appendingPathComponent("b.txt")])
        #expect(w.activeTab?.document.fileURL == moved.first && w.activeTab?.document.isDirty == true)
        #expect(selectedInTree(w) == moved.first)

        #expect(side.drop([a], into: root, copying: true).map(\.lastPathComponent) == ["a copy.txt"])
        #expect(side.drop([a], into: root, copying: true).map(\.lastPathComponent) == ["a copy 2.txt"])
        #expect(side.drop([src.url], into: root, copying: true).map(\.lastPathComponent) == ["src copy"])
        #expect(contents("a copy.txt") == "alpha\n" && contents("src copy/b.txt") == "beta\n")

        try Data("other\n".utf8).write(to: src.url.appendingPathComponent("a.txt"))
        #expect(side.drop([a], into: src, copying: false).isEmpty && errors.count == 1)
        #expect(errors.first as? FileTreeError == .alreadyThere("a.txt", folder: "src"))
        #expect(contents("a.txt") == "alpha\n" && contents("src/a.txt") == "other\n")
    }

    /// A drop goes into the folder under the pointer, whatever the outline proposes: over the
    /// folder an item is already in, nothing happens (the outline then proposes the gap at the
    /// row's edge, which can belong to the folder above, and the item went there). Dragging from
    /// anywhere in a row isn't tested here: AppKit only refuses the empty part of a row in a
    /// window on screen.
    @Test func dropsWhereThePointerIs() throws {
        let w = window()
        defer { w.close() }
        let side = try #require(w.sidebar)
        side.expand(paths: ["src"])
        let tree = try #require(descendant(FileOutlineView.self, of: w.window?.contentView))
        let main = dir.appendingPathComponent("src/main.swift"), b = dir.appendingPathComponent("b.txt")
        let row = tree.row(forItem: side.tree.node(for: main))
        try #require(row >= 0)
        let rect = tree.rect(ofRow: row)
        let overMain = tree.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)

        let own = FakeDrag(main, at: overMain, source: tree)
        defer { own.release() }
        #expect(side.outlineView(tree, validateDrop: own, proposedItem: nil, proposedChildIndex: 0) == [])
        #expect(!side.outlineView(tree, acceptDrop: own, item: nil, childIndex: 0))
        #expect(contents("src/main.swift") == "let x = 1\n")

        let other = FakeDrag(b, at: overMain, source: tree)
        defer { other.release() }
        #expect(side.outlineView(tree, validateDrop: other, proposedItem: nil, proposedChildIndex: 0) == .move)
        #expect(side.outlineView(tree, acceptDrop: other, item: nil, childIndex: 0))
        #expect(contents("src/b.txt") == "beta\n" && contents("b.txt") == nil)
    }

    /// The tree's top row is the folder itself, open at first. It folds like any folder, and
    /// showing a file in it opens it again; a drop on it goes into the folder. It isn't renamed,
    /// trashed or dragged (the window is built on it), and its menu leaves those out.
    @Test func topRowIsTheFolder() throws {
        let w = window()
        defer { w.close() }
        let side = try #require(w.sidebar)
        let tree = try #require(descendant(FileOutlineView.self, of: w.window?.contentView))
        let root = side.tree.root
        #expect(tree.item(atRow: 0) as? FileNode === root && tree.isItemExpanded(root))
        #expect(tree.numberOfRows == 4 && tree.level(forRow: 1) == 1) // the folder, then src, a.txt, b.txt

        func titles(_ node: FileNode?) -> [String] {
            let menu = NSMenu()
            side.fill(menu, for: node)
            return menu.items.map { $0.isSeparatorItem ? "—" : $0.title }
        }
        let a = try #require(side.tree.node(for: dir.appendingPathComponent("a.txt")))
        #expect(titles(root) == ["New File…", "New Folder…", "—", "Reveal in Finder", "Copy Path"])
        #expect(titles(a) == ["New File…", "New Folder…", "—", "Rename", "Move to Trash", "—",
                              "Reveal in Finder", "Copy Path", "Copy Relative Path"])
        #expect(titles(nil) == ["New File…", "New Folder…"])
        #expect(side.outlineView(tree, pasteboardWriterForItem: root) == nil)
        #expect(side.outlineView(tree, pasteboardWriterForItem: a) != nil)
        side.beginRename(root)
        #expect(!(w.window?.firstResponder is NSTextView))

        let rect = tree.rect(ofRow: 0)
        let drag = FakeDrag(dir.appendingPathComponent("src/main.swift"), at: tree.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil), source: tree)
        defer { drag.release() }
        #expect(side.outlineView(tree, validateDrop: drag, proposedItem: nil, proposedChildIndex: 0) == .move)
        #expect(side.outlineView(tree, acceptDrop: drag, item: nil, childIndex: 0))
        #expect(contents("main.swift") == "let x = 1\n" && contents("src/main.swift") == nil)

        tree.collapseItem(root)
        #expect(tree.numberOfRows == 1)
        w.open(dir.appendingPathComponent("b.txt"))
        #expect(tree.isItemExpanded(root) && selectedInTree(w)?.lastPathComponent == "b.txt")
    }

    /// Edit ▸ Undo, with the tree's keyboard, takes back a move (the tab follows back), a copy
    /// (to the Trash) and a trash (put back); Redo does them again.
    @Test func undoTakesBackTreeOperations() throws {
        let w = window()
        defer { w.close() }
        let side = try #require(w.sidebar)
        let trash = FileManager.default.temporaryDirectory.appendingPathComponent("vie-trash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        side.trashItem = { url in
            let place = trash.appendingPathComponent(UUID().uuidString)
            try FileManager.default.moveItem(at: url, to: place)
            return place
        }
        let undo = try #require(w.window?.undoManager)
        undo.groupsByEvent = false
        func step(_ body: () -> Void) {
            undo.beginUndoGrouping()
            body()
            undo.endUndoGrouping()
        }
        let a = dir.appendingPathComponent("a.txt"), b = dir.appendingPathComponent("b.txt")
        let src = try #require(side.tree.node(for: dir.appendingPathComponent("src")))
        w.open(b)

        step { side.drop([b], into: src, copying: false) }
        #expect(undo.undoMenuItemTitle == "Undo Move “b.txt”")
        undo.undo()
        #expect(contents("b.txt") == "beta\n" && w.activeTab?.document.fileURL == b)
        #expect(undo.redoMenuItemTitle == "Redo Move “b.txt”")
        undo.redo()
        #expect(contents("src/b.txt") == "beta\n" && w.activeTab?.document.fileURL == src.url.appendingPathComponent("b.txt"))

        step { side.drop([a], into: src, copying: true) }
        #expect(undo.undoMenuItemTitle == "Undo Copy “a.txt”")
        undo.undo()
        #expect(contents("src/a.txt") == nil && contents("a.txt") == "alpha\n")
        undo.redo()
        #expect(contents("src/a.txt") == "alpha\n")

        step { side.trash([a]) }
        #expect(contents("a.txt") == nil && undo.undoMenuItemTitle == "Undo Move to Trash")
        undo.undo()
        #expect(contents("a.txt") == "alpha\n")
        undo.redo()
        #expect(contents("a.txt") == nil)
    }

    /// The tabs' languages, each window's current tab first, so their queries are compiled
    /// before the tabs are parsed; a language picked by hand counts, plain text has none.
    @Test func sessionLanguagesPutCurrentTabsFirst() {
        func tab(_ name: String, _ language: String? = nil) -> SessionState.Tab {
            SessionState.Tab(path: dir.appendingPathComponent(name).path, cursor: 0, topLine: 0, language: language)
        }
        let state = SessionState(windows: [
            SessionState.Window(folder: dir.path, frame: nil, sidebarWidth: nil,
                                tabs: [tab("a.md"), tab("b.swift"), tab("c.txt", "python"), tab("d.swift")], active: 1, expanded: []),
            SessionState.Window(folder: nil, frame: nil, sidebarWidth: nil, tabs: [tab("e.rs", ""), tab("f.json"), tab("g.c", "nonesuch")], active: 0, expanded: []),
        ])
        #expect(state.languages.map(\.name) == ["swift", "markdown", "python", "json", "c"])
    }

    /// A tab that can't be reopened doesn't make the restore pick the wrong current tab.
    @Test func restoreKeepsTheCurrentTabWhenAnEarlierOneIsGone() {
        let state = SessionState.Window(folder: dir.path, frame: nil, sidebarWidth: nil, tabs: [
            SessionState.Tab(path: dir.appendingPathComponent("gone.txt").path, cursor: 0, topLine: 0),
            SessionState.Tab(path: dir.appendingPathComponent("a.txt").path, cursor: 0, topLine: 0),
            SessionState.Tab(path: dir.appendingPathComponent("b.txt").path, cursor: 0, topLine: 0),
        ], active: 2, expanded: [])
        let r = window()
        defer { r.close() }
        r.restore(state)
        #expect(names(r) == ["a.txt", "b.txt"])
        #expect(r.activeTab?.title == "b.txt")
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
    /// file; j and k move, l opens a folder and then moves into it, h closes it (from an item at
    /// the top, the project's row), and Return
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
        #expect(selectedInTree(w)?.lastPathComponent == "src" && tree.numberOfRows == 4)
        try press(tree, "h") // src is at the top: h folds the project and selects its row
        #expect(selectedInTree(w)?.lastPathComponent == dir.lastPathComponent && tree.numberOfRows == 1)
        try press(tree, "l")
        #expect(tree.numberOfRows == 4)
        try press(tree, "j")
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
        tree.selectRowIndexes([3], byExtendingSelection: false) // the folder, src, a.txt, b.txt
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

/// A drag held over a window, for calling a view's drop methods directly: one file on its own
/// pasteboard, at a point in window coordinates.
@MainActor
private final class FakeDrag: NSObject, @preconcurrency NSDraggingInfo {
    let draggingPasteboard = NSPasteboard.withUniqueName()
    let draggingLocation: NSPoint
    let draggingSource: Any?
    let draggingSourceOperationMask: NSDragOperation

    init(_ url: URL, at location: NSPoint, source: Any?, allowed: NSDragOperation = [.move, .copy]) {
        draggingLocation = location
        draggingSource = source
        draggingSourceOperationMask = allowed
        super.init()
        draggingPasteboard.clearContents()
        draggingPasteboard.writeObjects([url as NSURL])
    }

    func release() { draggingPasteboard.releaseGlobally() }

    var draggingDestinationWindow: NSWindow? { nil }
    var draggedImageLocation: NSPoint { draggingLocation }
    var draggedImage: NSImage? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    func resetSpringLoading() {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?,
                                classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}
