import AppKit
import VieEditor
import VieSyntax
import VieText
import VieVim
import VieWorkspace

/// One open buffer in a window: a document and, once shown, its editor view.
@MainActor
final class EditorTab {
    let document: Document
    var view: EditorView?
    /// Where to put the cursor and scroll when the view is first made (session restore).
    var restoreCursor: Int?
    var restoreTopLine: Int?
    var diskAlertShowing = false

    init(document: Document) { self.document = document }

    var title: String { document.displayName }

    /// An empty untitled buffer nobody has typed into, which opening a file may replace.
    var isUntouched: Bool {
        document.fileURL == nil && !document.buffer.canUndo && document.buffer.rope.isEmpty
    }
}

/// A window: a folder's tree in the sidebar (or no sidebar for loose files), a tab per open
/// buffer, the editor, and the status bar.
@MainActor
final class WorkspaceWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation, NSSplitViewDelegate {
    /// The folder, or nil for a window of loose files.
    let folder: URL?
    let tree: FileTree?
    private(set) var tabs: [EditorTab] = []
    private(set) var activeIndex: Int?
    /// Tabs in the order they were last active, most recent first.
    private var history: [ObjectIdentifier] = []

    var onClose: ((WorkspaceWindowController) -> Void)?
    /// Something worth saving in the session changed (tabs opened, closed or switched).
    var onSessionChange: (() -> Void)?

    let vimSession: VimSession
    var vimEnabled: Bool {
        didSet { for tab in tabs { tab.view?.vimEnabled = vimEnabled } }
    }
    var wrapsLines: Bool {
        didSet { for tab in tabs { tab.view?.wrapsLines = wrapsLines } }
    }
    var editorFont: EditorFont {
        didSet { for tab in tabs { tab.view?.editorFont = editorFont } }
    }

    private let split = NSSplitView()
    private var sidebar: FileTreeController?
    private let column = NSView()
    private let tabBar: TabBarView
    private let editorHost = EmptyEditorView()
    let statusBar: StatusBarView
    private let quickOpen = QuickOpenController()
    private var index: FuzzyIndex?
    private var indexGeneration = 0
    private var indexRebuild: DispatchWorkItem?
    private var closeConfirmed = false

    var activeTab: EditorTab? { activeIndex.map { tabs[$0] } }
    /// The ⌘P index has been built.
    var isIndexReady: Bool { index != nil }
    /// Types into the ⌘P field (for tests and snapshots).
    func quickOpenType(_ text: String) { quickOpen.type(text) }
    var activeView: EditorView? { activeTab?.view }

