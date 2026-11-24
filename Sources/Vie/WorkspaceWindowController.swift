import AppKit
import Quartz
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
    /// A language picked by hand, from the session ("" for plain text).
    var restoreLanguage: String?
    var diskAlertShowing = false
    /// Unsaved text came back after a crash, but its file changed or went meanwhile: said
    /// when the tab is first shown.
    var recoveryWarning: Recovery.Change?

    init(document: Document) { self.document = document }

    var title: String { document.displayName }

    /// An empty untitled buffer nobody has typed into, which opening a file may replace.
    var isUntouched: Bool {
        document.fileURL == nil && !document.buffer.canUndo && document.buffer.rope.isEmpty
    }
}

/// A window: a folder's tree in the sidebar, a tab per open buffer, the editor, and the status
/// bar. A window of loose files has no folder; its sidebar, when shown, has the current file's
/// project and follows it from tab to tab.
@MainActor
final class WorkspaceWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation, NSSplitViewDelegate {
    /// The folder, or nil for a window of loose files.
    let folder: URL?
    /// The tree in the sidebar: the folder's, or in a window of loose files the current file's
    /// project's (once the sidebar is shown).
    private(set) var tree: FileTree?
    private(set) var tabs: [EditorTab] = []
    private(set) var activeIndex: Int?
    /// Tabs in the order they were last active, most recent first.
    private var history: [ObjectIdentifier] = []
    /// Files whose tabs were closed, most recently closed first, with where each tab was: ⌘P
    /// lists them after the open files, and opening one again goes back to its place.
    private(set) var closedFiles: [SessionState.Tab] = []
    private static let closedLimit = 50

    var onClose: ((WorkspaceWindowController) -> Void)?
    /// Something worth saving in the session changed (tabs opened, closed or switched).
    var onSessionChange: (() -> Void)?
    /// A file was saved under a name just chosen (Save As, or naming an untitled tab).
    var onSaveAs: ((URL) -> Void)?
    /// A file or folder was renamed or moved in this window's tree. The app passes it to every
    /// window (`renamed`), so tabs follow wherever the file is open; without it, this window's do.
    var onFileMoved: ((URL, URL) -> Void)?

    let vimSession: VimSession
    /// Keeps copies of unsaved text for after a crash (none in tests and benchmarks).
    let recovery: Recovery?
    var vimEnabled: Bool {
        didSet {
            for tab in tabs { tab.view?.vimEnabled = vimEnabled }
            statusBar.vimSwitch = vimEnabled
            sidebar?.vimKeys = vimEnabled
            outlineSection.vimKeys = vimEnabled
        }
    }
    var wrapsLines: Bool {
        didSet { for tab in tabs { tab.view?.wrapsLines = wrapsLines } }
    }
    var editorFont: EditorFont {
        didSet { for tab in tabs { tab.view?.editorFont = editorFont } }
    }

    private let split = NSSplitView()
    private(set) var sidebar: FileTreeController?
    /// The sidebar, left of the editor: the tree, and under it the current Markdown file's
    /// Outline, in a split of their own.
    private let sidebarBox = NSView()
    private let sidebarSplit = NSSplitView()
    let outlineSection = OutlineController()
    private let column = NSView()
    private let tabBar: TabBarView
    private let editorHost = EmptyEditorView()
    let statusBar: StatusBarView
    /// Between the tab bar and the text while shown (⌘F); searches the current tab.
    let findBar = FindBar(frame: .zero)
    /// The ⌘P panel, made on first use: its field and list cost ~4 ms that opening a window
    /// (and launching) shouldn't pay.
    private(set) var madeQuickOpen: QuickOpenController?
    private var quickOpen: QuickOpenController {
        if let made = madeQuickOpen { return made }
        let panel = QuickOpenController()
        panel.topInset = TabBarView.height
        panel.onOpen = { [weak self] path in self?.openQuickOpenResult(path) }
        panel.onDismiss = { [weak self] in
            guard let self, let view = self.activeView else { return }
            self.window?.makeFirstResponder(view)
        }
        madeQuickOpen = panel
        return panel
    }
    private var quickOpenIsShown: Bool { madeQuickOpen?.isShown == true }
    private var index: FuzzyIndex?
    private var indexGeneration = 0
    private var indexRebuild: DispatchWorkItem?
    /// In a window of loose files, the expanded folders and ⌘P index of each project shown
    /// before, so switching back finds it as it was.
    private var expandedByProject: [String: [String]] = [:]
    private var indexByProject: [String: FuzzyIndex] = [:]
    private var closeConfirmed = false

    var activeTab: EditorTab? { activeIndex.map { tabs[$0] } }
    /// The ⌘P index has been built.
    var isIndexReady: Bool { index != nil }
    /// Types into the ⌘P field (for tests and snapshots).
    func quickOpenType(_ text: String) { quickOpen.type(text) }
    var activeView: EditorView? { activeTab?.view }

