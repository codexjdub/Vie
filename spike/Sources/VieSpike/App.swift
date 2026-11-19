import AppKit

struct Options {
    var path: String?
    var bench = false
    var launchOnly = false
    var scale: CGFloat?
    var typeLine: Int?

    init(_ args: [String]) {
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--bench": bench = true
            case "--launch": launchOnly = true
            case "--scale":
                i += 1
                if i < args.count, let s = Double(args[i]) { scale = CGFloat(s) }
            case "--type-line":
                i += 1
                if i < args.count { typeLine = Int(args[i]) }
            default: path = args[i]
            }
            i += 1
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let rope: Rope
    private let options: Options
    private let openMs: Double
    private var window: NSWindow!
    private var view: EditorView!
    private var bench: Bench?
    private var firstFrameMs = 0.0

    init(rope: Rope, options: Options, openMs: Double) {
        self.rope = rope
        self.options = options
        self.openMs = openMs
        super.init()
    }

    private var fileName: String {
        options.path.map { ($0 as NSString).lastPathComponent } ?? "(empty)"
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        let rect = NSRect(x: 0, y: 0, width: 1600, height: 1000)
        window = NSWindow(contentRect: rect, styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "VieSpike — \(fileName)"
        window.isReleasedWhenClosed = false
        view = EditorView(frame: rect, rope: rope)
        view.forcedScale = options.scale
        view.showHUD = !(options.bench || options.launchOnly)
        view.onFirstDraw = { [unowned self] ms in self.didDrawFirstFrame(ms) }
        window.contentView = view
        window.center()
        window.makeFirstResponder(view)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private var header: [String] {
        [
            "VieSpike — \(fileName)",
            String(format: "file         %.1f MB, %@ lines", Double(rope.byteCount) / 1_048_576, rope.lineCount.formatted()),
            String(format: "open         %.1f ms (map file + build rope)", openMs),
            String(format: "first frame  %.1f ms after process start", firstFrameMs),
            String(format: "memory       %.1f MB footprint after first frame", Metrics.footprintMB()),
        ]
    }

    private func didDrawFirstFrame(_ ms: Double) {
        firstFrameMs = ms
        if options.launchOnly {
            print(String(format: "first frame %.1f ms after process start · open %.1f ms · memory %.1f MB",
                         ms, openMs, Metrics.footprintMB()))
            fflush(stdout)
            NSApp.terminate(nil)
            return
        }
        if options.bench {
            let b = Bench(view: view, header: header, typeLine: options.typeLine)
            bench = b
            b.start()
        } else {
            print(header.joined(separator: "\n"))
            print("interactive: scroll, type, click, drag the scrollbar. ⌘Q prints stats.")
            fflush(stdout)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard !options.bench, !options.launchOnly else { return }
        print("interactive session")
        print("  draw        " + view.drawStats.describe(unit: "ms"))
        if view.keyStats.count > 0 { print("  key→drawn   " + view.keyStats.describe(unit: "ms")) }
        if view.editStats.count > 0 { print("  rope edit   " + view.editStats.describe(unit: "µs")) }
        fflush(stdout)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit VieSpike", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        NSApp.mainMenu = main
    }
}
