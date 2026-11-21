import AppKit
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

    init(options: LaunchOptions) {
        self.options = options
        super.init()
    }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()
        let paths = options.isMeasuring ? Array(options.paths.prefix(1)) : options.paths
        for path in paths { open(URL(fileURLWithPath: path)) }
        if windows.isEmpty && !options.isMeasuring { restoreSession() }
        if windows.isEmpty { newDocument(nil) }
        NSApp.activate()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard !options.isMeasuring else { return }
        for url in urls { open(url) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { newDocument(nil) }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { options.isMeasuring }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    /// Quitting with unsaved changes asks about each document, as Mac document apps do.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let dirtyWindows = windows.filter { $0.tabs.contains { $0.document.isDirty } }
        let dirtyCount = dirtyWindows.reduce(0) { $0 + $1.tabs.filter { $0.document.isDirty }.count }
        if options.isMeasuring || dirtyCount == 0 {
            saveSession()
            return .terminateNow
        }
        Task {
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
                    saveSession()
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
            saveSession()
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

    private func restoreSession() {
        guard let state = SessionState.load() else { return }
        restoring = true
        defer { restoring = false }
        for w in state.windows {
            if let folder = w.folder {
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: folder, isDirectory: &isDir), isDir.boolValue else { continue }
                let controller = makeWindow(folder: URL(fileURLWithPath: folder))
                controller.restore(w)
                show(controller)
            } else if !w.tabs.isEmpty {
                let controller = makeWindow(folder: nil)
                controller.restore(w)
                if controller.tabs.isEmpty { continue }
                show(controller)
            }
        }
    }

    // MARK: - Vim mode

    private static let vimModeKey = "VimMode"

    /// On unless turned off in the Edit menu (or with `-VimMode NO` on the command line).
    private var vimMode: Bool {
        get {
            UserDefaults.standard.register(defaults: [Self.vimModeKey: true])
            return UserDefaults.standard.bool(forKey: Self.vimModeKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: Self.vimModeKey) }
    }

    @objc func toggleVimMode(_ sender: Any?) {
        vimMode.toggle()
        for controller in windows { controller.vimEnabled = vimMode }
    }

    // MARK: - Wrapping

    private static let wrapLinesKey = "WrapLines"

    /// On unless turned off in the View menu (or with `-WrapLines NO`).
    private var wrapLines: Bool {
        get {
            UserDefaults.standard.register(defaults: [Self.wrapLinesKey: true])
            return UserDefaults.standard.bool(forKey: Self.wrapLinesKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: Self.wrapLinesKey) }
    }

    @objc func toggleWrapLines(_ sender: Any?) {
        wrapLines.toggle()
        for controller in windows { controller.wrapsLines = wrapLines }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleVimMode(_:)) { item.state = vimMode ? .on : .off }
        if item.action == #selector(toggleWrapLines(_:)) { item.state = wrapLines ? .on : .off }
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

    /// A folder opens in its own window. A file opens as a tab in the window whose folder
    /// holds it, else in the front window of loose files, else in a new window.
    private func open(_ url: URL) {
        let url = url.standardizedFileURL
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        if exists && isDir.boolValue {
            let resolved = url.resolvingSymlinksInPath()
            if let existing = windows.first(where: { $0.folder == resolved }) {
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
        let resolved = url.resolvingSymlinksInPath()
        let target = windows.first { w in w.folder.map { resolved.path.hasPrefix($0.path + "/") } ?? false }
            ?? frontLooseWindow()
        if let target {
            if target.open(url) != nil { target.showWindow(nil) }
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
        if windows.isEmpty { openMs = controller.lastLoadMs }
        show(controller)
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
        let controller = WorkspaceWindowController(folder: folder, size: size, vimEnabled: vimMode, vimSession: vimSession,
                                                   wrapsLines: wrapLines)
        controller.onClose = { [weak self] closed in
            self?.windows.removeAll { $0 === closed }
            self?.scheduleSessionSave()
        }
        controller.onSessionChange = { [weak self] in self?.scheduleSessionSave() }
        return controller
    }

    private func show(_ controller: WorkspaceWindowController) {
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
            if windows.isEmpty {
                window.center()
                cascadePoint = NSPoint(x: window.frame.minX, y: window.frame.maxY)
            }
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