    init(folder: URL?, size: NSSize, vimEnabled: Bool, vimSession: VimSession, wrapsLines: Bool = true,
         font: EditorFont = EditorFont(), recovery: Recovery? = nil) {
        self.folder = folder?.standardizedFileURL.resolvingSymlinksInPath()
        tree = self.folder.map { FileTree(folder: $0) }
        self.vimEnabled = vimEnabled
        self.vimSession = vimSession
        self.recovery = recovery
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
        statusBar.vimSwitch = vimEnabled
        super.init(window: window)
        window.delegate = self
        buildViews(size: size)
        // Once the window is up, so the file-system work doesn't compete with the first frame.
        if let tree { watch(tree, after: 0.2) }
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

        sidebarSplit.isVertical = false
        sidebarSplit.dividerStyle = .thin
        sidebarSplit.delegate = self
        sidebarSplit.frame = sidebarBox.bounds
        sidebarSplit.autoresizingMask = [.width, .height]
        sidebarBox.addSubview(sidebarSplit)
        outlineSection.vimKeys = vimEnabled
        outlineSection.onLeave = { [weak self] in self?.focusEditor() }
        outlineSection.onAvailabilityChange = { [weak self] in self?.updateOutlineSection() }

        column.frame = NSRect(origin: .zero, size: size)
        let barH = StatusBarView.height, tabH = TabBarView.height
        statusBar.frame = NSRect(x: 0, y: 0, width: size.width, height: barH)
        statusBar.autoresizingMask = [.width, .maxYMargin]
        tabBar.frame = NSRect(x: 0, y: size.height - tabH, width: size.width, height: tabH)
        tabBar.autoresizingMask = [.width, .minYMargin]
        editorHost.frame = NSRect(x: 0, y: barH, width: size.width, height: size.height - barH - tabH)
        editorHost.autoresizingMask = [.width, .height]
        findBar.autoresizingMask = [.width, .minYMargin]
        column.addSubview(editorHost)
        column.addSubview(findBar)
        column.addSubview(tabBar)
        column.addSubview(statusBar)
        findBar.onResize = { [weak self] in self?.layoutFindBar() }
        findBar.onClose = { [weak self] in self?.closeFindBar() }
        tabBar.onSelect = { [weak self] i in self?.selectTab(i) }
        tabBar.onClose = { [weak self] i in
            guard let self else { return }
            Task { await self.closeTab(at: i) }
        }
        tabBar.onNewTab = { [weak self] in self?.newTab(nil) }
        tabBar.onMove = { [weak self] from, to in self?.moveTab(from: from, to: to) }
        tabBar.onDrop = { [weak self] windowNumber, i, to in
            guard let self, let source = NSApp.window(withWindowNumber: windowNumber)?.windowController as? WorkspaceWindowController else { return }
            self.takeTab(at: i, from: source, to: to)
        }
        statusBar.fileFormatMenu = { [weak self] in self?.fileFormatMenu() }
        watchCommandKey()

        split.addSubview(column)
        if let tree { addSidebar(tree) } else { split.adjustSubviews() }
        window.contentView = split
    }

    /// The tree, left of the editor.
    private func addSidebar(_ tree: FileTree, width: CGFloat = 240) {
        let side = FileTreeController(tree: tree)
        side.onOpen = { [weak self] url in self?.open(url) }
        side.onPreview = { [weak self] urls in self?.preview(urls) }
        side.onSelectionChange = { [weak self] in self?.previewFollowsSelection() }
        side.onError = { [weak self] error in self?.presentSoon(error) }
        side.onRename = { [weak self] from, to in
            guard let self else { return }
            if let onFileMoved { onFileMoved(from, to) } else { renamed(from, to) }
        }
        side.onLeave = { [weak self] in self?.focusEditor() }
        side.onToggleSidebar = { [weak self] in _ = self?.toggleSidebar(focus: true) }
        side.vimKeys = vimEnabled
        sidebar = side
        let height = split.bounds.height
        let outlineHeight = outlineSection.view.superview === sidebarSplit ? outlineSection.view.frame.height : nil
        side.view.frame = NSRect(x: 0, y: 0, width: width, height: height)
        sidebarSplit.addSubview(side.view, positioned: .below, relativeTo: nil) // the tree on top
        if sidebarBox.superview == nil {
            sidebarBox.frame = NSRect(x: 0, y: 0, width: width, height: height)
            split.addSubview(sidebarBox, positioned: .below, relativeTo: column)
        }
        split.adjustSubviews()
        split.setPosition(width, ofDividerAt: 0)
        sidebarSplit.adjustSubviews()
        if let outlineHeight { sidebarSplit.setPosition(sidebarSplit.bounds.height - outlineHeight, ofDividerAt: 0) }
        updateOutlineSection()
    }

    /// Shows the Outline under the tree while the current file is Markdown (and there is a
    /// tree), with the lower 40% of the sidebar; hides it otherwise.
    private func updateOutlineSection() {
        let wanted = outlineSection.isAvailable && sidebar != nil
        let shown = outlineSection.view.superview === sidebarSplit
        guard wanted != shown else { return }
        if wanted {
            let height = sidebarSplit.bounds.height
            outlineSection.view.frame = NSRect(x: 0, y: 0, width: sidebarSplit.bounds.width, height: round(height * 0.4))
            sidebarSplit.addSubview(outlineSection.view)
            sidebarSplit.adjustSubviews()
            sidebarSplit.setPosition(round(height * 0.6), ofDividerAt: 0)
        } else {
            if window?.firstResponder === outlineSection.outline { focusEditor() }
            outlineSection.view.removeFromSuperview()
            sidebarSplit.adjustSubviews()
        }
    }