    init(folder: URL?, size: NSSize, vimEnabled: Bool, vimSession: VimSession, wrapsLines: Bool = true,
         font: EditorFont = EditorFont()) {
        self.folder = folder?.standardizedFileURL.resolvingSymlinksInPath()
        tree = self.folder.map { FileTree(folder: $0) }
        self.vimEnabled = vimEnabled
        self.vimSession = vimSession
        self.wrapsLines = wrapsLines
        self.editorFont = font
        let rect = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: rect, styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 420, height: 240)
        window.tabbingMode = .disallowed
        tabBar = TabBarView(frame: NSRect(x: 0, y: size.height - TabBarView.height, width: size.width, height: TabBarView.height))
        statusBar = StatusBarView(frame: NSRect(x: 0, y: 0, width: size.width, height: StatusBarView.height), editor: nil)
        super.init(window: window)
        window.delegate = self
        buildViews(size: size)
        if let tree {
            tree.onEvents = { [weak self] folders, rescan in self?.foldersChanged(folders, rescan: rescan) }
            // Watching and indexing start once the window is up, so their file-system work
            // doesn't compete with the first frame.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self, self.window?.isVisible == true || self.window != nil else { return }
                tree.startWatching()
                self.rebuildIndex()
            }
        }
        quickOpen.topInset = TabBarView.height
        quickOpen.onOpen = { [weak self] path in self?.openQuickOpenResult(path) }
        quickOpen.onDismiss = { [weak self] in
            guard let self, let view = self.activeView else { return }
            self.window?.makeFirstResponder(view)
        }
        updateTitle()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func buildViews(size: NSSize) {
        guard let window else { return }
        split.isVertical = true
        split.dividerStyle = .thin
        split.delegate = self
        split.frame = NSRect(origin: .zero, size: size)
        split.autoresizingMask = [.width, .height]

        column.frame = NSRect(origin: .zero, size: size)
        let barH = StatusBarView.height, tabH = TabBarView.height
        statusBar.frame = NSRect(x: 0, y: 0, width: size.width, height: barH)
        statusBar.autoresizingMask = [.width, .maxYMargin]
        tabBar.frame = NSRect(x: 0, y: size.height - tabH, width: size.width, height: tabH)
        tabBar.autoresizingMask = [.width, .minYMargin]
        editorHost.frame = NSRect(x: 0, y: barH, width: size.width, height: size.height - barH - tabH)
        editorHost.autoresizingMask = [.width, .height]
        column.addSubview(editorHost)
        column.addSubview(tabBar)
        column.addSubview(statusBar)
        tabBar.onSelect = { [weak self] i in self?.selectTab(i) }
        tabBar.onClose = { [weak self] i in
            guard let self else { return }
            Task { await self.closeTab(at: i) }
        }
        tabBar.onNewTab = { [weak self] in self?.newTab(nil) }
        watchCommandKey()

        if let tree {
            let side = FileTreeController(tree: tree)
            side.onOpen = { [weak self] url in self?.open(url) }
            side.onError = { [weak self] error in self?.presentSoon(error) }
            side.onRename = { [weak self] from, to in self?.renamed(from, to) }
            sidebar = side
            side.view.frame = NSRect(x: 0, y: 0, width: 240, height: size.height)
            split.addSubview(side.view)
        }
        split.addSubview(column)
        split.adjustSubviews()
        if sidebar != nil { split.setPosition(240, ofDividerAt: 0) }
        window.contentView = split
    }

    // MARK: - Split view

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposed: CGFloat, ofSubviewAt index: Int) -> CGFloat {
        max(proposed, 140)
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposed: CGFloat, ofSubviewAt index: Int) -> CGFloat {
        min(proposed, splitView.bounds.width - 300)
    }

    func splitView(_ splitView: NSSplitView, shouldAdjustSizeOfSubview view: NSView) -> Bool {
        view !== sidebar?.view // the sidebar keeps its width when the window resizes
    }

    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool { subview === sidebar?.view }

    var sidebarWidth: CGFloat? {
        guard let side = sidebar?.view, !split.isSubviewCollapsed(side) else { return nil }
        return side.frame.width
    }

    func setSidebar(width: CGFloat?) {
        guard sidebar != nil else { return }
        if let width { split.setPosition(width, ofDividerAt: 0) } else { split.setPosition(0, ofDividerAt: 0) }
    }

    /// View ▸ Hide/Show Sidebar. Not named `toggleSidebar(_:)`: NSSplitView and NSWindow
    /// implement that, and the split view sits between the editor and this controller in the
    /// responder chain, so it would take the menu item (and disable it).
    @objc func toggleFileTree(_ sender: Any?) {
        guard let side = sidebar?.view else { return }
        if split.isSubviewCollapsed(side) || side.frame.width < 1 {
            split.setPosition(240, ofDividerAt: 0)
        } else {
            split.setPosition(0, ofDividerAt: 0)
        }
    }

    // MARK: - Tabs

    /// How long the last file took to load (read, check encoding, build rope), for benchmarks.
    private(set) var lastLoadMs = 0.0

    /// Opens a file in a tab (or selects its tab). Returns nil if it couldn't be opened.
    @discardableResult
    func open(_ url: URL, select: Bool = true) -> EditorTab? {
        let url = url.standardizedFileURL
        if let i = tabs.firstIndex(where: { $0.document.fileURL?.standardizedFileURL == url }) {
            if select { selectTab(i) }
            return tabs[i]
        }
        do {
            let t0 = CACurrentMediaTime()
            let document = try Document(contentsOf: url)
            lastLoadMs = (CACurrentMediaTime() - t0) * 1000
            let tab = EditorTab(document: document)
            if let a = activeIndex, tabs[a].isUntouched {
                replaceTab(at: a, with: tab)
            } else {
                add(tab)
            }
            if select { selectTab(tabs.firstIndex { $0 === tab }!) }
            return tab
        } catch {
            presentSoon(error)
            return nil
        }
    }

    @objc func newTab(_ sender: Any?) {
        let tab = EditorTab(document: Document())
        add(tab)
        selectTab(tabs.count - 1)
    }

    private func add(_ tab: EditorTab) {
        let at = activeIndex.map { $0 + 1 } ?? tabs.count
        tabs.insert(tab, at: at)
        if let a = activeIndex, a >= at { activeIndex = a + 1 }
        watch(tab)
        updateTabBar()
        onSessionChange?()
    }

    private func replaceTab(at i: Int, with tab: EditorTab) {
        let old = tabs[i]
        old.view?.removeFromSuperview()
        old.document.close()
        history.removeAll { $0 == ObjectIdentifier(old) }
        tabs[i] = tab
        activeIndex = nil
        watch(tab)
    }

    private func watch(_ tab: EditorTab) {
        tab.document.buffer.addObserver(self) { [weak self] _ in self?.updateEditedState() }
        tab.document.onDiskChange = { [weak self, weak tab] in
            guard let self, let tab else { return }
            self.handleDiskChange(tab)
        }
    }

    func selectTab(_ i: Int) {
        guard tabs.indices.contains(i), let window else { return }
        let tab = tabs[i]
        if let a = activeIndex, a != i, tabs.indices.contains(a), let old = tabs[a].view {
            old.removeFromSuperview()
            old.statusBar = nil
        }
        let view = tab.view ?? makeView(for: tab)
        if view.superview !== editorHost {
            view.frame = editorHost.bounds
            editorHost.addSubview(view)
        }
        statusBar.editor = view
        view.statusBar = statusBar
        activeIndex = i
        history.removeAll { $0 == ObjectIdentifier(tab) }
        history.insert(ObjectIdentifier(tab), at: 0)
        if !quickOpen.isShown { window.makeFirstResponder(view) }
        updateTabBar()
        updateTitle()
        if let url = tab.document.fileURL { sidebar?.reveal(url) }
        onSessionChange?()
    }

    private func makeView(for tab: EditorTab) -> EditorView {
        let doc = tab.document
        if let c = tab.restoreCursor { doc.buffer.selection = Selection(min(max(c, 0), doc.buffer.rope.byteCount)) }
        let view = EditorView(frame: editorHost.bounds, buffer: doc.buffer)
        view.autoresizingMask = [.width, .height]
        view.indentation = doc.indentation
        view.syntaxLanguage = language(of: doc)
        view.editorFont = editorFont
        view.wrapsLines = wrapsLines
        view.vimSession = vimSession
        view.vimEnabled = vimEnabled
        view.vimFileHandler = { [weak self, weak tab] command in
            guard let self, let tab else { return nil }
            return self.runVimCommand(command, in: tab)
        }
        if let line = tab.restoreTopLine { view.scroll(toLine: line) }
        tab.restoreCursor = nil
        tab.restoreTopLine = nil
        tab.view = view
        return view
    }

    /// Closes a tab, asking about unsaved changes unless `force`. Returns false if cancelled.
    @discardableResult
    func closeTab(at i: Int, force: Bool = false) async -> Bool {
        guard tabs.indices.contains(i) else { return false }
        let tab = tabs[i]
        if !force && tab.document.isDirty {
            selectTab(i)
            guard await confirmClose(tab) else { return false }
        }
        guard let i = tabs.firstIndex(where: { $0 === tab }) else { return true }
        tab.view?.removeFromSuperview()
        tab.view?.statusBar = nil
        tab.document.close()
        tab.document.buffer.removeObserver(self)
        tabs.remove(at: i)
        history.removeAll { $0 == ObjectIdentifier(tab) }
        let wasActive = activeIndex == i
        if let a = activeIndex, a > i { activeIndex = a - 1 }
        if wasActive {
            activeIndex = nil
            statusBar.editor = nil
            if let next = history.first.flatMap({ id in tabs.firstIndex { ObjectIdentifier($0) == id } }) ?? (tabs.isEmpty ? nil : min(i, tabs.count - 1)) {
                selectTab(next)
            }
        }
        updateTabBar()
        updateTitle()
        updateEditedState()
        onSessionChange?()
        if tabs.isEmpty {
            if folder == nil { closeSoon() } else { window?.makeFirstResponder(sidebar?.outline) }
        }
        return true
    }

    /// ⌘W: closes the active tab; with no tabs left, the window.
    @objc func closeTab(_ sender: Any?) {
        guard let i = activeIndex else {
            window?.performClose(sender)
            return
        }
        Task { await closeTab(at: i) }
    }

    // Menu actions here need names AppKit doesn't use: NSWindow and NSSplitView sit between
    // the editor and this controller in the responder chain, and take actions they know
    // (`selectNextTab:`, `toggleSidebar:`) even when they then do nothing.
    @objc func showNextTab(_ sender: Any?) { cycleTabs(1) }
    @objc func showPreviousTab(_ sender: Any?) { cycleTabs(-1) }

    /// ⌘1–⌘9: the menu item's tag is the tab's number.
    @objc func showTabNumber(_ sender: Any?) {
        guard let n = (sender as? NSMenuItem)?.tag, tabs.indices.contains(n - 1) else { return NSSound.beep() }
        selectTab(n - 1)
    }

    private var commandKeyMonitor: Any?
    private var showNumbersSoon: Task<Void, Never>?

    /// Watches ⌘ in this window, to show the tabs' numbers while it's held.
    private func watchCommandKey() {
        commandKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown, .leftMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, event.window === self.window else { return }
                let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
                self.commandKeyChanged(heldAlone: event.type == .flagsChanged && modifiers == .command)
            }
            return event
        }
    }

    /// Holding ⌘ on its own for a moment shows each tab's number (for ⌘1–⌘9). Letting go,
    /// adding another modifier, typing or clicking hides them. The delay keeps them from
    /// flashing on every ⌘ shortcut.
    func commandKeyChanged(heldAlone: Bool) {
        showNumbersSoon?.cancel()
        showNumbersSoon = nil
        tabBar.showsNumbers = false
        guard heldAlone, tabs.count > 1 else { return }
        showNumbersSoon = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.tabBar.showsNumbers = true
        }
    }

    var showsTabNumbers: Bool { tabBar.showsNumbers }

    private func cycleTabs(_ delta: Int) {
        guard !tabs.isEmpty else { return }
        let i = ((activeIndex ?? 0) + delta) % tabs.count
        selectTab(i < 0 ? i + tabs.count : i)
    }

    private func updateTabBar() {
        tabBar.tabs = tabs.map { tab in
            TabBarView.Tab(title: tab.title, isDirty: tab.document.isDirty, toolTip: tab.document.fileURL.map { displayPath($0) })
        }
        tabBar.selectedIndex = activeIndex
    }

    /// A path relative to the folder when it's inside, else with `~` for the home folder.
    func displayPath(_ url: URL) -> String {
        if let folder, url.path.hasPrefix(folder.path + "/") { return String(url.path.dropFirst(folder.path.count + 1)) }
        return (url.path as NSString).abbreviatingWithTildeInPath
    }

    private func renamed(_ from: URL, _ to: URL) {
        // Tabs of renamed files keep their buffers; reopen under the new name when clean.
        for (i, tab) in tabs.enumerated() {
            guard let url = tab.document.fileURL, url.path == from.path || url.path.hasPrefix(from.path + "/") else { continue }
            let newURL = URL(fileURLWithPath: to.path + url.path.dropFirst(from.path.count))
            if !tab.document.isDirty, let doc = try? Document(contentsOf: newURL) {
                let wasActive = activeIndex == i
                let replacement = EditorTab(document: doc)
                replaceTab(at: i, with: replacement)
                if wasActive { selectTab(i) }
            }
        }
        updateTabBar()
    }

    // MARK: - Title and dirty state

    private func updateTitle() {
        guard let window else { return }
        let tab = activeTab
        window.title = tab?.title ?? folder?.lastPathComponent ?? "Vie"
        window.representedURL = tab?.document.fileURL
        var parts: [String] = []
        if let folder { parts.append(folder.lastPathComponent) }
        if let doc = tab?.document {
            if doc.format != .utf8 { parts.append(doc.format.description) }
            if doc.hadMixedLineEndings { parts.append("mixed line endings") }
        }
        window.subtitle = parts.joined(separator: " · ")
        updateEditedState()
    }

    /// Runs after every edit, so it only touches the window when something flips.
    private func updateEditedState() {
        let dirty = tabs.contains { $0.document.isDirty }
        if let window, window.isDocumentEdited != dirty { window.isDocumentEdited = dirty }
        let dots = tabs.map { $0.document.isDirty }
        if dots != tabBar.tabs.map(\.isDirty) { updateTabBar() }
    }

    // MARK: - Closing

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if closeConfirmed || !tabs.contains(where: { $0.document.isDirty }) { return true }
        Task {
            if await confirmCloseAll() {
                closeConfirmed = true
                window?.close()
            }
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        if let commandKeyMonitor { NSEvent.removeMonitor(commandKeyMonitor) }
        commandKeyMonitor = nil
        commandKeyChanged(heldAlone: false)
        tree?.stopWatching()
        for tab in tabs { tab.document.close() }
        onClose?(self)
    }

    /// Asks about each tab with unsaved changes. Returns false if any was cancelled.
    func confirmCloseAll() async -> Bool {
        for tab in tabs where tab.document.isDirty {
            if let i = tabs.firstIndex(where: { $0 === tab }) { selectTab(i) }
            guard await confirmClose(tab) else { return false }
        }
        return true
    }

    /// Asks whether to save a tab's changes. True when it's fine to close it.
    func confirmClose(_ tab: EditorTab) async -> Bool {
        guard tab.document.isDirty, let window else { return true }
        let alert = NSAlert()
        alert.messageText = "Do you want to save the changes you made to “\(tab.title)”?"
        alert.informativeText = "Your changes will be lost if you don’t save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let dontSave = alert.addButton(withTitle: "Don’t Save")
        dontSave.hasDestructiveAction = true
        dontSave.keyEquivalent = "d"
        dontSave.keyEquivalentModifierMask = .command
        switch await alert.beginSheetModal(for: window) {
        case .alertFirstButtonReturn: return await save(tab, as: false)
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }

    /// Closes after the current key is handled, never from inside it.
    private func closeSoon() {
        closeConfirmed = true
        DispatchQueue.main.async { [weak self] in self?.window?.close() }
    }

    // MARK: - Saving

    @objc func saveDocument(_ sender: Any?) {
        guard let tab = activeTab else { return }
        Task { await save(tab, as: false) }
    }

    @objc func saveDocumentAs(_ sender: Any?) {
        guard let tab = activeTab else { return }
        Task { await save(tab, as: true) }
    }

    @objc func revertDocumentToSaved(_ sender: Any?) {
        if let tab = activeTab { reload(tab) }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let doc = activeTab?.document
        switch item.action {
        case #selector(revertDocumentToSaved(_:)): return doc?.fileURL != nil && doc?.isDirty == true
        case #selector(saveDocument(_:)), #selector(saveDocumentAs(_:)): return doc.map { !$0.isSaving } ?? false
        case #selector(toggleFileTree(_:)):
            item.title = sidebarWidth == nil ? "Show Sidebar" : "Hide Sidebar"
            return sidebar != nil
        case #selector(showNextTab(_:)), #selector(showPreviousTab(_:)): return tabs.count > 1
        case #selector(showTabNumber(_:)): return tabs.indices.contains(item.tag - 1)
        default: return true
        }
    }

    /// Saves, asking for a location if the document is untitled (or for Save As). Returns
    /// false if the user cancelled or the save failed (the error has been shown).
    @discardableResult
    func save(_ tab: EditorTab, as saveAs: Bool) async -> Bool {
        let doc = tab.document
        guard let window, !doc.isSaving else { return false }
        var url = doc.fileURL
        if url == nil || saveAs {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = doc.fileURL?.lastPathComponent ?? "Untitled.txt"
            if let dir = doc.fileURL?.deletingLastPathComponent() ?? folder { panel.directoryURL = dir }
            guard await panel.beginSheetModal(for: window) == .OK, let chosen = panel.url else { return false }
            url = chosen
        }
        guard let url else { return false }
        do {
            try await doc.save(to: url)
        } catch TextFileError.unrepresentable(let encoding) {
            guard await askToSaveAsUTF8(doc, encoding) else { return false }
            do {
                try await doc.save(to: url, format: TextFormat(encoding: .utf8, lineEnding: doc.format.lineEnding))
            } catch {
                await present(error)
                return false
            }
        } catch {
            await present(error)
            return false
        }
        updateTitle()
        updateTabBar()
        tab.view?.syntaxLanguage = language(of: doc)
        return true
    }

    /// The document's language for highlighting, from its file name or `#!` line.
    private func language(of doc: Document) -> SyntaxLanguage? {
        guard let url = doc.fileURL else { return nil }
        let rope = doc.buffer.rope
        return SyntaxLanguage.forFile(named: url.lastPathComponent, firstLine: rope.string(in: 0..<min(rope.lineEnd(0), 200)))
    }

    private func askToSaveAsUTF8(_ doc: Document, _ encoding: String.Encoding) async -> Bool {
        guard let window else { return false }
        let name = String.localizedName(of: encoding)
        let alert = NSAlert()
        alert.messageText = "“\(doc.displayName)” can’t be saved as \(name)."
        alert.informativeText = "The text contains characters that \(name) can’t store. Save it as UTF-8 instead?"
        alert.addButton(withTitle: "Save as UTF-8")
        alert.addButton(withTitle: "Cancel")
        return await alert.beginSheetModal(for: window) == .alertFirstButtonReturn
    }

    private func present(_ error: Error) async {
        guard let window else { return }
        _ = await NSAlert(error: error).beginSheetModal(for: window)
    }

    private func presentSoon(_ error: Error) {
        Task { await present(error) }
    }

    // MARK: - Changes on disk

    /// ⌘-Tab away while ⌘ is held: the release goes to another app.
    func windowDidResignKey(_ notification: Notification) {
        commandKeyChanged(heldAlone: false)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        // A backstop for the file watcher: check whenever the user comes back to the window.
        for tab in tabs { handleDiskChange(tab) }
    }

    /// Reloads silently if there are no unsaved edits; otherwise asks.
    private func handleDiskChange(_ tab: EditorTab) {
        let doc = tab.document
        guard doc.checkDisk() == .changed else { return }
        if !doc.isDirty {
            reload(tab)
            return
        }
        guard !tab.diskAlertShowing, let window else { return }
        tab.diskAlertShowing = true
        if let i = tabs.firstIndex(where: { $0 === tab }) { selectTab(i) }
        let alert = NSAlert()
        alert.messageText = "“\(doc.displayName)” was changed by another app."
        alert.informativeText = "Reloading replaces your unsaved changes with the version on disk. You can get them back with Undo."
        alert.addButton(withTitle: "Keep My Version")
        alert.addButton(withTitle: "Reload")
        Task {
            let response = await alert.beginSheetModal(for: window)
            tab.diskAlertShowing = false
            if response == .alertSecondButtonReturn { reload(tab) }
        }
    }

    private func reload(_ tab: EditorTab) {
        do {
            try tab.document.reload()
            updateTitle()
            updateTabBar()
        } catch {
            presentSoon(error)
        }
    }

    // MARK: - Vim commands

    private static let notSaved = "E37: No write since last change (add ! to override)"

    /// `:w`, `:q`, `:e`, the buffer list and friends, for the tab whose engine asked. Saving is
    /// asynchronous, so success is reported later with a message.
    private func runVimCommand(_ command: VimFileCommand, in tab: EditorTab) -> String? {
        switch command {
        case .write(let path, _):
            Task { await write(tab, path) }
        case .quit(let force):
            if !force && tab.document.isDirty { return Self.notSaved }
            closeTabSoon(tab)
        case .writeQuit(let path, _):
            Task { if await write(tab, path) { closeTabSoon(tab) } }
        case .exit(let force):
            if tab.document.isDirty && !force {
                Task { if await write(tab, nil) { closeTabSoon(tab) } }
            } else {
                closeTabSoon(tab)
            }
        case .edit(let path, let force):
            if let path, !path.isEmpty {
                open(url(for: path, from: tab))
                return nil
            }
            guard tab.document.fileURL != nil else { return "E32: No file name" }
            if !force && tab.document.isDirty { return Self.notSaved }
            reload(tab)
        case .quitAll(let force):
            if !force, let dirty = tabs.first(where: { $0.document.isDirty }) {
                return "E37: No write since last change for “\(dirty.title)” (add ! to override)"
            }
            closeSoon()
        case .writeAll:
            Task { for t in tabs where t.document.isDirty { guard await write(t, nil) else { return } } }
        case .writeQuitAll:
            Task {
                for t in tabs where t.document.isDirty { guard await write(t, nil) else { return } }
                closeSoon()
            }
        case .toggleSidebar:
            guard sidebar != nil else { return "No folder open" }
            toggleFileTree(nil)
        case .listBuffers:
            tab.view?.vim?.showMessage(bufferList())
        case .buffer(let arg):
            return switchToBuffer(arg)
        case .nextBuffer(let count):
            cycleTabs(count)
        case .previousBuffer(let count):
            cycleTabs(-count)
        case .deleteBuffer(let force):
            if !force && tab.document.isDirty {
                let n = (tabs.firstIndex { $0 === tab } ?? 0) + 1
                return "E89: No write since last change for buffer \(n) (add ! to override)"
            }
            closeTabSoon(tab, force: true)
        }
        return nil
    }

    private func closeTabSoon(_ tab: EditorTab, force: Bool = true) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let i = self.tabs.firstIndex(where: { $0 === tab }) else { return }
            Task { await self.closeTab(at: i, force: force) }
        }
    }

    /// `:ls` on one line: number, `%` for the current buffer, `#` for the previous one, `+` if
    /// modified, then the name.
    private func bufferList() -> String {
        let previous = history.dropFirst().first
        return tabs.enumerated().map { i, t in
            var flags = i == activeIndex ? "%a" : (ObjectIdentifier(t) == previous ? "#" : "")
            if t.document.isDirty { flags += "+" }
            let name = t.document.fileURL.map { displayPath($0) } ?? "[No Name]"
            return "\(i + 1)\(flags.isEmpty ? "" : " " + flags) \"\(name)\""
        }.joined(separator: "   ")
    }

    private func switchToBuffer(_ arg: String) -> String? {
        let arg = arg.trimmingCharacters(in: .whitespaces)
        if arg.isEmpty { return nil }
        if let n = Int(arg) {
            guard tabs.indices.contains(n - 1) else { return "E86: Buffer \(n) does not exist" }
            selectTab(n - 1)
            return nil
        }
        let matches = tabs.indices.filter { i in
            let name = tabs[i].document.fileURL.map { displayPath($0) } ?? tabs[i].title
            return name.localizedCaseInsensitiveContains(arg)
        }
        if matches.count == 1 {
            selectTab(matches[0])
            return nil
        }
        let exact = matches.filter { tabs[$0].title == arg }
        if exact.count == 1 {
            selectTab(exact[0])
            return nil
        }
        return matches.isEmpty ? "E94: No matching buffer for \(arg)" : "E93: More than one match for \(arg)"
    }

    /// A path from the command line: `~` is the home folder; relative paths start in the
    /// document's folder, or the window's folder.
    private func url(for path: String, from tab: EditorTab) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return URL(fileURLWithPath: expanded).standardizedFileURL }
        let base = tab.document.fileURL?.deletingLastPathComponent() ?? folder ?? FileManager.default.homeDirectoryForCurrentUser
        return base.appendingPathComponent(expanded).standardizedFileURL
    }

    /// Saves (to `path` if given; a copy if the document already has another file), then shows
    /// Vim's "written" message.
    @discardableResult
    private func write(_ tab: EditorTab, _ path: String?) async -> Bool {
        let doc = tab.document
        let rope = doc.buffer.rope
        let summary = "\(rope.lineCount)L, \(rope.byteCount)B written"
        if let path, !path.isEmpty {
            let target = url(for: path, from: tab)
            if let current = doc.fileURL, target != current.standardizedFileURL {
                do {
                    try await doc.writeCopy(to: target)
                } catch {
                    await present(error)
                    return false
                }
                tab.view?.vim?.showMessage("\"\(target.lastPathComponent)\" \(summary)")
                return true
            }
            if doc.fileURL == nil {
                do {
                    try await doc.save(to: target)
                } catch {
                    await present(error)
                    return false
                }
                updateTitle()
                updateTabBar()
                tab.view?.syntaxLanguage = language(of: doc)
                tab.view?.vim?.showMessage("\"\(doc.displayName)\" \(summary)")
                return true
            }
        }
        guard await save(tab, as: false) else { return false }
        tab.view?.vim?.showMessage("\"\(doc.displayName)\" \(summary)")
        return true
    }

    // MARK: - Quick open

    @objc func openQuickly(_ sender: Any?) {
        if quickOpen.isShown { return quickOpen.dismiss() }
        quickOpen.index = index
        quickOpen.recent = history.compactMap { id in tabs.first { ObjectIdentifier($0) == id } }
            .compactMap { $0.document.fileURL.map { displayPath($0) } }
        quickOpen.show(in: column)
    }

    private func openQuickOpenResult(_ path: String) {
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { open(URL(fileURLWithPath: expanded)) }
        else if let folder { open(folder.appendingPathComponent(path)) }
    }

    /// Builds the ⌘P index in the background (again after files change).
    private func rebuildIndex() {
        guard let folder else { return }
        indexGeneration += 1
        let generation = indexGeneration
        Task.detached(priority: .utility) {
            let context = IgnoreContext(folder: folder)
            let index = FuzzyIndex(paths: PathScanner.scan(context, folder: folder))
            await MainActor.run { [weak self] in
                guard let self, generation == self.indexGeneration else { return }
                self.index = index
                if self.quickOpen.isShown { self.quickOpen.index = index }
            }
        }
    }

    private func foldersChanged(_ folders: [String], rescan: Bool) {
        guard rescan || folders.contains(where: affectsIndex) else { return }
        indexRebuild?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.rebuildIndex() }
        indexRebuild = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    /// Changes inside `.git` or under a folder already known to be ignored don't change the index.
    private func affectsIndex(_ path: String) -> Bool {
        guard let tree else { return false }
        let root = tree.root.url.path
        guard path == root || path.hasPrefix(root + "/") else { return false }
        let parts = path.dropFirst(root.count).split(separator: "/")
        if parts.first == ".git" { return false }
        var node = tree.root
        for part in parts {
            guard let next = node.children?.first(where: { $0.name == part }) else { break }
            if next.isIgnored { return false }
            node = next
        }
        return true
    }

    // MARK: - Session

    func state() -> SessionState.Window {
        let tabsState = tabs.compactMap { tab -> SessionState.Tab? in
            guard let url = tab.document.fileURL else { return nil }
            let cursor = tab.view?.vim?.cursor ?? tab.document.buffer.selection.head
            let top = tab.view?.visibleLines.lowerBound ?? tab.restoreTopLine ?? 0
            return SessionState.Tab(path: url.path, cursor: cursor, topLine: top)
        }
        let activePath = activeTab?.document.fileURL?.path
        return SessionState.Window(
            folder: folder?.path,
            frame: window.map { NSStringFromRect($0.frame) },
            sidebarWidth: sidebarWidth.map(Double.init),
            tabs: tabsState,
            active: activePath.flatMap { p in tabsState.firstIndex { $0.path == p } },
            expanded: sidebar?.expandedPaths ?? [])
    }

    func restore(_ state: SessionState.Window) {
        if let frame = state.frame { window?.setFrame(NSRectFromString(frame), display: false) }
        setSidebar(width: state.sidebarWidth.map { CGFloat($0) })
        sidebar?.expand(paths: state.expanded)
        for t in state.tabs {
            guard FileManager.default.fileExists(atPath: t.path),
                  let tab = open(URL(fileURLWithPath: t.path), select: false) else { continue }
            tab.restoreCursor = t.cursor
            tab.restoreTopLine = t.topLine
        }
        if let a = state.active, tabs.indices.contains(a) { selectTab(a) } else if !tabs.isEmpty { selectTab(0) }
    }
}

