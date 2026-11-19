import AppKit
import QuartzCore
import VieEditor
import VieText

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
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

    func applicationWillTerminate(_ notification: Notification) {
        guard options.hud, let view = windows.first?.editorView else { return }
        print("draw        " + view.drawStats.describe(unit: "ms"))
        if view.keyStats.count > 0 { print("key→drawn   " + view.keyStats.describe(unit: "ms")) }
        if view.editStats.count > 0 { print("rope edit   " + view.editStats.describe(unit: "µs")) }
        fflush(stdout)
    }

    // MARK: - Opening files

    @objc func newDocument(_ sender: Any?) {
        show(rope: Rope(), url: nil)
    }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { open(url) }
    }

    private func open(_ url: URL) {
        if let existing = windows.first(where: { $0.fileURL?.standardizedFileURL == url.standardizedFileURL }) {
            existing.showWindow(nil)
            return
        }
        do {
            let t0 = CACurrentMediaTime()
            let rope = try Rope.load(contentsOf: url)
            if windows.isEmpty { openMs = (CACurrentMediaTime() - t0) * 1000 }
            for untouched in windows where untouched.isUntouchedUntitled { untouched.close() }
            show(rope: rope, url: url)
        } catch {
            if options.isMeasuring {
                fputs("can't open \(url.path): \(error.localizedDescription)\n", stderr)
                exit(1)
            }
            NSAlert(error: error).runModal()
        }
    }

    private func show(rope: Rope, url: URL?) {
        // Benchmarks use a fixed size so results stay comparable with the spike's.
        let size = options.isMeasuring ? NSSize(width: 1600, height: 1000) : NSSize(width: 1100, height: 760)
        let controller = EditorWindowController(rope: rope, url: url, size: size)
        let view = controller.editorView
        view.showHUD = options.hud
        view.forcedScale = options.scale
        controller.onClose = { [weak self] closed in self?.windows.removeAll { $0 === closed } }
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
            String(format: "open         %.1f ms (map file + build rope)", openMs),
            String(format: "first frame  %.1f ms after process start", firstFrameMs),
            String(format: "memory       %.1f MB footprint after first frame", Metrics.footprintMB()),
        ]
    }
}