    /// Follows changes in the folder and builds the ⌘P index, starting after `delay` seconds.
    private func watch(_ tree: FileTree, after delay: Double) {
        tree.onEvents = { [weak self] folders, rescan in self?.foldersChanged(folders, rescan: rescan) }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.window?.isVisible == true || self.window != nil else { return }
            tree.startWatching()
            self.rebuildIndex()
        }
    }

    /// The current file's project: the git repository holding it, else its folder.
    private var activeProject: URL? {
        guard let file = activeTab?.document.fileURL else { return nil }
        let dir = file.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
        return IgnoreContext.repository(containing: dir) ?? dir
    }

    /// In a window of loose files, puts the current file's project in the sidebar in place of
    /// the one there, `width` wide. The tree stays when the file has no project (untitled).
    private func followActiveProject(width: CGFloat) {
        guard folder == nil, let project = activeProject, project.path != tree?.root.url.path else { return }
        if let old = tree, let side = sidebar {
            expandedByProject[old.root.url.path] = side.expandedPaths
            if let index { indexByProject[old.root.url.path] = index }
            old.onEvents = nil
            old.stopWatching()
            side.view.removeFromSuperview()
            window?.undoManager?.removeAllActions(withTarget: side) // its renames and moves can't be undone from here
        }
        indexGeneration += 1 // an index still being built for the old project is dropped
        indexRebuild?.cancel()
        let new = FileTree(folder: project)
        tree = new
        addSidebar(new, width: width)
        sidebar?.expand(paths: expandedByProject[new.root.url.path] ?? [])
        index = indexByProject[new.root.url.path]
        watch(new, after: 0)
    }

    /// Selects the current file in the tree, or nothing when it isn't there.
    private func revealActiveFile() {
        if let url = activeTab?.document.fileURL { sidebar?.reveal(url) } else { sidebar?.clearSelection() }
    }

    // MARK: - Split view

    // The window's split (sidebar | editor) and the sidebar's (tree over Outline) share these.

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposed: CGFloat, ofSubviewAt index: Int) -> CGFloat {
        max(proposed, splitView === sidebarSplit ? 80 : 140)
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposed: CGFloat, ofSubviewAt index: Int) -> CGFloat {
        splitView === sidebarSplit ? min(proposed, splitView.bounds.height - 80) : min(proposed, splitView.bounds.width - 300)
    }

    func splitView(_ splitView: NSSplitView, shouldAdjustSizeOfSubview view: NSView) -> Bool {
        splitView === sidebarSplit || view !== sidebarBox // the sidebar keeps its width when the window resizes
    }

    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
        splitView === split && subview === sidebarBox
    }

    private var sidebarShown: Bool {
        guard sidebar != nil, sidebarBox.superview === split else { return false }
        return !split.isSubviewCollapsed(sidebarBox) && sidebarBox.frame.width >= 1
    }

    var sidebarWidth: CGFloat? { sidebarShown ? sidebarBox.frame.width : nil }

    func setSidebar(width: CGFloat?) {
        guard sidebar != nil else { return }
        if let width { split.setPosition(width, ofDividerAt: 0) } else { split.setPosition(0, ofDividerAt: 0) }
    }

    /// View ▸ Hide/Show Sidebar (and Space e). Not named `toggleSidebar(_:)`: NSSplitView and
    /// NSWindow implement that, and the split view sits between the editor and this controller
    /// in the responder chain, so it would take the menu item (and disable it).
    @objc func toggleFileTree(_ sender: Any?) { _ = toggleSidebar(focus: false) }

    /// Hides the sidebar (back to the editor if the tree had the keyboard), or shows it: in a
    /// window of loose files, with the current file's project; with `focus` (Space e), with
    /// the keyboard in the tree, as LazyVim does. Returns a message when there's no tree.
    private func toggleSidebar(focus: Bool) -> String? {
        if sidebarShown {
            let treeHadFocus = window?.firstResponder === sidebar?.outline || window?.firstResponder === outlineSection.outline
            split.setPosition(0, ofDividerAt: 0)
            if treeHadFocus { focusEditor() }
        } else {
            followActiveProject(width: 240)
            guard sidebar != nil else { return "No folder open: File ▸ Open… (⌘O) opens one" }
            split.setPosition(240, ofDividerAt: 0)
            revealActiveFile()
            if focus { focusTree() }
        }
        updateTitle()
        return nil
    }

    /// The keyboard to the tree, on the current file (else the first row), if it's showing.
    private func focusTree() {
        guard sidebarShown, let outline = sidebar?.outline else { return }
        if outline.selectedRow < 0, outline.numberOfRows > 0 { outline.selectRowIndexes([0], byExtendingSelection: false) }
        window?.makeFirstResponder(outline)
    }

    /// The keyboard back to the editor (Esc or ⌃L in the tree).
    private func focusEditor() {
        window?.makeFirstResponder(activeView)
    }

    // MARK: - Tabs

    /// How long the last file took to load (read, check encoding, build rope), for benchmarks.
    private(set) var lastLoadMs = 0.0

    /// Opens a file in a tab (or selects its tab). Returns nil if it couldn't be opened.
    @discardableResult
    func open(_ url: URL, select: Bool = true) -> EditorTab? {
        let url = url.standardizedFileURL
        if let i = tabIndex(for: url) {
            if select { selectTab(i) }
            return tabs[i]
        }
        // Not text (an image, a PDF): Quick Look shows it instead of a tab.
        if TextFile.looksBinary(at: url) {
            if select { preview([url]) }
            return nil
        }
        do {
            let t0 = CACurrentMediaTime()
            let document = try Document(contentsOf: url)
            lastLoadMs = (CACurrentMediaTime() - t0) * 1000
            let tab = EditorTab(document: document)
            if let k = closedFiles.firstIndex(where: { $0.path == url.path }) {
                let place = closedFiles.remove(at: k)
                tab.restoreCursor = place.cursor
                tab.restoreTopLine = place.topLine
                tab.restoreLanguage = place.language
            }
            if let a = activeIndex, tabs[a].isUntouched {
                replaceTab(at: a, with: tab)
            } else {
                add(tab)
            }
            if select { selectTab(tabs.firstIndex { $0 === tab }!) }
            return tab
        } catch TextFileError.binary { // binary past the part `looksBinary` reads
            if select { preview([url]) }
            return nil
        } catch {
            presentSoon(error)
            return nil
        }
    }

    /// The tab of a file, if it's open in this window.
    func tabIndex(for url: URL) -> Int? {
        let url = url.standardizedFileURL
        return tabs.firstIndex { $0.document.fileURL?.standardizedFileURL == url }
    }

    @objc func newTab(_ sender: Any?) {
        let tab = EditorTab(document: Document())
        add(tab)
        // Next to the current tab, which isn't always the last.
        selectTab(tabs.firstIndex { $0 === tab }!)
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
        recovery?.untrack(old.document)
        history.removeAll { $0 == ObjectIdentifier(old) }
        tabs[i] = tab
        if activeIndex == i { activeIndex = nil }
        watch(tab)
    }

    private func watch(_ tab: EditorTab) {
        tab.document.buffer.addObserver(self) { [weak self] _ in self?.updateEditedState() }
        recovery?.track(tab.document)
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
        findBar.editor = view
        outlineSection.editor = view
        activeIndex = i
        history.removeAll { $0 == ObjectIdentifier(tab) }
        history.insert(ObjectIdentifier(tab), at: 0)
        if !quickOpenIsShown { window.makeFirstResponder(view) }
        if folder == nil, let width = sidebarWidth { followActiveProject(width: width) }
        updateTabBar()
        updateTitle()
        revealActiveFile()
        onSessionChange?()
        if tab.recoveryWarning != nil { warnAboutRecoverySoon(tab) }
    }

    private func makeView(for tab: EditorTab) -> EditorView {
        let doc = tab.document
        if let c = tab.restoreCursor { doc.buffer.selection = Selection(min(max(c, 0), doc.buffer.rope.byteCount)) }
        let view = EditorView(frame: editorHost.bounds, buffer: doc.buffer)
        view.autoresizingMask = [.width, .height]
        view.indentation = doc.indentation
        if let name = tab.restoreLanguage, name.isEmpty || SyntaxLanguage.named(name) != nil {
            view.chooseLanguage(name.isEmpty ? nil : SyntaxLanguage.named(name))
        } else {
            view.syntaxLanguage = language(of: doc)
        }
        tab.restoreLanguage = nil
        configure(view, for: tab)
        if let line = tab.restoreTopLine { view.scroll(toLine: line) }
        tab.restoreCursor = nil
        tab.restoreTopLine = nil
        tab.view = view
        return view
    }

    /// The window's settings for an editor, and where its Vim file commands go (again when
    /// its tab comes from another window).
    private func configure(_ view: EditorView, for tab: EditorTab) {
        view.editorFont = editorFont
        view.wrapsLines = wrapsLines
        view.vimSession = vimSession
        view.vimEnabled = vimEnabled
        view.vimFileHandler = { [weak self, weak tab] command in
            guard let self, let tab else { return nil }
            return self.runVimCommand(command, in: tab)
        }
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
        noteClosed(tab)
        tab.document.close()
        recovery?.untrack(tab.document)
        removeTab(at: i)
        return true
    }

    /// Takes a tab out of the window (closed, or moved to another window) and shows the tab
    /// used before it. A window of loose files closes with its last tab.
    private func removeTab(at i: Int) {
        let tab = tabs[i]
        tab.view?.removeFromSuperview()
        tab.view?.statusBar = nil
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
            } else {
                findBar.editor = nil
                findBar.hide()
                outlineSection.editor = nil
            }
        }
        updateTabBar()
        updateTitle()
        updateEditedState()
        onSessionChange?()
        if tabs.isEmpty {
            if folder == nil { closeSoon() } else { window?.makeFirstResponder(sidebar?.outline) }
        }
    }

    // MARK: - Moving tabs

    /// Moves a tab to another place in the tab bar; `to` is its index afterwards.
    func moveTab(from: Int, to: Int) {
        guard tabs.indices.contains(from), from != to else { return }
        let active = activeTab
        let tab = tabs.remove(at: from)
        tabs.insert(tab, at: min(max(to, 0), tabs.count))
        activeIndex = active.flatMap { a in tabs.firstIndex { $0 === a } }
        updateTabBar()
        onSessionChange?()
    }

    /// Moves a tab from another window to `index` here, with its unsaved changes, undo history
    /// and place, and shows it. If its file is already open here, that tab is shown instead.
    func takeTab(at i: Int, from source: WorkspaceWindowController, to index: Int) {
        guard source !== self, source.tabs.indices.contains(i) else { return }
        let tab = source.tabs[i]
        if let url = tab.document.fileURL, let existing = tabIndex(for: url) {
            NSSound.beep()
            selectTab(existing)
            return
        }
        source.removeTab(at: i)
        let at = min(max(index, 0), tabs.count)
        tabs.insert(tab, at: at)
        if let a = activeIndex, a >= at { activeIndex = a + 1 }
        watch(tab)
        if let view = tab.view { configure(view, for: tab) }
        window?.makeKeyAndOrderFront(nil)
        selectTab(at)
    }

    /// Puts a closed tab's file first among the closed files.
    private func noteClosed(_ tab: EditorTab) {
        guard let url = tab.document.fileURL else { return }
        var place = sessionTab(tab)
        place.path = url.standardizedFileURL.path
        closedFiles.removeAll { $0.path == place.path }
        closedFiles.insert(place, at: 0)
        if closedFiles.count > Self.closedLimit { closedFiles.removeLast(closedFiles.count - Self.closedLimit) }
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

    /// A file or folder was renamed in the sidebar: tabs of the files in it follow, keeping
    /// their text, unsaved changes and place, so later saves go to the new name.
    func renamed(_ from: URL, _ to: URL) {
        var moved = false
        for tab in tabs {
            guard let url = tab.document.fileURL, url.path == from.path || url.path.hasPrefix(from.path + "/") else { continue }
            tab.document.moved(to: URL(fileURLWithPath: to.path + url.path.dropFirst(from.path.count)))
            detectLanguage(tab)
            recovery?.refresh(tab.document)
            moved = true
        }
        var movedClosed = false
        for k in closedFiles.indices {
            guard let path = closedFiles[k].path, path == from.path || path.hasPrefix(from.path + "/") else { continue }
            closedFiles[k].path = to.path + path.dropFirst(from.path.count)
            movedClosed = true
        }
        guard moved || movedClosed else { return }
        if moved {
            updateTabBar()
            updateTitle()
        }
        onSessionChange?()
    }

    // MARK: - Title and dirty state

    private func updateTitle() {
        guard let window else { return }
        let tab = activeTab
        // The folder, or the project in a window of loose files while its tree is showing.
        let shown = folder ?? (sidebarShown ? tree?.root.url : nil)
        window.title = tab?.title ?? shown?.lastPathComponent ?? "Vie"
        window.representedURL = tab?.document.fileURL
        window.subtitle = shown?.lastPathComponent ?? ""
        updateFileFormat()
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
        if closeConfirmed || (sidebar?.isBusy != true && !tabs.contains(where: { $0.document.isDirty })) { return true }
        Task {
            if await confirmStopTransfers(), await confirmCloseAll() {
                closeConfirmed = true
                window?.close()
            }
        }
        return false
    }

    /// While the tree copies or moves something, asks whether to stop it, and stops it. True
    /// when nothing is running (any more). If it all finishes while the question is up, the
    /// question goes by itself: there's nothing left to stop, so the closing goes on.
    func confirmStopTransfers() async -> Bool {
        guard let sidebar, let transfer = sidebar.transfers.first, let window else { return true }
        let alert = NSAlert()
        let doing = sidebar.describe(transfer)
        alert.messageText = "Stop \(doing.prefix(1).lowercased() + doing.dropFirst())?"
        alert.informativeText = transfer.kind == .move
            ? "It isn’t finished. Stopping removes what was copied so far; the originals stay where they are."
            : "It isn’t finished. Stopping removes what was copied so far."
        alert.addButton(withTitle: "Stop")
        alert.addButton(withTitle: "Cancel")
        Task { [weak sidebar, weak alert, weak window] in
            await sidebar?.finishTransfers()
            guard let alert, let window, window.attachedSheet === alert.window else { return }
            window.endSheet(alert.window, returnCode: .alertFirstButtonReturn)
        }
        guard await alert.beginSheetModal(for: window) == .alertFirstButtonReturn else { return false }
        await sidebar.stopTransfers()
        return true
    }

    func windowWillClose(_ notification: Notification) {
        if let commandKeyMonitor { NSEvent.removeMonitor(commandKeyMonitor) }
        commandKeyMonitor = nil
        commandKeyChanged(heldAlone: false)
        tree?.stopWatching()
        for tab in tabs {
            tab.document.close()
            recovery?.untrack(tab.document)
        }
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
            return sidebar != nil || doc?.fileURL != nil // with no tree yet, it shows the file's project
        case #selector(showNextTab(_:)), #selector(showPreviousTab(_:)): return tabs.count > 1
        case #selector(showTabNumber(_:)): return tabs.indices.contains(item.tag - 1)
        case #selector(showFindBar(_:)), #selector(showFindAndReplace(_:)), #selector(findNextMatch(_:)),
             #selector(findPreviousMatch(_:)):
            return activeView != nil
        case #selector(useSelectionForFind(_:)): return activeView?.selection.isEmpty == false
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
        var format: TextFormat?
        let asks = url == nil || saveAs
        if asks {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = doc.fileURL?.lastPathComponent ?? "Untitled.txt"
            if let dir = doc.fileURL?.deletingLastPathComponent() ?? folder { panel.directoryURL = dir }
            let chooser = FormatChooser(doc.format)
            panel.accessoryView = chooser.view
            guard await panel.beginSheetModal(for: window) == .OK, let chosen = panel.url else { return false }
            url = chosen
            format = chooser.format
        }
        guard let url else { return false }
        do {
            try await doc.save(to: url, format: format)
        } catch TextFileError.unrepresentable(let encoding) {
            guard await askToSaveAsUTF8(doc, encoding) else { return false }
            do {
                try await doc.save(to: url, format: TextFormat(encoding: .utf8, lineEnding: (format ?? doc.format).lineEnding))
            } catch {
                await present(error)
                return false
            }
        } catch {
            await present(error)
            return false
        }
        saved(tab)
        if asks { onSaveAs?(url) }
        return true
    }

    /// After a save: the title, tab and language may follow a new name, the copy of the
    /// unsaved text can go, and the session should know the new name.
    private func saved(_ tab: EditorTab) {
        updateTitle()
        updateTabBar()
        detectLanguage(tab)
        recovery?.refresh(tab.document)
        onSessionChange?()
    }

    /// After a save (a new name may mean a new language), unless one was picked by hand.
    private func detectLanguage(_ tab: EditorTab) {
        guard let view = tab.view, !view.languageIsChosen else { return }
        view.syntaxLanguage = language(of: tab.document)
    }

    /// The document's language for highlighting, from its file name or `#!` line.
    private func language(of doc: Document) -> SyntaxLanguage? {
        guard let url = doc.fileURL else { return nil }
        let rope = doc.buffer.rope
        return SyntaxLanguage.forFile(named: url.lastPathComponent, firstLine: rope.string(in: 0..<min(rope.lineEnd(0), 200)))
    }

    private func askToSaveAsUTF8(_ doc: Document, _ encoding: String.Encoding) async -> Bool {
        guard let window else { return false }
        let name = TextFormat(encoding: encoding).encodingName
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

    // MARK: - Quick Look

    /// The files Quick Look shows for this window.
    private(set) var previewItems: [URL] = []
    /// The window that last showed files in Quick Look: only it takes the panel, so another
    /// window that showed some earlier doesn't bring its old files back.
    private static weak var previewOwner: WorkspaceWindowController?
    /// This window gives the Quick Look panel its files (between begin and end of control).
    private var controlsPreview = false

    /// Shows the files in Quick Look, or shows them instead of what it was showing.
    func preview(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        previewItems = urls
        Self.previewOwner = self
        showPreview()
    }

    /// Opens the Quick Look panel, or reloads it when it's already open; tests replace it.
    var showPreview: () -> Void = {
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible {
            panel.updateController()
            panel.reloadData()
            panel.currentPreviewItemIndex = 0
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    /// Whether the Quick Look panel is showing this window's files.
    private var isPreviewing: Bool {
        controlsPreview && QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible
    }

    /// While Quick Look shows this window's files, moving in the tree shows what's selected,
    /// as in Finder.
    private func previewFollowsSelection() {
        guard isPreviewing, let urls = sidebar?.selectedNodes.map(\.url), !urls.isEmpty, urls != previewItems else { return }
        previewItems = urls
        QLPreviewPanel.shared().reloadData()
    }

    // The panel asks these on the main thread (they're NSObject's, so not marked main actor).
    nonisolated override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        MainActor.assumeIsolated { Self.previewOwner === self && !previewItems.isEmpty }
    }

    nonisolated override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            controlsPreview = true
            panel.dataSource = self
            panel.delegate = self
        }
    }

    nonisolated override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { controlsPreview = false }
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
        recovery?.refresh(doc) // the copy says which version of the file the text is based on
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

    /// Re-reads the tab's file (as `encoding`, if given), showing any error in an alert.
    private func reload(_ tab: EditorTab, as encoding: String.Encoding? = nil) {
        do {
            try reloadOrThrow(tab, as: encoding)
        } catch {
            presentSoon(error)
        }
    }

    private func reloadOrThrow(_ tab: EditorTab, as encoding: String.Encoding?) throws {
        try tab.document.reload(as: encoding)
        recovery?.refresh(tab.document)
        updateTitle()
        updateTabBar()
    }

    // MARK: - Encoding and line endings

    /// The status bar's encoding and line endings, for the current tab.
    private func updateFileFormat() {
        guard let doc = activeTab?.document else {
            statusBar.fileFormat = nil
            return
        }
        statusBar.fileFormatNote = doc.hadMixedLineEndings
            ? "The file mixes line endings; saving writes them all as \(doc.format.lineEnding.name)." : nil
        statusBar.fileFormat = doc.format.description + (doc.hadMixedLineEndings ? " (mixed)" : "")
    }

    static func lineEndingTitle(_ ending: LineEnding) -> String {
        switch ending {
        case .lf: "LF (macOS, Linux)"
        case .crlf: "CRLF (Windows)"
        case .cr: "CR (classic Mac OS)"
        }
    }

    /// The menu under the status bar's format: line endings, then encodings to save with or to
    /// read the file again in. A new line ending or encoding is written on the next save.
    func fileFormatMenu() -> NSMenu? {
        guard let doc = activeTab?.document else { return nil }
        let menu = NSMenu()
        menu.font = NSFont.menuFont(ofSize: 12)
        menu.autoenablesItems = false
        menu.addItem(.sectionHeader(title: "Line Endings"))
        for ending in LineEnding.allCases {
            let item = NSMenuItem(title: Self.lineEndingTitle(ending), action: #selector(chooseLineEnding(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = ending.rawValue
            item.state = doc.format.lineEnding == ending ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Encoding"))
        let save = NSMenuItem(title: "Save with Encoding", action: nil, keyEquivalent: "")
        save.submenu = encodingMenu(#selector(saveWithEncoding(_:)), checked: doc.format)
        menu.addItem(save)
        let reopen = NSMenuItem(title: "Reopen with Encoding", action: nil, keyEquivalent: "")
        reopen.submenu = encodingMenu(#selector(reopenWithEncoding(_:)), checked: nil)
        reopen.isEnabled = doc.fileURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        menu.addItem(reopen)
        return menu
    }

    /// The encodings Vie offers, Unicode first, then Western, then East Asian; the item's tag
    /// is its index in `TextEncoding.all`.
    private func encodingMenu(_ action: Selector, checked: TextFormat?) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (k, choice) in TextEncoding.all.enumerated() {
            if choice.encoding == .windowsCP1252 || choice.encoding == .shiftJIS { menu.addItem(.separator()) }
            let item = NSMenuItem(title: choice.title, action: action, keyEquivalent: "")
            item.target = self
            item.tag = k
            if let checked, checked.encoding == choice.encoding, checked.hasBOM == choice.hasBOM { item.state = .on }
            menu.addItem(item)
        }
        return menu
    }

    @objc func chooseLineEnding(_ item: NSMenuItem) {
        guard let tab = activeTab, let raw = item.representedObject as? String, let ending = LineEnding(rawValue: raw) else { return }
        var format = tab.document.format
        format.lineEnding = ending
        setFormat(format, of: tab)
    }

    @objc func saveWithEncoding(_ item: NSMenuItem) {
        guard let tab = activeTab, TextEncoding.all.indices.contains(item.tag) else { return }
        let choice = TextEncoding.all[item.tag]
        var format = tab.document.format
        format.encoding = choice.encoding
        format.hasBOM = choice.hasBOM
        setFormat(format, of: tab)
    }

    @objc func reopenWithEncoding(_ item: NSMenuItem) {
        guard let tab = activeTab, TextEncoding.all.indices.contains(item.tag) else { return }
        reload(tab, as: TextEncoding.all[item.tag].encoding)
    }

    /// A new encoding or line endings for the next save; the tab shows it's unsaved.
    private func setFormat(_ format: TextFormat, of tab: EditorTab) {
        tab.document.setFormat(format)
        updateFileFormat()
        updateEditedState()
    }

    /// `:set ff`, `:set fenc` and `:set bomb`: show or change how the tab's file is saved.
    private func fileOption(_ option: VimFileOption, _ value: String?, in tab: EditorTab) -> String? {
        let current = tab.document.format
        var format = current
        switch option {
        case .fileformat:
            guard let value else {
                tab.view?.vim?.showMessage("  fileformat=\(current.lineEnding.vimName)")
                return nil
            }
            guard let ending = LineEnding(vimName: value) else { return "E474: Invalid argument: ff=\(value)" }
            format.lineEnding = ending
        case .fileencoding:
            guard let value else {
                tab.view?.vim?.showMessage("  fileencoding=\(current.vimEncodingName)")
                return nil
            }
            guard let choice = TextEncoding.named(value) else { return "E474: Invalid argument: fenc=\(value)" }
            format.encoding = choice.encoding
            // UTF-16 always gets a BOM, so Vie can read it back; UTF-8 keeps 'bomb' as it was.
            format.hasBOM = choice.encoding == .utf8 ? current.encoding == .utf8 && current.hasBOM : choice.hasBOM
        case .bomb:
            guard let value else {
                tab.view?.vim?.showMessage(current.hasBOM ? "  bomb" : "  nobomb")
                return nil
            }
            // Only UTF-8's mark is optional: UTF-16 always has one, other encodings none.
            guard current.encoding == .utf8 else { return nil }
            format.hasBOM = value == "toggle" ? !current.hasBOM : value == "on"
        }
        setFormat(format, of: tab)
        return nil
    }

    /// `:e ++enc=name`: reads the tab's file again in that encoding.
    private func reopen(_ tab: EditorTab, encoding name: String, force: Bool) -> String? {
        guard let choice = TextEncoding.named(name) else { return "E474: Invalid argument: ++enc=\(name)" }
        guard tab.document.fileURL != nil else { return "E32: No file name" }
        if !force && tab.document.isDirty { return Self.notSaved }
        do {
            try reloadOrThrow(tab, as: choice.encoding)
        } catch {
            return error.localizedDescription
        }
        tab.view?.vim?.showMessage("\"\(tab.document.displayName)\" read as \(choice.name)")
        return nil
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
        case .writeQuit(let path, let force):
            Task {
                guard await write(tab, path) else { return }
                // `:wq other.txt` wrote a copy; as in Vim, the buffer's own changes keep the
                // tab open unless forced.
                if force || !tab.document.isDirty {
                    closeTabSoon(tab)
                } else {
                    tab.view?.vim?.showMessage(Self.notSaved, error: true)
                }
            }
        case .exit:
            // `:x` and `:x!` both write first when there are changes, as in Vim (where the `!`
            // only forces the write).
            if tab.document.isDirty {
                Task { if await write(tab, nil) { closeTabSoon(tab) } }
            } else {
                closeTabSoon(tab)
            }
        case .edit(let path, let force, let encoding):
            if let path, !path.isEmpty {
                let opened = open(url(for: path, from: tab))
                if let opened, let encoding { return reopen(opened, encoding: encoding, force: force) }
                return nil
            }
            if let encoding { return reopen(tab, encoding: encoding, force: force) }
            guard tab.document.fileURL != nil else { return "E32: No file name" }
            if !force && tab.document.isDirty { return Self.notSaved }
            reload(tab)
        case .fileOption(let option, let value):
            return fileOption(option, value, in: tab)
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
            return toggleSidebar(focus: true)
        case .focusSidebar:
            focusTree()
        // The Space commands that match menu items do what those do, after the key.
        case .closeTab:
            closeTabSoon(tab, force: false)
        case .findFile:
            DispatchQueue.main.async { [weak self] in self?.openQuickly(nil) }
        case .newFile:
            DispatchQueue.main.async { [weak self] in self?.newTab(nil) }
        case .quitApp:
            DispatchQueue.main.async { NSApp.terminate(nil) }
        case .toggleWrap:
            NSApp.sendAction(#selector(AppDelegate.toggleWrapLines(_:)), to: nil, from: nil)
        case .setFiletype, .showFiletype:
            break // the editor view handles these itself
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
                saved(tab)
                onSaveAs?(target)
                tab.view?.vim?.showMessage("\"\(doc.displayName)\" \(summary)")
                return true
            }
        }
        guard await save(tab, as: false) else { return false }
        tab.view?.vim?.showMessage("\"\(doc.displayName)\" \(summary)")
        return true
    }

    // MARK: - Find

    /// Edit ▸ Find ▸ Find… (⌘F): the Find bar, without its Replace row, with the keyboard.
    @objc func showFindBar(_ sender: Any?) { presentFindBar(replacing: false) }

    /// Edit ▸ Find ▸ Find and Replace… (⌥⌘F).
    @objc func showFindAndReplace(_ sender: Any?) { presentFindBar(replacing: true) }

    /// ⌘G, also with the bar hidden.
    @objc func findNextMatch(_ sender: Any?) {
        findBar.editor = activeView
        findBar.findNext(forward: true)
    }

    /// ⇧⌘G.
    @objc func findPreviousMatch(_ sender: Any?) {
        findBar.editor = activeView
        findBar.findNext(forward: false)
    }

    /// ⌘E: the selection becomes the search, ready for ⌘G.
    @objc func useSelectionForFind(_ sender: Any?) {
        findBar.editor = activeView
        findBar.useSelection()
    }

    private func presentFindBar(replacing: Bool) {
        guard let view = activeView else { return NSSound.beep() }
        findBar.editor = view
        findBar.show(replacing: replacing)
        findBar.focus()
    }

    private func closeFindBar() {
        findBar.hide()
        focusEditor()
    }

    /// The Find bar, while shown, between the tab bar and the text, which gives it the room.
    private func layoutFindBar() {
        let size = column.bounds.size
        let barH = StatusBarView.height, tabH = TabBarView.height
        let findH = findBar.isShown ? findBar.height : 0
        findBar.frame = NSRect(x: 0, y: size.height - tabH - findH, width: size.width, height: findH)
        editorHost.frame = NSRect(x: 0, y: barH, width: size.width, height: max(0, size.height - barH - tabH - findH))
    }

    // MARK: - Quick open

    @objc func openQuickly(_ sender: Any?) {
        if quickOpenIsShown { return quickOpen.dismiss() }
        quickOpen.index = index
        // Tabs not shown since the session was restored come after the others, in tab order.
        let shown = history.compactMap { id in tabs.first { ObjectIdentifier($0) == id } }
        quickOpen.recent = (shown + tabs.filter { tab in !shown.contains { $0 === tab } })
            .compactMap { $0.document.fileURL.map { displayPath($0) } }
        // Files deleted since they were closed are left out.
        quickOpen.closed = closedFiles.compactMap { $0.path.map { URL(fileURLWithPath: $0) } }
            .filter { tabIndex(for: $0) == nil && FileManager.default.fileExists(atPath: $0.path) }
            .map { displayPath($0) }
        quickOpen.show(in: column)
    }

    private func openQuickOpenResult(_ path: String) {
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { open(URL(fileURLWithPath: expanded)) }
        else if let folder = tree?.root.url { open(folder.appendingPathComponent(path)) }
    }

    /// Builds the ⌘P index in the background (again after files change).
    private func rebuildIndex() {
        guard let folder = tree?.root.url else { return }
        indexGeneration += 1
        let generation = indexGeneration
        Task.detached(priority: .utility) {
            let context = IgnoreContext(folder: folder)
            let index = FuzzyIndex(paths: PathScanner.scan(context, folder: folder))
            await MainActor.run { [weak self] in
                guard let self, generation == self.indexGeneration else { return }
                self.index = index
                if self.quickOpenIsShown { self.quickOpen.index = index }
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
        var tabsState: [SessionState.Tab] = []
        var active: Int?
        for tab in tabs {
            let backup = recovery?.backupID(for: tab.document)
            // An untitled tab comes back only with its unsaved text, after a crash.
            guard tab.document.fileURL != nil || backup != nil else { continue }
            if tab === activeTab { active = tabsState.count }
            tabsState.append(sessionTab(tab, backup: backup))
        }
        return SessionState.Window(
            folder: folder?.path,
            frame: window.map { NSStringFromRect($0.frame) },
            sidebarWidth: sidebarWidth.map(Double.init),
            tabs: tabsState,
            active: active,
            expanded: sidebar?.expandedPaths ?? [],
            closed: closedFiles.isEmpty ? nil : closedFiles)
    }

    /// What the session keeps of a tab: its file, cursor, top line and chosen language.
    private func sessionTab(_ tab: EditorTab, backup: String? = nil) -> SessionState.Tab {
        // A tab not shown since the restore has no view yet: its cursor is still the session's.
        let cursor = tab.view?.vim?.cursor ?? tab.restoreCursor ?? tab.document.buffer.selection.head
        let top = tab.view?.visibleLines.lowerBound ?? tab.restoreTopLine ?? 0
        let language = tab.view.map { $0.languageIsChosen ? $0.syntaxLanguage?.name ?? "" : nil } ?? tab.restoreLanguage
        return SessionState.Tab(path: tab.document.fileURL?.path, cursor: cursor, topLine: top, language: language, backup: backup)
    }

    /// Brings back a window from the session. Tabs with a copy among `backups` (left by a
    /// crash) get their unsaved text back; returns the copies used.
    @discardableResult
    func restore(_ state: SessionState.Window, backups: [String: Recovery.Backup] = [:]) -> Set<String> {
        if let frame = state.frame { window?.setFrame(NSRectFromString(frame), display: false) }
        // First, so opening the session's tabs takes their files off the list.
        closedFiles = state.closed ?? []
        if folder != nil {
            setSidebar(width: state.sidebarWidth.map { CGFloat($0) })
            sidebar?.expand(paths: state.expanded)
        }
        var used: Set<String> = []
        // The tab that was current, kept by identity: tabs that fail to open shift the indices.
        var current: EditorTab?
        for (k, t) in state.tabs.enumerated() {
            let backup = recovery == nil ? nil : t.backup.flatMap { backups[$0] }
            let tab: EditorTab
            if let path = t.path {
                // A file deleted since the crash still comes back with its unsaved text.
                guard backup != nil || FileManager.default.fileExists(atPath: path),
                      let opened = open(URL(fileURLWithPath: path), select: false) else { continue }
                tab = opened
            } else {
                guard backup != nil else { continue }
                tab = EditorTab(document: Document())
                add(tab)
            }
            if let backup {
                recover(backup, into: tab)
                used.insert(backup.id)
            }
            tab.restoreCursor = t.cursor
            tab.restoreTopLine = t.topLine
            tab.restoreLanguage = t.language
            if k == state.active { current = tab }
        }
        if let current, let i = tabs.firstIndex(where: { $0 === current }) { selectTab(i) } else if !tabs.isEmpty { selectTab(0) }
        // A window of loose files that showed its tree shows the current file's project again.
        if folder == nil, let width = state.sidebarWidth {
            followActiveProject(width: CGFloat(width))
            sidebar?.expand(paths: state.expanded)
            revealActiveFile()
            updateTitle()
        }
        return used
    }

    /// Opens a copy of unsaved text that the session didn't list: in its file's tab, or in a
    /// new untitled tab if it had no file or the file can't be opened.
    func recover(_ backup: Recovery.Backup) {
        let tab = backup.path.flatMap { open(URL(fileURLWithPath: $0)) } ?? {
            let tab = EditorTab(document: Document())
            add(tab)
            selectTab(tabs.firstIndex { $0 === tab }!)
            return tab
        }()
        recover(backup, into: tab)
        updateEditedState()
        if activeTab === tab, tab.recoveryWarning != nil { warnAboutRecoverySoon(tab) }
    }

    /// Puts a copy's text into the tab, noting whether its file changed since.
    private func recover(_ backup: Recovery.Backup, into tab: EditorTab) {
        tab.recoveryWarning = Recovery.change(since: backup)
        recovery?.recover(backup, into: tab.document)
    }

    /// Once the window is on screen (restoring selects tabs before it's shown).
    private func warnAboutRecoverySoon(_ tab: EditorTab) {
        DispatchQueue.main.async { [weak self] in self?.warnAboutRecovery(tab) }
    }

    /// Says that the tab's recovered text was made to a version of its file that's gone, and
    /// offers the version on disk now (Undo brings the recovered text back).
    private func warnAboutRecovery(_ tab: EditorTab) {
        guard let change = tab.recoveryWarning, let window, window.isVisible, window.attachedSheet == nil,
              activeTab === tab else { return }
        tab.recoveryWarning = nil
        let alert = NSAlert()
        let name = tab.document.displayName
        switch change {
        case .changed:
            alert.messageText = "“\(name)” changed on disk after Vie quit unexpectedly."
            alert.informativeText = "Your recovered changes were made to an older version of the file. Undo in this tab shows the version on disk now."
            alert.addButton(withTitle: "Keep My Changes")
            alert.addButton(withTitle: "Use Version on Disk")
        case .deleted:
            alert.messageText = "“\(name)” was deleted after Vie quit unexpectedly."
            alert.informativeText = "Your unsaved text is back in its tab. Saving creates the file again."
            alert.addButton(withTitle: "OK")
        }
        Task {
            let response = await alert.beginSheetModal(for: window)
            if change == .changed && response == .alertSecondButtonReturn { reload(tab) }
        }
    }
}

/// The editor area when no tab is open.
extension WorkspaceWindowController: @preconcurrency QLPreviewPanelDataSource, @preconcurrency QLPreviewPanelDelegate {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { previewItems.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        previewItems[index] as NSURL
    }

    /// Keys the panel doesn't use (up and down, j and k) go to the tree when it has the
    /// keyboard, so moving there shows the next item.
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown, let outline = sidebar?.outline, window?.firstResponder === outline else { return false }
        outline.keyDown(with: event)
        return true
    }
}

final class EmptyEditorView: NSView {
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        NotificationCenter.default.addObserver(self, selector: #selector(themeDidChange), name: EditorTheme.didChange, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func themeDidChange(_ note: Notification) { needsDisplay = true }

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
        /// The file; nil for an untitled tab (kept only when it has a backup).
        var path: String?
        var cursor: Int
        var topLine: Int
        /// A language picked by hand ("" for plain text); nil goes by the file's name.
        var language: String?
        /// The copy of the tab's unsaved text in the recovery folder, if it has one.
        var backup: String?
    }

    struct Window: Codable {
        var folder: String?
        var frame: String?
        var sidebarWidth: Double?
        var tabs: [Tab]
        var active: Int?
        var expanded: [String]
        /// Files whose tabs were closed, most recently closed first (nil in older sessions).
        var closed: [Tab]? = nil
    }

    var windows: [Window]

    /// The languages the tabs will be highlighted in, each window's current tab first.
    var languages: [SyntaxLanguage] {
        var found: [SyntaxLanguage] = []
        func add(_ tab: Tab) {
            // As restoring does: a language picked by hand ("" for plain text), else the file's.
            let language: SyntaxLanguage?
            if let name = tab.language, name.isEmpty || SyntaxLanguage.named(name) != nil {
                language = SyntaxLanguage.named(name)
            } else {
                language = tab.path.flatMap { SyntaxLanguage.forFile(named: URL(fileURLWithPath: $0).lastPathComponent) }
            }
            if let language, !found.contains(where: { $0 === language }) { found.append(language) }
        }
        for w in windows {
            if let k = w.active, w.tabs.indices.contains(k) { add(w.tabs[k]) }
        }
        for w in windows { w.tabs.forEach(add) }
        return found
    }

    /// Compiles the highlight queries of the tabs' languages off the main thread, so they're
    /// ready by the time the tabs are parsed: Swift's alone takes longer (~60 ms) than the rest
    /// of a launch after this point, and the first frame would show the text without colors.
    func compileQueriesInBackground() {
        for language in languages {
            DispatchQueue.global(qos: .userInitiated).async { language.compileQueries() }
        }
    }

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