/// The editor area when no tab is open.
final class EmptyEditorView: NSView {
    override var isFlipped: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        EditorView.backgroundColor(for: effectiveAppearance).setFill()
        bounds.fill()
        guard subviews.isEmpty else { return }
        let text = "⌘P  Open File       ⌘O  Open…       ⌘T  New Tab"
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.tertiaryLabelColor]
        let size = text.size(withAttributes: attrs)
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attrs)
    }

    override func didAddSubview(_ subview: NSView) { needsDisplay = true }
    override func willRemoveSubview(_ subview: NSView) { needsDisplay = true }
}

/// What's restored at launch: each window's folder, frame, sidebar and tabs.
struct SessionState: Codable {
    struct Tab: Codable {
        var path: String
        var cursor: Int
        var topLine: Int
    }

    struct Window: Codable {
        var folder: String?
        var frame: String?
        var sidebarWidth: Double?
        var tabs: [Tab]
        var active: Int?
        var expanded: [String]
    }

    var windows: [Window]

    static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Vie")
        return dir.appendingPathComponent("session.json")
    }

    static func load() -> SessionState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SessionState.self, from: data)
    }

    func save() {
        do {
            try FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(self).write(to: Self.url, options: .atomic)
        } catch {
            NSLog("Vie: couldn't save the session: \(error.localizedDescription)")
        }
    }
}
