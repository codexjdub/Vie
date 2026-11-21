import AppKit
import QuartzCore
import VieEditor
import VieSyntax
import VieText
import VieVim

/// Drives the editor one step per display refresh and records, per phase: time spent in
/// draw(_:), total frame work (edit + redraw), edit time (rope change, undo record and change
/// notifications), and vsyncs the main thread missed. With syntax highlighting it waits for
/// the first parse, then also records background parse times and the redraws when they land.
@MainActor
final class Bench: NSObject {
    private final class Phase {
        let name: String
        let frames: Int
        let setup: (EditorView) -> Void
        let step: (EditorView, Int) -> Void
        let draw = Stats(), work = Stats(), edit = Stats()
        var dropped = 0
        var noDraw = 0

        init(_ name: String, _ frames: Int, setup: @escaping (EditorView) -> Void = { _ in },
             step: @escaping (EditorView, Int) -> Void) {
            self.name = name
            self.frames = frames
            self.setup = setup
            self.step = step
        }
    }

    private let view: EditorView
    private let header: [String]
    private var phases: [Phase] = []
    private var index = 0
    private var frame = -1
    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0
    private var period: CFTimeInterval = 1.0 / 60
    private var firstParseMs: Double?
    private var parseCount = 0
    private var drawsSeen = 0
    private let parses = Stats(), parseRedraws = Stats()

    init(view: EditorView, header: [String], typeLine: Int?) {
        self.view = view
        self.header = header
        let lines = view.rope.lineCount
        var rng = SeededGenerator(seed: 7)
        let jumps = (0..<120).map { _ in rng.int(lines) }
        let typed = "let total = compute(42) // typed\n".map { String($0) }
        let typeAt = typeLine ?? lines / 2
        super.init()
        phases = [
            Phase("scroll 40 pt/frame", 480, setup: { $0.scroll(toLine: 0) }, step: { v, _ in v.scroll(by: 40) }),
            Phase("fling 400 pt/frame", 240, step: { v, _ in v.scroll(by: 400) }),
            Phase("jump to random line", 120, step: { v, i in v.scroll(toLine: jumps[i]) }),
            // In Vim mode typing goes through Insert mode, and cursor down is `j`.
            Phase("type at line \(typeAt.formatted())", 480, setup: { v in
                v.moveCursor(toLine: typeAt)
                v.vim?.handle(VimKey("i"))
            }, step: { v, i in v.insert(typed[i % typed.count]) }),
            Phase("backspace", 240, step: { v, _ in v.deleteBackward() }),
            Phase("cursor down", 240, setup: { v in v.vim?.handle(.escape) }, step: { v, _ in v.moveCursor(lines: 1) }),
        ]
    }

    func start() {
        let l = view.displayLink(target: self, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
        perform(#selector(timedOut), with: nil, afterDelay: 300)
    }

    @objc private func timedOut() {
        finish(note: "timed out; was the window hidden or the display asleep?")
    }

    @objc private func tick(_ link: CADisplayLink) {
        let p = link.targetTimestamp - link.timestamp
        if p > 0.001 { period = p }
        let phase = phases[index]

        // Phases time highlighted text, so wait (unmeasured) for the first parse.
        if let syntax = view.syntax, firstParseMs == nil {
            guard syntax.isReady else { return }
            firstParseMs = syntax.lastParseMs
            parseCount = syntax.parseCount
        }

        if frame < 0 { // setup frame, not measured
            phase.setup(view)
            view.needsDisplay = true
            view.displayIfNeeded()
            _ = view.takeLastEditMs()
            frame = 0
            lastTimestamp = link.timestamp
            drawsSeen = view.drawCount
            return
        }

        // A parse that landed since the last frame may have redrawn the view in between.
        if let syntax = view.syntax, syntax.parseCount != parseCount {
            parseCount = syntax.parseCount
            parses.record(syntax.lastParseMs)
            if view.drawCount != drawsSeen { parseRedraws.record(view.lastDrawMs) }
        }

        let skipped = Int(((link.timestamp - lastTimestamp) / period).rounded()) - 1
        if skipped > 0 { phase.dropped += skipped }
        lastTimestamp = link.timestamp

        let drawsBefore = view.drawCount
        let t0 = CACurrentMediaTime()
        phase.step(view, frame)
        view.needsDisplay = true
        view.displayIfNeeded()
        phase.work.record((CACurrentMediaTime() - t0) * 1000)
        if view.drawCount == drawsBefore { phase.noDraw += 1 } else { phase.draw.record(view.lastDrawMs) }
        if let e = view.takeLastEditMs() { phase.edit.record(e * 1000) }
        drawsSeen = view.drawCount

        frame += 1
        if frame == phase.frames {
            index += 1
            frame = -1
            if index == phases.count { finish(note: nil) }
        }
    }

    private func finish(note: String?) {
        guard link != nil else { return }
        link?.invalidate()
        link = nil
        NSObject.cancelPreviousPerformRequests(withTarget: self)
        var out = header
        out.append(String(format: "display      %.0f Hz (%.2f ms per frame), backing scale %.0fx%@, view %.0f×%.0f pt",
                          1 / period, period * 1000, view.deviceScale,
                          view.forcedScale != nil ? " (timed offscreen)" : "", view.bounds.width, view.bounds.height))
        if let syntax = view.syntax {
            out.append(String(format: "syntax       %@, first parse %.1f ms (in the background)", syntax.language.displayName, firstParseMs ?? 0))
        } else {
            out.append("syntax       off (no language, or over the \(EditorView.syntaxSizeLimit / 1_048_576) MB limit)")
        }
        out.append("")
        out.append("phase                   frames │ draw ms  p50    p95    max │ frame work ms  p95    max │ missed vsyncs")
        for p in phases where p.work.count > 0 {
            out.append(p.name.padding(toLength: 22, withPad: " ", startingAt: 0)
                + String(format: "  %6d │       %6.2f %6.2f %6.2f │             %6.2f %6.2f │ %d",
                         p.work.count, p.draw.percentile(0.5), p.draw.percentile(0.95), p.draw.max,
                         p.work.percentile(0.95), p.work.max, p.dropped))
            if p.noDraw > 0 { out.append("  warning: \(p.noDraw) frames did not redraw") }
        }
        let edits = Stats()
        for p in phases { edits.merge(p.edit) }
        if edits.count > 0 {
            out.append("")
            out.append("edit         " + edits.describe(unit: "µs"))
        }
        if parses.count > 0 {
            out.append("reparse      " + parses.describe(unit: "ms, in the background after edits"))
        }
        if parseRedraws.count > 0 {
            out.append("redraw       " + parseRedraws.describe(unit: "ms, between frames when a reparse landed"))
        }
        out.append(String(format: "memory       %.1f MB footprint at end", Metrics.footprintMB()))
        if let note { out.append("note: " + note) }
        print(out.joined(separator: "\n"))
        fflush(stdout)
        NSApp.terminate(nil)
    }
}
