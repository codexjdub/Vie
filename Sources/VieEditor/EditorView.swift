import AppKit
import CoreText
import QuartzCore
import VieSyntax
import VieText
import VieVim

/// The text view. Draws only the visible lines of a buffer with Core Text, caches each line's
/// layout, and handles selection, keyboard commands, mouse, scrolling and IME input itself.
///
/// The code is split across files: layout (`EditorView+Layout`), commands and clipboard
/// (`+Commands`), mouse and scrolling (`+Mouse`), NSTextInputClient (`+TextInput`), Vim
/// mode (`+Vim`) and syntax highlighting (`+Syntax`).
public final class EditorView: NSView, @preconcurrency NSTextInputClient, NSMenuItemValidation {
    public let buffer: Buffer
    public var rope: Rope { buffer.rope }
    public var selection: Selection { buffer.selection }

    /// What the Tab key inserts.
    public var indentation: Indentation = .spaces(4) {
        didSet { if let vim { applyIndentation(to: vim) } }
    }
    /// Pasteboard for cut, copy and paste. Tests swap in a private one.
    public var pasteboard: NSPasteboard = .general

    // Layout metrics: one monospace font, fixed line height (see `fontSize`).
    private(set) var font: CTFont
    let hudFont: CTFont
    var paragraph: CTParagraphStyle
    /// Columns per tab stop; follows Vim's 'tabstop' in Vim mode.
    var tabColumns = 4
    private(set) var lineHeight: CGFloat
    private(set) var baselineOffset: CGFloat
    private(set) var charWidth: CGFloat
    let gutterPadding: CGFloat = 12
    let textInset: CGFloat = 10
    let scrollbarWidth: CGFloat = 10

    // View state.
    /// The row at the top of the view, and how far it's scrolled out of sight (see `+Wrap`).
    var top = RowPosition(line: 0, row: 0)
    var topOffset: CGFloat = 0
    public internal(set) var scrollX: CGFloat = 0
    /// Soft wrap: long lines go on in the rows below instead of scrolling sideways.
    public var wrapsLines = false {
        didSet {
            guard wrapsLines != oldValue else { return }
            vim?.options.wrap = wrapsLines
            top.row = 0
            topOffset = 0
            scrollX = 0
            wrappedWidth = wrapWidth
            dropLayouts { _ in true }
            widestLine = 0
            goalX = nil
            revealCursor()
        }
    }
    /// The width rows were wrapped at.
    var wrappedWidth: CGFloat = 0
    /// What the last frame showed, for the scrollbar: its lines, whether it reached the end of
    /// the text, and whether the text fit.
    var shownLines = 0...0
    var shownEnd = true
    var shownAll = true
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

    // Vim mode.
    /// The Vim engine while Vim mode is on (see `vimEnabled`).
    public internal(set) var vim: VimEngine?
    /// Shared by the engines of one app, so registers and searches carry across buffers.
    /// Set it before turning Vim mode on.
    public var vimSession = VimSession()
    /// Carries out `:w`, `:q`, `:e` and friends; returns an error message to show, or nil.
    public var vimFileHandler: ((VimFileCommand) -> String?)?
    /// Engine calls in progress, and whether the engine asked for a redraw meanwhile (the
    /// cursor is revealed once, after the outermost call).
    var vimCallDepth = 0
    var vimStateChanged = false
    /// Shows the mode, command line, messages and cursor position.
    public weak var statusBar: StatusBarView? {
        didSet { statusBar?.refresh() }
    }

    /// Snapshot tests draw as if focused; a view without a window never is.
    var focusedForTesting: Bool?

    // Per-line layout caches, keyed by line number.
    var lines: [Int: LineEntry] = [:]
    var numberCache: [Int: CTLine] = [:]
    /// The theme generation the caches were laid out in (colors are baked into them).
    var themeGeneration = -1

