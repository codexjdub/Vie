import AppKit
import CoreText
import QuartzCore
import VieText

/// The text view. Draws only the visible lines of a buffer with Core Text, caches each line's
/// layout, and handles selection, keyboard commands, mouse, scrolling and IME input itself.
///
/// The code is split across files: layout (`EditorView+Layout`), commands and clipboard
/// (`+Commands`), mouse and scrolling (`+Mouse`), and NSTextInputClient (`+TextInput`).
public final class EditorView: NSView, @preconcurrency NSTextInputClient, NSMenuItemValidation {
    public let buffer: Buffer
    public var rope: Rope { buffer.rope }
    public var selection: Selection { buffer.selection }

    /// What the Tab key inserts.
    public var indentation: Indentation = .spaces(4)
    /// Pasteboard for cut, copy and paste. Tests swap in a private one.
    public var pasteboard: NSPasteboard = .general

    // Layout metrics: one monospace font, fixed line height.
    let font: CTFont
    let hudFont: CTFont
    let paragraph: CTParagraphStyle
    let lineHeight: CGFloat
    let baselineOffset: CGFloat
    let charWidth: CGFloat
    let gutterPadding: CGFloat = 12
    let textInset: CGFloat = 10
    let scrollbarWidth: CGFloat = 10

    // View state.
    public internal(set) var scrollY: CGFloat = 0
    public internal(set) var scrollX: CGFloat = 0
    /// Remembered x for up/down movement, so the cursor keeps its column across short lines.
    var goalX: CGFloat?
    /// IME composition, drawn inline at the cursor but not yet in the buffer.
    var marked: String?
    var markedSelection = NSRange(location: 0, length: 0)
    var draggingScrollbar: ScrollbarAxis?
    /// Text removed by ⌃K, inserted again by ⌃Y.
    var killBuffer: [UInt8] = []
    /// Widest line laid out so far (an estimate for very long lines); sets the horizontal
    /// scroll range.
    var widestLine: CGFloat = 0

    // Per-line layout caches, keyed by line number.
    var lines: [Int: LineEntry] = [:]
    var numberCache: [Int: CTLine] = [:]

    // Measurement.
    public var showHUD = false
    /// Time each frame rendered into an offscreen bitmap at this scale (simulated Retina).
    public var forcedScale: CGFloat?
    /// Called once, after the first frame is drawn, with ms since process start.
    public var onFirstDraw: ((Double) -> Void)?
    public private(set) var lastDrawMs = 0.0
    public private(set) var drawCount = 0
    public private(set) var deviceScale: CGFloat = 1
    public let drawStats = Stats()
    public let keyStats = Stats()
    public let editStats = Stats()
    var lastEditMs: Double?
    var pendingKeyTime: CFTimeInterval?
    private var firstDrawMs: Double?
    private var recent = [Double](repeating: 0, count: 120)
    private var memoryText = ""
    private var offscreen: CGContext?

