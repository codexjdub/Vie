import AppKit
import QuartzCore
import VieEditor
import VieText
import VieWorkspace

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private let options: LaunchOptions
    private var windows: [EditorWindowController] = []
    private var cascadePoint = NSPoint.zero
    private var bench: Bench?
    private var openMs = 0.0
    private var firstFrameMs = 0.0

    init(options: LaunchOptions) {
        self.options = options
        super.init()
    }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()
        let paths = options.isMeasuring ? Array(options.paths.prefix(1)) : options.paths
        for path in paths { open(URL(fileURLWithPath: path)) }
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
        let dirty = windows.filter { $0.textDocument.isDirty }
        if options.isMeasuring || dirty.isEmpty { return .terminateNow }
        Task {
            if dirty.count > 1 {
                let alert = NSAlert()
                alert.messageText = "You have \(dirty.count) documents with unsaved changes. Do you want to review these changes before quitting?"
                alert.informativeText = "If you don’t review your documents, all your changes will be lost."
                alert.addButton(withTitle: "Review Changes…")
                alert.addButton(withTitle: "Cancel")
                alert.addButton(withTitle: "Discard Changes").hasDestructiveAction = true
                switch alert.runModal() {
                case .alertFirstButtonReturn: break
                case .alertThirdButtonReturn:
                    NSApp.reply(toApplicationShouldTerminate: true)
                    return
                default:
                    NSApp.reply(toApplicationShouldTerminate: false)
                    return
                }
            }
            for controller in dirty {
                controller.showWindow(nil)
                guard await controller.confirmClose() else {
                    NSApp.reply(toApplicationShouldTerminate: false)
                    return
                }
            }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard options.hud, let view = windows.first?.editorView else { return }
        print("draw        " + view.drawStats.describe(unit: "ms"))
        if view.keyStats.count > 0 { print("key→drawn   " + view.keyStats.describe(unit: "ms")) }
        if view.editStats.count > 0 { print("edit        " + view.editStats.describe(unit: "µs")) }
        fflush(stdout)
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
        for controller in windows { controller.editorView.vimEnabled = vimMode }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleVimMode(_:)) { item.state = vimMode ? .on : .off }
        return true
    }

    // MARK: - Opening files

    @objc func newDocument(_ sender: Any?) {
        show(Document())
    }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { open(url) }
    }

    private func open(_ url: URL) {
        if let existing = windows.first(where: { $0.fileURL == url.standardizedFileURL }) {
            existing.showWindow(nil)
            return
        }
        do {
            let t0 = CACurrentMediaTime()
            let document = try Document(contentsOf: url)
            if windows.isEmpty { openMs = (CACurrentMediaTime() - t0) * 1000 }
            for untouched in windows where untouched.isUntouchedUntitled { untouched.close() }
            show(document)
        } catch {
            if options.isMeasuring {
                fputs("can't open \(url.path): \(error.localizedDescription)\n", stderr)
                exit(1)
            }
            NSAlert(error: error).runModal()
        }
    }

    private func show(_ document: Document) {
        // Benchmarks use a fixed size so results stay comparable with the spike's.
        let size = options.isMeasuring ? NSSize(width: 1600, height: 1000) : NSSize(width: 1100, height: 760)
        let controller = EditorWindowController(document: document, size: size)
        let view = controller.editorView
        view.vimEnabled = vimMode
        view.showHUD = options.hud
        view.forcedScale = options.scale
        controller.onClose = { [weak self] closed in self?.windows.removeAll { $0 === closed } }
        controller.onOpen = { [weak self] url in self?.open(url) }
        if options.isMeasuring && windows.isEmpty {
            view.onFirstDraw = { [weak self, weak controller] ms in
                guard let self, let controller else { return }
                self.didDrawFirstFrame(ms, in: controller)
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

    private func didDrawFirstFrame(_ ms: Double, in controller: EditorWindowController) {
        firstFrameMs = ms
        if options.launchOnly {
            print(String(format: "first frame %.1f ms after process start · open %.1f ms · memory %.1f MB",
                         ms, openMs, Metrics.footprintMB()))
            fflush(stdout)
            NSApp.terminate(nil)
        } else if options.bench {
            let b = Bench(view: controller.editorView, header: header(for: controller), typeLine: options.typeLine)
            bench = b
            b.start()
        }
    }

    private func header(for controller: EditorWindowController) -> [String] {
        let rope = controller.editorView.rope
        return [
            "Vie benchmark — \(controller.fileURL?.lastPathComponent ?? "(empty)")",
            String(format: "file         %.1f MB, %@ lines", Double(rope.byteCount) / 1_048_576, rope.lineCount.formatted()),
            String(format: "open         %.1f ms (read, check encoding, build rope)", openMs),
            String(format: "first frame  %.1f ms after process start", firstFrameMs),
            String(format: "memory       %.1f MB footprint after first frame", Metrics.footprintMB()),
            controller.editorView.vimEnabled ? "vim mode     on (typing in Insert mode; -VimMode NO turns it off)" : "vim mode     off",
        ]
    }
}