    // Syntax highlighting.
    /// The file's language; nil for plain text. Files over `syntaxSizeLimit` stay plain.
    public var syntaxLanguage: SyntaxLanguage? {
        didSet { if syntaxLanguage !== oldValue { restartSyntax() } }
    }
    public internal(set) var syntax: SyntaxHighlighter?
    private(set) var boldFont: CTFont
    private(set) var italicFont: CTFont

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
        let faces = EditorFont().faces()
        let m = Self.metrics(faces.regular)
        (font, lineHeight, baselineOffset, charWidth) = (faces.regular, m.lineHeight, m.baselineOffset, m.charWidth)
        (boldFont, italicFont) = (faces.bold, faces.italic)
        hudFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium) as CTFont
        paragraph = Highlighter.paragraphStyle(tabWidth: m.charWidth * 4)
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        buffer.addObserver(self) { [weak self] change in self?.bufferDidChange(change) }
    }

    public required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - Font

    /// The text's font, size and ligatures; the size is kept within `EditorFont.sizes`.
    /// Changing it lays the text out again, keeping the same text at the top, and the cursor
    /// on screen if it was.
    public var editorFont = EditorFont() {
        didSet {
            editorFont.size = min(max(editorFont.size, EditorFont.sizes.lowerBound), EditorFont.sizes.upperBound)
            if editorFont != oldValue { applyFont() }
        }
    }

    /// The size of `editorFont`, in points.
    public var fontSize: CGFloat {
        get { editorFont.size }
        set { editorFont.size = newValue }
    }

    private func applyFont() {
        let caretRow = rowPosition(of: caretOffset)
        let caretShown = visibleRows().contains { $0.pos == caretRow }
        let topUnit = wrapsLines ? rowFragment(top).u0 : 0
        let faces = editorFont.faces()
        let m = Self.metrics(faces.regular)
        let ratio = m.charWidth / charWidth
        (font, lineHeight, baselineOffset, charWidth) = (faces.regular, m.lineHeight, m.baselineOffset, m.charWidth)
        (boldFont, italicFont) = (faces.bold, faces.italic)
        paragraph = Highlighter.paragraphStyle(tabWidth: charWidth * CGFloat(tabColumns))
        dropLayouts { _ in true }
        Self.discard(numberCache)
        numberCache.removeAll()
        goalX = nil
        // Monospaced lines are as wide as their character count, so the widest line and the
        // sideways scroll can follow the character width without laying anything out.
        widestLine *= ratio
        scrollX *= ratio
        wrappedWidth = wrapWidth
        top.row = rowIndex(top.line, unit: topUnit)
        topOffset = 0
        clampScroll()
        if caretShown { revealCursor() }
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    private struct FontMetrics {
        let lineHeight, baselineOffset, charWidth: CGFloat
    }

    private static func metrics(_ font: CTFont) -> FontMetrics {
        let ascent = CTFontGetAscent(font), descent = CTFontGetDescent(font), leading = CTFontGetLeading(font)
        let lineHeight = ceil(ascent + descent + leading) + 4
        var ch: UniChar = 0x30 // "0"
        var glyph = CGGlyph()
        CTFontGetGlyphsForCharacters(font, &ch, &glyph, 1)
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)
        return FontMetrics(lineHeight: lineHeight,
                       baselineOffset: round((lineHeight - (ascent + descent)) / 2 + ascent), charWidth: advance.width)
    }

    public override var isFlipped: Bool { true }

    /// Anything that redraws the text may change what the status bar shows.
    public override var needsDisplay: Bool {
        didSet { statusBar?.refresh() }
    }
    public override var isOpaque: Bool { true }
    public override var acceptsFirstResponder: Bool { true }

    /// The layer redraws only when asked, so a new size asks; otherwise growing the window
    /// draws only the uncovered strip, leaving the old scrollbar and old rows behind.
    public override func setFrameSize(_ newSize: NSSize) {
        let resized = newSize != frame.size
        super.setFrameSize(newSize)
        followWrapWidth()
        clampScroll()
        if resized { needsDisplay = true }
    }

    // MARK: - Focus

    /// The caret shows and the selection is colored only while typing would reach this view.
    var isFocused: Bool { focusedForTesting ?? (window?.isKeyWindow == true && window?.firstResponder === self) }

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
        syntax?.update(rope: buffer.rope, edits: change.edits)
        if change.lineDelta != 0 || change.lastLine == .max || change.lastLine - change.firstLine > lines.count {
            dropLayouts { $0 >= change.firstLine }
        } else {
            let dropped = (change.firstLine...change.lastLine).compactMap { lines.removeValue(forKey: $0) }
            Self.discard(dropped)
        }
        if change.lineDelta != 0 { window?.invalidateCursorRects(for: self) }
        followEdit(change)
        followWrapWidth()
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
    /// The scroll range without wrapping.
    var maxScrollY: CGFloat { max(0, CGFloat(rope.lineCount) * lineHeight - bounds.height) }
    var maxScrollX: CGFloat { wrapsLines ? 0 : max(0, widestLine + charWidth * 2 - textWidth) }

    // MARK: - Drawing

    public override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        followTheme()
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
        let gutter = gutterWidth, textX = gutter + textInset
        let height = bounds.height
        let sel = buffer.selection
        let focused = isFocused
        let block = vim?.visualBlockRanges

        ctx.setFillColor(Theme.background)
        ctx.fill(bounds)

        followWrapWidth()
        let rows = visibleRows()
        let first = rows[0].pos.line, last = rows[rows.count - 1].pos.line
        let caret = caretOffset
        let caretRow = rowPosition(of: caret)
        let caretLine = caretRow.line
        let caretY = rows.first { $0.pos == caretRow }?.y
        if let end = rows.last {
            shownLines = first...last
            shownEnd = end.y + lineHeight <= height + 0.5 && row(after: end.pos) == nil
            shownAll = shownEnd && top == RowPosition(line: 0, row: 0) && topOffset == 0
        }

        if sel.isEmpty && block == nil {
            ctx.setFillColor(Theme.currentLine)
            for (pos, y) in rows where pos.line == caretLine {
                ctx.fill(CGRect(x: gutter, y: y, width: bounds.width - gutter, height: lineHeight))
            }
        }

        // Text area: highlights, selection, text and caret, clipped so horizontal scrolling
        // never draws over the gutter.
        ctx.saveGState()
        ctx.clip(to: CGRect(x: gutter, y: 0, width: bounds.width - gutter, height: height))

        /// Fills the part of `r` on each visible row. A range running past a line end covers
        /// the rest of the row, or one cell with `newlineCell`; an empty range one cell with
        /// `emptyCell`.
        func fill(_ r: Range<Int>, newlineCell: Bool = false, emptyCell: Bool = false) {
            let from = max(first, rope.line(at: r.lowerBound)), to = min(last, rope.line(at: r.upperBound))
            guard from <= to else { return }
            for (pos, y) in rows where pos.line >= from && pos.line <= to {
                let info = info(pos.line)
                let span = byteRange(of: pos)
                let lastRow = span.upperBound >= info.end
                let lo = max(r.lowerBound, span.lowerBound), hi = min(r.upperBound, span.upperBound)
                // A position at a wrap point belongs to the row after it.
                if !lastRow && lo >= span.upperBound { continue }
                let withNewline = lastRow && r.upperBound > info.end
                let pastRow = !lastRow && r.upperBound > span.upperBound
                if lo > hi || (lo == hi && !withNewline && !pastRow && !(emptyCell && r.isEmpty)) { continue }
                let x0 = lo == info.start ? 0 : x(of: lo, line: pos.line)
                var x1: CGFloat
                if pastRow {
                    let f = rowFragment(pos)
                    x1 = f.x0 + f.width
                } else {
                    x1 = x(of: hi, line: pos.line)
                }
                if withNewline { x1 = newlineCell ? x1 + charWidth : scrollX + bounds.width }
                if r.isEmpty { x1 = x0 + charWidth }
                ctx.fill(CGRect(x: textX + x0 - scrollX, y: y, width: x1 - x0, height: lineHeight))
            }
        }

        if let vim {
            let lo = rope.offset(ofLine: first), hi = rope.lineEnd(last)
            if hi - lo <= Self.highlightLimit {
                ctx.setFillColor(Theme.searchMatch)
                for r in vim.searchHighlights(in: lo..<hi) { fill(r, newlineCell: true, emptyCell: true) }
            }
            if let r = vim.incsearchRange {
                ctx.setFillColor(Theme.currentMatch)
                fill(r, newlineCell: true, emptyCell: true)
            }
        }

        ctx.setFillColor(focused ? Theme.selection : Theme.inactiveSelection)
        if let block {
            for r in block where !r.isEmpty { fill(r) }
        } else if !sel.isEmpty {
            fill(sel.range)
        }

        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        let composed = marked != nil && wrapsLines ? composedFragment() : nil
        for (pos, y) in rows {
            let baseline = y + baselineOffset
            if wrapsLines {
                var frag = rowFragment(pos)
                if let composed, composed.line == pos.line, composed.base.u0 == frag.u0 { frag = composed.fragment }
                ctx.textPosition = CGPoint(x: textX + frag.x0, y: baseline)
                CTLineDraw(frag.ct, ctx)
            } else {
                for frag in fragments(pos.line, from: scrollX, to: scrollX + textWidth) {
                    ctx.textPosition = CGPoint(x: textX + frag.x0 - scrollX, y: baseline)
                    CTLineDraw(frag.ct, ctx)
                }
            }
        }

        if let caretY, let vim {
            drawVimCursor(ctx, vim, at: caret, line: caretLine, y: caretY, focused: focused)
        } else if let caretY, sel.isEmpty && focused {
            ctx.setFillColor(Theme.cursor)
            let x = round(textX + caretX() - scrollX)
            ctx.fill(CGRect(x: x, y: caretY + 1, width: 2, height: lineHeight - 2))
        }
        ctx.restoreGState()

        ctx.setFillColor(Theme.gutter)
        ctx.fill(CGRect(x: 0, y: 0, width: gutter, height: height))
        for (pos, y) in rows where pos.row == 0 {
            ctx.textPosition = CGPoint(x: gutter - gutterPadding - CGFloat(digits(pos.line + 1)) * charWidth, y: y + baselineOffset)
            CTLineDraw(numberLine(pos.line + 1), ctx)
        }

        drawScrollbars(ctx)
        trimCaches(around: first)
        trimLongLines(rows)
    }

    /// Search highlighting is skipped when the visible lines hold more bytes than this (a
    /// huge minified line), so drawing stays fast.
    static let highlightLimit = 1 << 20

    /// The Vim cursor: a block in Normal and Visual mode (hollow while the window is inactive
    /// or the command line has the keyboard), a bar in Insert mode, an underline in Replace.
    private func drawVimCursor(_ ctx: CGContext, _ vim: VimEngine, at off: Int, line: Int, y: CGFloat, focused: Bool) {
        let info = info(line)
        let x0 = x(of: off, line: line)
        let width = cellWidth(at: off, line: line)
        let left = textX + x0 - scrollX
        ctx.setFillColor(Theme.cursor)
        ctx.setStrokeColor(Theme.cursor)
        switch vim.cursorShape {
        case .bar where focused:
            ctx.fill(CGRect(x: round(textX + caretX() - scrollX), y: y + 1, width: 2, height: lineHeight - 2))
        case .underline where focused:
            ctx.fill(CGRect(x: left, y: y + lineHeight - 3, width: width, height: 2))
        case .block where focused && vim.mode != .commandLine:
            ctx.fill(CGRect(x: left, y: y, width: width, height: lineHeight))
            // The character under the block, in the background color.
            if off < info.end {
                let s = rope.string(in: off..<rope.nextGraphemeBoundary(after: off))
                if s != "\t" && s != " " {
                    let ct = CTLineCreateWithAttributedString(Highlighter.plain(s, font: font, color: Theme.background) as CFAttributedString)
                    ctx.textPosition = CGPoint(x: left, y: y + baselineOffset)
                    CTLineDraw(ct, ctx)
                }
            }
        default:
            ctx.setLineWidth(1)
            ctx.stroke(CGRect(x: left, y: y, width: width, height: lineHeight).insetBy(dx: 0.5, dy: 0.5))
        }
    }

    private func numberLine(_ n: Int) -> CTLine {
        if let c = numberCache[n] { return c }
        let ct = CTLineCreateWithAttributedString(Highlighter.plain(String(n), font: font, color: Theme.lineNumber) as CFAttributedString)
        numberCache[n] = ct
        return ct
    }

    private func trimCaches(around first: Int) {
        if lines.count > 1500 { dropLayouts { abs($0 - first) >= 400 } }
        if numberCache.count > 1500 {
            let old = numberCache
            numberCache = numberCache.filter { abs($0.key - first) < 400 }
            Self.discard(old)
        }
    }

    /// A long line on screen keeps the rows (or, without wrapping, the windows) near the view;
    /// scrolling through a 50 MB line would otherwise keep every row it passed.
    private func trimLongLines(_ rows: [(pos: RowPosition, y: CGFloat)]) {
        var seen = Set<Int>()
        for (pos, _) in rows where seen.insert(pos.line).inserted {
            guard var entry = lines[pos.line], entry.longRows.count > 600 || entry.far.count > 600 else { continue }
            let rows = entry.longRows, far = entry.far
            entry.longRows = rows.filter { abs($0.key - pos.row) < 300 }
            let window = Int(max(0, scrollX - (entry.prefix?.width ?? 0)) / (CGFloat(Self.farWindow) * charWidth))
            entry.far = far.filter { abs($0.key - window) < 300 }
            lines[pos.line] = entry
            Self.discard((rows, far))
        }
    }

    /// Drops the cached layouts of the lines `drop` picks. They're freed on a background queue:
    /// releasing a thousand laid-out lines takes milliseconds (more with syntax colors, which
    /// make more runs), enough to make a frame miss its budget.
    func dropLayouts(where drop: (Int) -> Bool) {
        let old = lines
        lines = lines.filter { !drop($0.key) }
        Self.discard(old)
    }

    /// Releases `value`, and whatever only it holds, on a background queue.
    static func discard<T>(_ value: T) {
        let box = Discarded(value)
        discardQueue.async { withExtendedLifetime(box) {} }
    }

    nonisolated private static let discardQueue = DispatchQueue(label: "Vie.layout.free", qos: .utility)

    // MARK: - Scrollbars

    enum ScrollbarAxis { case vertical, horizontal }

    /// Whether there's text above or below the view.
    var canScrollVertically: Bool { wrapsLines ? !shownAll : maxScrollY > 0 }

    /// The vertical scroller's thumb. With wrapping, rows are known only near the view, so it
    /// goes by lines.
    var verticalThumb: CGRect {
        guard canScrollVertically else { return .zero }
        let h = bounds.height, lines = CGFloat(rope.lineCount)
        let thumbH: CGFloat, fraction: CGFloat
        if wrapsLines {
            thumbH = min(h, max(28, h * CGFloat(shownLines.count) / lines))
            fraction = shownEnd ? 1 : min(1, scrollY / lineHeight / max(1, lines - 1))
        } else {
            thumbH = max(28, h * h / (lines * lineHeight))
            fraction = scrollY / maxScrollY
        }
        return CGRect(x: bounds.width - scrollbarWidth + 2, y: fraction * (h - thumbH), width: scrollbarWidth - 4, height: thumbH)
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

/// Carries layouts to the queue that frees them (Core Text lines are safe to release anywhere).
private final class Discarded<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
