import AppKit
import CoreText
import QuartzCore
import VieEditor
import VieText
import VieVim
import VieWorkspace

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private let options: LaunchOptions
    private var windows: [WorkspaceWindowController] = []
    private var cascadePoint = NSPoint.zero
    private var bench: Bench?
    private var openMs = 0.0
    private var firstFrameMs = 0.0
    /// One Vim session for the app: registers and searches carry across windows.
    private let vimSession = VimSession()
    private var sessionSave: DispatchWorkItem?
    private var restoring = false
    /// Copies of unsaved text, for after a crash; none when measuring.
    private lazy var recovery: Recovery? = {
        guard !options.isMeasuring else { return nil }
        let recovery = Recovery(directory: SessionState.url.deletingLastPathComponent().appendingPathComponent("Recovery"))
        recovery.onChange = { [weak self] in self?.scheduleSessionSave() }
        return recovery
    }()
    /// Files asked for while launching (from Finder or `open`), opened once the session is
    /// back; nil after launch.
    private var launchURLs: [URL]? = []
    /// File ▸ Open Recent.
    private lazy var recentMenu = RecentMenu.system { [weak self] url in self?.open(url) }

    init(options: LaunchOptions) {
        self.options = options
        super.init()
    }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build(recent: recentMenu.menu)
        applyLook()
        if let name = settings.font.name, EditorFont.bundled.contains(name) { registerBundledFonts() }
        let paths = options.isMeasuring ? Array(options.paths.prefix(1)) : options.paths
        let urls = paths.map { URL(fileURLWithPath: $0) } + (launchURLs ?? [])
        launchURLs = nil
        // The last session's windows come back even when Vie was started to open files, as
        // Mac apps do; the files then open in the windows holding them (or a new one), in
        // front. Benchmarks skip the session.
        if !options.isMeasuring { restoreSession() }
        for url in urls { open(url) }
        if windows.isEmpty { newDocument(nil) }
        NSApp.activate()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard !options.isMeasuring else { return }
        if launchURLs != nil { launchURLs? += urls } else { for url in urls { open(url) } }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { newDocument(nil) }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { options.isMeasuring }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    /// Quitting with unsaved changes asks about each document, as Mac document apps do; while
    /// a copy or move is running in a window's tree, it asks whether to stop that first.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let dirtyWindows = windows.filter { $0.tabs.contains { $0.document.isDirty } }
        let dirtyCount = dirtyWindows.reduce(0) { $0 + $1.tabs.filter { $0.document.isDirty }.count }
        let busyWindows = windows.filter { $0.sidebar?.isBusy == true }
        if options.isMeasuring || (dirtyCount == 0 && busyWindows.isEmpty) {
            finishQuitting()
            return .terminateNow
        }
        Task {
            for controller in busyWindows {
                controller.showWindow(nil)
                guard await controller.confirmStopTransfers() else {
                    NSApp.reply(toApplicationShouldTerminate: false)
                    return
                }
            }
            if dirtyCount > 1 {
                let alert = NSAlert()
                alert.messageText = "You have \(dirtyCount) documents with unsaved changes. Do you want to review these changes before quitting?"
                alert.informativeText = "If you don’t review your documents, all your changes will be lost."
                alert.addButton(withTitle: "Review Changes…")
                alert.addButton(withTitle: "Cancel")
                alert.addButton(withTitle: "Discard Changes").hasDestructiveAction = true
                switch alert.runModal() {
                case .alertFirstButtonReturn: break
                case .alertThirdButtonReturn:
                    finishQuitting()
                    NSApp.reply(toApplicationShouldTerminate: true)
                    return
                default:
                    NSApp.reply(toApplicationShouldTerminate: false)
                    return
                }
            }
            for controller in dirtyWindows {
                controller.showWindow(nil)
                guard await controller.confirmCloseAll() else {
                    NSApp.reply(toApplicationShouldTerminate: false)
                    return
                }
            }
            finishQuitting()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard options.hud, let view = windows.first?.activeView else { return }
        print("draw        " + view.drawStats.describe(unit: "ms"))
        if view.keyStats.count > 0 { print("key→drawn   " + view.keyStats.describe(unit: "ms")) }
        if view.editStats.count > 0 { print("edit        " + view.editStats.describe(unit: "µs")) }
        fflush(stdout)
    }

    // MARK: - Session

    /// Quitting normally, with unsaved changes saved or thrown away: the copies kept for a
    /// crash go (before the session is saved, so it doesn't list them).
    private func finishQuitting() {
        recovery?.removeAll()
        saveSession()
    }

    private func saveSession() {
        guard !options.isMeasuring, !restoring else { return }
        sessionSave?.cancel()
        SessionState(windows: windows.map { $0.state() }).save()
    }

    /// Saves a moment after the last change (tabs opened, closed, switched), so a crash
    /// loses little.
    private func scheduleSessionSave() {
        guard !options.isMeasuring, !restoring else { return }
        sessionSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveSession() }
        sessionSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    /// Brings back the last session's windows. Copies of unsaved text left by a crash go back
    /// into their tabs; any the session doesn't list (a tab opened just before the crash) open
    /// in the window that would hold their file.
    private func restoreSession() {
        var backups = Dictionary((recovery?.backups() ?? []).map { ($0.id, $0) }) { a, _ in a }
        restoring = true
        defer { restoring = false }
        let session = SessionState.load()
        session?.compileQueriesInBackground()
        for w in session?.windows ?? [] {
            if let folder = w.folder {
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: folder, isDirectory: &isDir), isDir.boolValue else { continue }
                let controller = makeWindow(folder: URL(fileURLWithPath: folder))
                for id in controller.restore(w, backups: backups) { backups[id] = nil }
                show(controller, placed: w.frame != nil)
            } else if !w.tabs.isEmpty {
                let controller = makeWindow(folder: nil)
                for id in controller.restore(w, backups: backups) { backups[id] = nil }
                if controller.tabs.isEmpty { continue }
                show(controller, placed: w.frame != nil)
            }
        }
        for backup in backups.values.sorted(by: { $0.id < $1.id }) {
            let url = backup.path.map { URL(fileURLWithPath: $0).standardizedFileURL }
            if let target = url.map({ window(for: $0) }) ?? frontLooseWindow() {
                target.recover(backup)
            } else {
                let controller = makeWindow(folder: nil)
                controller.recover(backup)
                show(controller)
            }
        }
    }

    // MARK: - Settings

    /// Vim mode, wrapping and the font, from the menus and the Settings window.
    /// Not private: tests give the app settings of their own.
    lazy var settings: AppSettings = {
        let settings = AppSettings(measuring: options.isMeasuring)
        settings.onChange = { [weak self] in self?.applySettings() }
        return settings
    }()
    private var settingsWindow: SettingsWindowController?

    @objc func showSettings(_ sender: Any?) {
        registerBundledFonts()
        if settingsWindow == nil { settingsWindow = SettingsWindowController(settings: settings) }
        settingsWindow?.showWindow(sender)
    }

    private var bundledFontsRegistered = false

    /// Makes the fonts in Resources/Fonts (scripts/fetch-fonts.sh) usable by Vie alone. Done
    /// when first needed rather than at launch (or with Info.plist's ATSApplicationFontsPath),
    /// which would cost every launch ~4 ms, even with SF Mono.
    private func registerBundledFonts() {
        guard !bundledFontsRegistered, let dir = Bundle.main.resourceURL?.appendingPathComponent("Fonts") else { return }
        bundledFontsRegistered = true
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for url in files where url.pathExtension == "ttf" { CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil) }
    }

    /// The appearance and themes, for the whole app.
    private func applyLook() {
        let appearance = settings.appearance.nsAppearance
        if NSApp.appearance?.name != appearance?.name { NSApp.appearance = appearance }
        EditorTheme.use(light: settings.lightTheme, dark: settings.darkTheme)
    }

    /// Every window takes the settings (the Settings window observes them itself).
    private func applySettings() {
        applyLook()
        let font = settings.font
        for controller in windows {
            if controller.vimEnabled != settings.vimMode { controller.vimEnabled = settings.vimMode }
            if controller.wrapsLines != settings.wrapLines { controller.wrapsLines = settings.wrapLines }
            if controller.relativeLineNumbers != settings.relativeLineNumbers {
                controller.relativeLineNumbers = settings.relativeLineNumbers
            }
            if controller.editorFont != font { controller.editorFont = font }
        }
    }

    /// On unless turned off in the Edit menu (⌃⌘V), the status bar's switch or Settings (or
    /// with `-VimMode NO`).
    @objc func toggleVimMode(_ sender: Any?) {
        settings.vimMode.toggle()
    }

    /// On unless turned off in the View menu or Settings (or with `-WrapLines NO`).
    @objc func toggleWrapLines(_ sender: Any?) {
        settings.wrapLines.toggle()
    }

    /// Off unless turned on in the View menu or Settings, or by double-clicking the line
    /// numbers (or with `-RelativeLineNumbers YES`).
    @objc func toggleRelativeLineNumbers(_ sender: Any?) {
        settings.relativeLineNumbers.toggle()
    }

    /// Space u b: Light or Dark, whichever isn't showing (leaving "System" if it was set).
    @objc func toggleDarkMode(_ sender: Any?) {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        settings.appearance = dark ? .light : .dark
    }

    /// Space u C: the themes for the appearance showing, in the key window's ⌘P panel. Each
    /// shows as the selection reaches it; Return keeps it (as choosing it in Settings does),
    /// Esc goes back to the one before.
    @objc func chooseTheme(_ sender: Any?) {
        guard let controller = windows.first(where: { $0.window?.isKeyWindow == true }) ?? windows.first else { return }
        chooseTheme(in: controller)
    }

    /// Space u C: the themes for the window's appearance in its ⌘P panel. Moving previews one,
    /// Return keeps it (as Settings would), Esc goes back.
    func chooseTheme(in controller: WorkspaceWindowController) {
        let dark = (controller.window?.effectiveAppearance ?? NSApp.effectiveAppearance).bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let themes = dark ? EditorTheme.dark : EditorTheme.light
        let current = dark ? settings.darkTheme : settings.lightTheme
        controller.showChoices(QuickOpenController.Choices(
            titles: themes.map(\.name), selected: themes.firstIndex(of: current) ?? 0,
            placeholder: dark ? "Dark theme…" : "Light theme…",
            onHighlight: { [unowned self] i in
                EditorTheme.use(light: dark ? settings.lightTheme : themes[i], dark: dark ? themes[i] : settings.darkTheme)
            },
            onChoose: { [unowned self] i in
                if dark { settings.darkTheme = themes[i] } else { settings.lightTheme = themes[i] }
            },
            onCancel: { [unowned self] in
                EditorTheme.use(light: settings.lightTheme, dark: settings.darkTheme)
            }))
    }

    @objc func increaseFontSize(_ sender: Any?) {
        settings.font.size += 1
    }

    @objc func decreaseFontSize(_ sender: Any?) {
        settings.font.size -= 1
    }

    @objc func resetFontSize(_ sender: Any?) {
        settings.font.size = EditorFont.defaultSize
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let size = settings.font.size
        switch item.action {
        case #selector(toggleVimMode(_:)): item.state = settings.vimMode ? .on : .off
        case #selector(toggleWrapLines(_:)): item.state = settings.wrapLines ? .on : .off
        case #selector(toggleRelativeLineNumbers(_:)): item.state = settings.relativeLineNumbers ? .on : .off
        case #selector(increaseFontSize(_:)): return size < EditorFont.sizes.upperBound
        case #selector(decreaseFontSize(_:)): return size > EditorFont.sizes.lowerBound
        case #selector(resetFontSize(_:)): return size != EditorFont.defaultSize
        default: break
        }
        return true
    }

    // MARK: - Opening files and folders

    /// ⌘N: a new window with an empty tab.
    @objc func newDocument(_ sender: Any?) {
        let controller = makeWindow(folder: nil)
        controller.newTab(nil)
        show(controller)
    }

    /// ⌘T when no window is open (windows handle it themselves).
    @objc func newTab(_ sender: Any?) { newDocument(sender) }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.message = "Choose files, or a folder to open as a workspace."
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { open(url) }
    }

    /// Help ▸ Vie Help (⌘?): Vie's guide, the README that the build puts in the app, as a
    /// Markdown tab with the sidebar showing its Outline. It opens from a copy in Caches, so
    /// editing it can't touch the app; the copy is made afresh unless it's open already, when
    /// its tab is shown. Not named `showHelp(_:)`: NSApplication has that, and it comes first
    /// in the responder chain.
    @objc func showVieHelp(_ sender: Any?) {
        guard let guide = Bundle.main.url(forResource: "Vie Help", withExtension: "md"),
              let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            NSSound.beep()
            return
        }
        let copy = caches.appendingPathComponent("Vie/Vie Help.md")
        if !windows.contains(where: { $0.tabIndex(for: copy) != nil }) {
            do {
                try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: copy.path) { try FileManager.default.removeItem(at: copy) }
                try FileManager.default.copyItem(at: guide, to: copy)
            } catch {
                NSAlert(error: error).runModal()
                return
            }
        }
        open(copy, recent: false)
        // The sidebar holds the guide's Outline; a window of loose files starts without it.
        if let window = window(for: copy), window.sidebarWidth == nil { window.toggleFileTree(nil) }
    }

    /// A folder opens in its own window. A file opens as a tab in the window whose folder
    /// holds it, else in the front window of loose files, else in a new window. Either goes
    /// to the top of File ▸ Open Recent (unless `recent` is false). A file that isn't text goes
    /// to its default app.
    private func open(_ url: URL, recent: Bool = true) {
        let url = url.standardizedFileURL
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        if exists && isDir.boolValue {
            noteRecent(url)
            let resolved = url.resolvingSymlinksInPath()
            if let existing = windows.first(where: { $0.folder?.path == resolved.path }) {
                existing.showWindow(nil)
                return
            }
            let t0 = CACurrentMediaTime()
            let controller = makeWindow(folder: url)
            if windows.isEmpty { openMs = (CACurrentMediaTime() - t0) * 1000 }
            // An empty untitled window gives way to the folder.
            for w in windows where w.folder == nil && w.tabs.allSatisfy(\.isUntouched) { w.close() }
            show(controller)
            return
        }
        if exists, !options.isMeasuring, TextFile.looksBinary(at: url) {
            openInDefaultApp(url)
            return
        }
        if let target = window(for: url) {
            if target.open(url) != nil {
                if recent { noteRecent(url) }
                target.showWindow(nil)
            }
            return
        }
        let controller = makeWindow(folder: nil)
        guard controller.open(url) != nil else {
            if options.isMeasuring {
                fputs("can't open \(url.path)\n", stderr)
                exit(1)
            }
            return
        }
        if recent { noteRecent(url) }
        if windows.isEmpty { openMs = controller.lastLoadMs }
        show(controller)
    }

    /// A file that isn't text, opened from outside a window (⌘O, Open Recent, the Dock): its
    /// default app shows it, as there may be no window to preview it over. If that app is Vie
    /// (made the default for a kind of text), or there's none, an alert says why it can't open.
    private func openInDefaultApp(_ url: URL) {
        if let app = NSWorkspace.shared.urlForApplication(toOpen: url),
           Bundle(url: app)?.bundleIdentifier != Bundle.main.bundleIdentifier {
            NSWorkspace.shared.open(url)
        } else {
            NSAlert(error: TextFileError.binary).runModal()
        }
    }

    /// Puts a file or folder at the top of File ▸ Open Recent (and the Dock icon's menu):
    /// what's opened from outside a window, and files saved under a new name. Not when
    /// measuring, so benchmarks leave the list alone.
    private func noteRecent(_ url: URL) {
        guard !options.isMeasuring else { return }
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
    }

    /// Where a file opens: the window that has it open already, else the one whose folder
    /// holds it, else the front window of loose files.
    private func window(for file: URL) -> WorkspaceWindowController? {
        windows.first { $0.tabIndex(for: file) != nil } ?? window(holding: file) ?? frontLooseWindow()
    }

    /// The window whose folder holds the file.
    private func window(holding url: URL) -> WorkspaceWindowController? {
        let resolved = url.resolvingSymlinksInPath()
        return windows.first { w in w.folder.map { resolved.path.hasPrefix($0.path + "/") } ?? false }
    }

    private func frontLooseWindow() -> WorkspaceWindowController? {
        for window in NSApp.orderedWindows {
            if let c = windows.first(where: { $0.window === window }), c.folder == nil { return c }
        }
        return nil
    }

    private func makeWindow(folder: URL?) -> WorkspaceWindowController {
        // Benchmarks use a fixed size so results stay comparable with the spike's.
        let size = options.isMeasuring ? NSSize(width: 1600, height: 1000) : NSSize(width: 1200, height: 800)
        let controller = WorkspaceWindowController(folder: folder, size: size, vimEnabled: settings.vimMode, vimSession: vimSession,
                                                   wrapsLines: settings.wrapLines, relativeLineNumbers: settings.relativeLineNumbers,
                                                   font: settings.font, recovery: recovery)
        controller.onClose = { [weak self] closed in
            self?.windows.removeAll { $0 === closed }
            self?.scheduleSessionSave()
        }
        controller.onSessionChange = { [weak self] in self?.scheduleSessionSave() }
        controller.onSaveAs = { [weak self] url in self?.noteRecent(url) }
        controller.onFileMoved = { [weak self] from, to in self?.windows.forEach { $0.renamed(from, to) } }
        controller.statusBar.onVimSwitch = { [weak self] in self?.toggleVimMode(nil) }
        return controller
    }

    /// Shows a window: centered if it's the first, else cascaded from the last. A window
    /// `placed` by the session stays where it was, unless that's on no screen now.
    private func show(_ controller: WorkspaceWindowController, placed: Bool = false) {
        if let view = controller.activeView {
            view.showHUD = options.hud
            view.forcedScale = options.scale
        }
        if options.isMeasuring && windows.isEmpty {
            let report: (Double) -> Void = { [weak self, weak controller] ms in
                guard let self, let controller else { return }
                self.didDrawFirstFrame(ms, in: controller)
            }
            if let view = controller.activeView {
                view.onFirstDraw = report
            } else {
                // A folder with no file open: time the window's first display (with its tree).
                DispatchQueue.main.async {
                    controller.window?.displayIfNeeded()
                    report((Metrics.secondsSinceProcessStart() ?? 0) * 1000)
                }
            }
        }
        if let window = controller.window {
            let onScreen = NSScreen.screens.contains { $0.visibleFrame.intersects(window.frame) }
            if placed && onScreen {
                cascadePoint = NSPoint(x: window.frame.minX, y: window.frame.maxY)
            } else if windows.isEmpty {
                window.center()
                cascadePoint = NSPoint(x: window.frame.minX, y: window.frame.maxY)
            }
            // Puts a new window at the point (a no-op for the two above) and gives the next one's.
            cascadePoint = window.cascadeTopLeft(from: cascadePoint)
        }
        windows.append(controller)
        controller.showWindow(nil)
    }

    // MARK: - Measurement modes

    private func didDrawFirstFrame(_ ms: Double, in controller: WorkspaceWindowController) {
        firstFrameMs = ms
        if options.launchOnly {
            print(String(format: "first frame %.1f ms after process start · open %.1f ms · memory %.1f MB",
                         ms, openMs, Metrics.footprintMB()))
            fflush(stdout)
            NSApp.terminate(nil)
        } else if options.bench, let view = controller.activeView {
            let b = Bench(view: view, header: header(for: controller, view), typeLine: options.typeLine)
            bench = b
            b.start()
        }
    }

    private func header(for controller: WorkspaceWindowController, _ view: EditorView) -> [String] {
        let rope = view.rope
        return [
            "Vie benchmark — \(controller.activeTab?.document.fileURL?.lastPathComponent ?? "(empty)")",
            String(format: "file         %.1f MB, %@ lines", Double(rope.byteCount) / 1_048_576, rope.lineCount.formatted()),
            String(format: "open         %.1f ms (read, check encoding, build rope)", openMs),
            String(format: "first frame  %.1f ms after process start", firstFrameMs),
            String(format: "memory       %.1f MB footprint after first frame", Metrics.footprintMB()),
            view.vimEnabled ? "vim mode     on (typing in Insert mode; -VimMode NO turns it off)" : "vim mode     off",
            view.wrapsLines ? "wrap         on (-WrapLines NO turns it off)" : "wrap         off",
        ]
    }
}