    public init(frame: NSRect, buffer: Buffer) {
        self.buffer = buffer
        font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular) as CTFont
        hudFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium) as CTFont
        let ascent = CTFontGetAscent(font), descent = CTFontGetDescent(font), leading = CTFontGetLeading(font)
        lineHeight = ceil(ascent + descent + leading) + 4
        baselineOffset = round((lineHeight - (ascent + descent)) / 2 + ascent)
        var ch: UniChar = 0x30 // "0"
        var glyph = CGGlyph()
        CTFontGetGlyphsForCharacters(font, &ch, &glyph, 1)
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)
        charWidth = advance.width
        paragraph = Highlighter.paragraphStyle(tabWidth: advance.width * 4)
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        buffer.addObserver(self) { [weak self] change in self?.bufferDidChange(change) }
    }

    public required init?(coder: NSCoder) { fatalError("not used") }

    public override var isFlipped: Bool { true }
    public override var isOpaque: Bool { true }
    public override var acceptsFirstResponder: Bool { true }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        clampScroll()
    }

    // MARK: - Focus

    /// The caret shows and the selection is colored only while typing would reach this view.
    var isFocused: Bool { window?.isKeyWindow == true && window?.firstResponder === self }

    public override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return true
    }

    public override func resignFirstResponder() -> Bool {
        if marked != nil { unmarkText() }
        needsDisplay = true
        return true
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let center = NotificationCenter.default
        center.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
        center.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        guard let window else { return }
        center.addObserver(self, selector: #selector(windowKeyChanged), name: NSWindow.didBecomeKeyNotification, object: window)
        center.addObserver(self, selector: #selector(windowKeyChanged), name: NSWindow.didResignKeyNotification, object: window)
    }

    @objc private func windowKeyChanged(_ note: Notification) { needsDisplay = true }

    // MARK: - Buffer changes

    func bufferDidChange(_ change: BufferChange) {
        if change.lineDelta != 0 || change.lastLine == .max || change.lastLine - change.firstLine > lines.count {
            lines = lines.filter { $0.key < change.firstLine }
        } else {
            for line in change.firstLine...change.lastLine { lines[line] = nil }
        }
        if change.lineDelta != 0 { window?.invalidateCursorRects(for: self) }
        clampScroll()
        needsDisplay = true
    }

    // MARK: - Geometry

    func digits(_ n: Int) -> Int {
        var n = n, d = 1
        while n >= 10 { n /= 10; d += 1 }
        return d
    }

    var gutterWidth: CGFloat { CGFloat(max(3, digits(rope.lineCount))) * charWidth + gutterPadding * 2 }
    var textX: CGFloat { gutterWidth + textInset }
    /// Width of the area text is drawn in.
    var textWidth: CGFloat { max(charWidth, bounds.width - textX - scrollbarWidth) }
    var maxScrollY: CGFloat { max(0, CGFloat(rope.lineCount) * lineHeight - bounds.height) }
    var maxScrollX: CGFloat { max(0, widestLine + charWidth * 2 - textWidth) }

    func clampScroll() {
        scrollY = min(max(scrollY, 0), maxScrollY)
        scrollX = min(max(scrollX, 0), maxScrollX)
    }

    // MARK: - Drawing

    public override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let ms: Double
        if let scale = forcedScale, let offscreen = offscreenContext(scale: scale) {
            // Simulated Retina: time a render into a bitmap at `scale`, then draw the
            // on-screen copy untimed.
            let t0 = CACurrentMediaTime()
            render(offscreen)
            ms = (CACurrentMediaTime() - t0) * 1000
            deviceScale = scale
            render(ctx)
        } else {
            let t0 = CACurrentMediaTime()
            render(ctx)
            ms = (CACurrentMediaTime() - t0) * 1000
            deviceScale = abs(ctx.userSpaceToDeviceSpaceTransform.a)
        }

        lastDrawMs = ms
        drawStats.record(ms)
        recent[drawCount % recent.count] = ms
        drawCount += 1
        if let k = pendingKeyTime {
            let latency = (CACurrentMediaTime() - k) * 1000
            if latency >= 0 && latency < 1000 { keyStats.record(latency) }
            pendingKeyTime = nil
        }
        if showHUD { drawHUD(ctx) }
        if onFirstDraw != nil && firstDrawMs == nil {
            firstDrawMs = (Metrics.secondsSinceProcessStart() ?? 0) * 1000
            perform(#selector(fireFirstDraw), with: nil, afterDelay: 0)
        }
    }

    @objc private func fireFirstDraw() {
        guard let callback = onFirstDraw, let ms = firstDrawMs else { return }
        onFirstDraw = nil
        callback(ms)
    }

    private func offscreenContext(scale: CGFloat) -> CGContext? {
        let w = Int(bounds.width * scale), h = Int(bounds.height * scale)
        if let c = offscreen, c.width == w, c.height == h { return c }
        guard let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        c.translateBy(x: 0, y: CGFloat(h)) // flip to match the view's top-left origin
        c.scaleBy(x: scale, y: -scale)
        offscreen = c
        return c
    }

    /// Draws the visible lines, selection, gutter, caret and scrollbars. Everything here scales
    /// with the number of visible lines, never with file size.
    func render(_ ctx: CGContext) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        let lineCount = rope.lineCount
        let gutter = gutterWidth, textX = gutter + textInset
        let height = bounds.height
        let sel = buffer.selection
        let focused = isFocused

        ctx.setFillColor(Theme.background)
        ctx.fill(bounds)

        let first = min(Int(scrollY / lineHeight), lineCount - 1)
        let last = min(lineCount - 1, first + Int(ceil(height / lineHeight)))
        let top = CGFloat(first) * lineHeight - scrollY
        let headLine = rope.line(at: sel.head)
        let headVisible = (first...last).contains(headLine)
        func rowY(_ line: Int) -> CGFloat { top + CGFloat(line - first) * lineHeight }

        if sel.isEmpty && headVisible {
            ctx.setFillColor(Theme.currentLine)
            ctx.fill(CGRect(x: gutter, y: rowY(headLine), width: bounds.width - gutter, height: lineHeight))
        }

        // Text area: selection, text and caret, clipped so horizontal scrolling never draws
        // over the gutter.
        ctx.saveGState()
        ctx.clip(to: CGRect(x: gutter, y: 0, width: bounds.width - gutter, height: height))
        if !sel.isEmpty {
            ctx.setFillColor(focused ? Theme.selection : Theme.inactiveSelection)
            let from = max(first, rope.line(at: sel.lowerBound)), to = min(last, rope.line(at: sel.upperBound))
            if from <= to {
                for line in from...to {
                    let info = info(line)
                    let lo = max(sel.lowerBound, info.start), hi = min(sel.upperBound, info.end)
                    let withNewline = sel.upperBound > info.end
                    if lo > hi || (lo == hi && !withNewline) { continue }
                    let x0 = lo == info.start ? 0 : x(of: lo, line: line)
                    let x1 = withNewline ? scrollX + bounds.width : x(of: hi, line: line)
                    ctx.fill(CGRect(x: textX + x0 - scrollX, y: rowY(line), width: x1 - x0, height: lineHeight))
                }
            }
        }

        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        for line in first...last {
            let baseline = rowY(line) + baselineOffset
            for frag in fragments(line, from: scrollX, to: scrollX + textWidth) {
                ctx.textPosition = CGPoint(x: textX + frag.x0 - scrollX, y: baseline)
                CTLineDraw(frag.ct, ctx)
            }
        }

        if sel.isEmpty && headVisible && focused {
            ctx.setFillColor(Theme.cursor)
            let x = round(textX + caretX() - scrollX)
            ctx.fill(CGRect(x: x, y: rowY(headLine) + 1, width: 2, height: lineHeight - 2))
        }
        ctx.restoreGState()

        ctx.setFillColor(Theme.gutter)
        ctx.fill(CGRect(x: 0, y: 0, width: gutter, height: height))
        for line in first...last {
            ctx.textPosition = CGPoint(x: gutter - gutterPadding - CGFloat(digits(line + 1)) * charWidth, y: rowY(line) + baselineOffset)
            CTLineDraw(numberLine(line + 1), ctx)
        }

        drawScrollbars(ctx)
        trimCaches(around: first)
    }

    private func numberLine(_ n: Int) -> CTLine {
        if let c = numberCache[n] { return c }
        let ct = CTLineCreateWithAttributedString(Highlighter.plain(String(n), font: font, color: Theme.lineNumber) as CFAttributedString)
        numberCache[n] = ct
        return ct
    }

    private func trimCaches(around first: Int) {
        if lines.count > 1500 { lines = lines.filter { abs($0.key - first) < 400 } }
        if numberCache.count > 1500 { numberCache = numberCache.filter { abs($0.key - first) < 400 } }
    }

    // MARK: - Scrollbars

    enum ScrollbarAxis { case vertical, horizontal }

    var verticalThumb: CGRect {
        let h = bounds.height
        let content = CGFloat(rope.lineCount) * lineHeight
        guard content > h else { return .zero }
        let thumbH = max(28, h * h / content)
        let y = maxScrollY > 0 ? (scrollY / maxScrollY) * (h - thumbH) : 0
        return CGRect(x: bounds.width - scrollbarWidth + 2, y: y, width: scrollbarWidth - 4, height: thumbH)
    }

    var horizontalThumb: CGRect {
        guard maxScrollX > 0 else { return .zero }
        let track = bounds.width - gutterWidth - scrollbarWidth
        let thumbW = max(28, track * textWidth / (widestLine + charWidth * 2))
        let x = gutterWidth + (scrollX / maxScrollX) * (track - thumbW)
        return CGRect(x: x, y: bounds.height - scrollbarWidth + 2, width: thumbW, height: scrollbarWidth - 4)
    }

    private func drawScrollbars(_ ctx: CGContext) {
        ctx.setFillColor(Theme.scrollbar)
        for r in [verticalThumb, horizontalThumb] where r != .zero {
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: 3, cornerHeight: 3, transform: nil))
            ctx.fillPath()
        }
    }

    // MARK: - HUD

    private func drawHUD(_ ctx: CGContext) {
        let n = min(drawCount, recent.count)
        let sorted = recent[0..<n].sorted()
        let p95 = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        if memoryText.isEmpty || drawCount % 30 == 0 {
            memoryText = String(format: "mem %.0f MB", Metrics.footprintMB())
        }
        let key = keyStats.count > 0 ? String(format: "%.2f ms", keyStats.last) : "type to measure"
        let lines = [
            String(format: "draw  %.2f ms   p95 %.2f ms", lastDrawMs, p95),
            "key → drawn  \(key)",
            String(format: "%@ lines · %.1f MB · %@", rope.lineCount.formatted(), Double(rope.byteCount) / 1_048_576, memoryText),
        ]
        let lh: CGFloat = 16
        let r = CGRect(x: bounds.width - 330 - scrollbarWidth - 12, y: 12, width: 330, height: CGFloat(lines.count) * lh + 14)
        ctx.setFillColor(Theme.hudBackground)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: 8, cornerHeight: 8, transform: nil))
        ctx.fillPath()
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        for (i, s) in lines.enumerated() {
            let ct = CTLineCreateWithAttributedString(Highlighter.plain(s, font: hudFont, color: Theme.hudText) as CFAttributedString)
            ctx.textPosition = CGPoint(x: r.minX + 12, y: r.minY + 19 + CGFloat(i) * lh)
            CTLineDraw(ct, ctx)
        }
    }
}
