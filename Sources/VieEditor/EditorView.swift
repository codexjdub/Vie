import AppKit
import CoreText
import QuartzCore
import VieText

/// The text view. Draws only the visible lines of a rope with Core Text, caches each line's
/// layout, and handles scrolling, typing and IME input (NSTextInputClient) itself.
///
/// M0 state: ported from the spike. Selection, undo, saving and Vim arrive in M1–M2.
public final class EditorView: NSView, @preconcurrency NSTextInputClient {
    public let rope: Rope

    // Layout metrics: one monospace font, fixed line height.
    private let font: CTFont
    private let hudFont: CTFont
    private let paragraph: CTParagraphStyle
    private let lineHeight: CGFloat
    private let baselineOffset: CGFloat
    private let charWidth: CGFloat
    private let gutterPadding: CGFloat = 12
    private let textInset: CGFloat = 10
    private let scrollbarWidth: CGFloat = 10

    // Editor state.
    public private(set) var scrollY: CGFloat = 0
    public private(set) var cursor = 0 // byte offset
    public private(set) var isModified = false
    private var goalColumn: Int?
    private var marked: String? // IME composition, drawn inline at the cursor
    private var markedSelection = NSRange(location: 0, length: 0)
    private var draggingScrollbar = false

    // Per-line layout caches, keyed by line number.
    private var lineCache: [Int: CTLine] = [:]
    private var numberCache: [Int: CTLine] = [:]

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
    private var lastEditMs: Double?
    private var pendingKeyTime: CFTimeInterval?
    private var firstDrawMs: Double?
    private var recent = [Double](repeating: 0, count: 120)
    private var memoryText = ""
    private var offscreen: CGContext?

    public init(frame: NSRect, rope: Rope) {
        self.rope = rope
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
    }

    public required init?(coder: NSCoder) { fatalError("not used") }

    public override var isFlipped: Bool { true }
    public override var isOpaque: Bool { true }
    public override var acceptsFirstResponder: Bool { true }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        lineCache.removeAll() // visible width changed
        clampScroll()
    }

    // MARK: - Geometry

    private func digits(_ n: Int) -> Int {
        var n = n, d = 1
        while n >= 10 { n /= 10; d += 1 }
        return d
    }

    private var gutterWidth: CGFloat { CGFloat(max(3, digits(rope.lineCount))) * charWidth + gutterPadding * 2 }
    private var textX: CGFloat { gutterWidth + textInset }
    private var visibleColumns: Int { max(1, Int((bounds.width - textX - scrollbarWidth) / charWidth) + 1) }
    private var maxScroll: CGFloat { max(0, CGFloat(rope.lineCount) * lineHeight - bounds.height) }

    private func clampScroll() { scrollY = min(max(scrollY, 0), maxScroll) }

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

    /// Draws the visible lines, gutter, cursor and scrollbar. Everything here scales with the
    /// number of visible lines, never with file size.
    private func render(_ ctx: CGContext) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        let lineCount = rope.lineCount
        let gutter = gutterWidth, textX = gutter + textInset
        let height = bounds.height

        ctx.setFillColor(Theme.background)
        ctx.fill(bounds)
        ctx.setFillColor(Theme.gutter)
        ctx.fill(CGRect(x: 0, y: 0, width: gutter, height: height))

        let first = min(Int(scrollY / lineHeight), lineCount - 1)
        let last = min(lineCount - 1, first + Int(ceil(height / lineHeight)))
        let top = CGFloat(first) * lineHeight - scrollY
        let cursorLine = rope.line(at: cursor)
        let cursorVisible = (first...last).contains(cursorLine)
        let cols = visibleColumns

        if cursorVisible {
            ctx.setFillColor(Theme.currentLine)
            ctx.fill(CGRect(x: gutter, y: top + CGFloat(cursorLine - first) * lineHeight,
                            width: bounds.width - gutter, height: lineHeight))
        }

        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        for line in first...last {
            let baseline = top + CGFloat(line - first) * lineHeight + baselineOffset
            ctx.textPosition = CGPoint(x: gutter - gutterPadding - CGFloat(digits(line + 1)) * charWidth, y: baseline)
            CTLineDraw(numberLine(line + 1), ctx)
            ctx.textPosition = CGPoint(x: textX, y: baseline)
            CTLineDraw(textLine(line, isCursorLine: line == cursorLine, columns: cols), ctx)
        }

        if cursorVisible {
            let r = caretRect()
            ctx.setFillColor(Theme.cursor)
            ctx.fill(CGRect(x: round(r.minX), y: r.minY + 1, width: 2, height: r.height - 2))
        }

        drawScrollbar(ctx)
        trimCaches(around: first)
    }

    private func numberLine(_ n: Int) -> CTLine {
        if let c = numberCache[n] { return c }
        let ct = CTLineCreateWithAttributedString(Highlighter.plain(String(n), font: font, color: Theme.lineNumber) as CFAttributedString)
        numberCache[n] = ct
        return ct
    }

    /// Layout for the visible part of a line: at most `columns` characters, so a 50 MB line
    /// costs the same as a short one.
    private func textLine(_ line: Int, isCursorLine: Bool, columns: Int) -> CTLine {
        if isCursorLine, let m = marked {
            let start = rope.offset(ofLine: line)
            let before = String(decoding: rope.bytes(from: start, maxBytes: cursor - start), as: UTF8.self)
            let after = String(decoding: rope.bytes(from: cursor, maxScalars: columns), as: UTF8.self)
            let attr = Highlighter.highlight(before + m + after, font: font, paragraph: paragraph)
            attr.addAttribute(Highlighter.underlineKey, value: NSNumber(value: CTUnderlineStyle.single.rawValue),
                              range: NSRange(location: before.utf16.count, length: m.utf16.count))
            return CTLineCreateWithAttributedString(attr as CFAttributedString)
        }
        if let c = lineCache[line] { return c }
        let bytes = rope.bytes(from: rope.offset(ofLine: line), maxScalars: columns)
        let attr = Highlighter.highlight(String(decoding: bytes, as: UTF8.self), font: font, paragraph: paragraph)
        let ct = CTLineCreateWithAttributedString(attr as CFAttributedString)
        lineCache[line] = ct
        return ct
    }

    private func caretRect() -> CGRect {
        let line = rope.line(at: cursor)
        let start = rope.offset(ofLine: line)
        var index = Summary.of(rope.bytes(from: start, maxBytes: cursor - start)).utf16
        if marked != nil { index += markedSelection.location }
        let ct = textLine(line, isCursorLine: true, columns: visibleColumns)
        let x = textX + CTLineGetOffsetForStringIndex(ct, index, nil)
        return CGRect(x: x, y: CGFloat(line) * lineHeight - scrollY, width: 2, height: lineHeight)
    }

    private var thumbRect: CGRect {
        let h = bounds.height
        let content = CGFloat(rope.lineCount) * lineHeight
        guard content > h else { return .zero }
        let thumbH = max(28, h * h / content)
        let y = maxScroll > 0 ? (scrollY / maxScroll) * (h - thumbH) : 0
        return CGRect(x: bounds.width - scrollbarWidth + 2, y: y, width: scrollbarWidth - 4, height: thumbH)
    }

    private func drawScrollbar(_ ctx: CGContext) {
        let r = thumbRect
        guard r != .zero else { return }
        ctx.setFillColor(Theme.scrollbar)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: 3, cornerHeight: 3, transform: nil))
        ctx.fillPath()
    }

    private func trimCaches(around first: Int) {
        if lineCache.count > 1500 { lineCache = lineCache.filter { abs($0.key - first) < 400 } }
        if numberCache.count > 1500 { numberCache = numberCache.filter { abs($0.key - first) < 400 } }
    }

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
        for (i, s) in lines.enumerated() {
            let ct = CTLineCreateWithAttributedString(Highlighter.plain(s, font: hudFont, color: Theme.hudText) as CFAttributedString)
            ctx.textPosition = CGPoint(x: r.minX + 12, y: r.minY + 19 + CGFloat(i) * lh)
            CTLineDraw(ct, ctx)
        }
    }

    // MARK: - Scrolling and mouse

    public override func scrollWheel(with event: NSEvent) {
        let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * lineHeight * 3
        scroll(by: -dy)
    }

    public func scroll(by dy: CGFloat) {
        scrollY += dy
        clampScroll()
        needsDisplay = true
    }

    public func scroll(toLine line: Int) {
        scrollY = CGFloat(line) * lineHeight
        clampScroll()
        needsDisplay = true
    }

    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        if p.x >= bounds.width - scrollbarWidth {
            draggingScrollbar = true
            dragScrollbar(to: p.y)
            return
        }
        if marked != nil { unmarkText() }
        let line = max(0, min(Int((p.y + scrollY) / lineHeight), rope.lineCount - 1))
        let ct = textLine(line, isCursorLine: false, columns: visibleColumns)
        var index = CTLineGetStringIndexForPosition(ct, CGPoint(x: p.x - textX, y: 0))
        if index == kCFNotFound { index = 0 }
        let start = rope.offset(ofLine: line)
        cursor = start + byteOffset(forUTF16: index, in: rope.bytes(from: start, maxScalars: visibleColumns))
        goalColumn = nil
        needsDisplay = true
    }

    public override func mouseDragged(with event: NSEvent) {
        if draggingScrollbar { dragScrollbar(to: convert(event.locationInWindow, from: nil).y) }
    }

    public override func mouseUp(with event: NSEvent) { draggingScrollbar = false }

    private func dragScrollbar(to y: CGFloat) {
        let thumbH = thumbRect.height
        let fraction = min(max((y - thumbH / 2) / max(1, bounds.height - thumbH), 0), 1)
        scrollY = fraction * maxScroll
        needsDisplay = true
    }

    // MARK: - Editing and cursor movement

    public func insert(_ text: String) {
        let bytes = Array(text.utf8)
        guard !bytes.isEmpty else { return }
        let line = rope.line(at: cursor)
        let t0 = CACurrentMediaTime()
        rope.insert(bytes, at: cursor)
        recordEdit(since: t0)
        cursor += bytes.count
        invalidate(from: line, linesShifted: bytes.contains(0x0A))
        goalColumn = nil
        revealCursor()
    }

    public func deleteBackward() {
        guard cursor > 0 else { return }
        let start = rope.previousCharStart(cursor)
        let line = rope.line(at: start)
        let joinsLines = rope.byte(at: start) == 0x0A
        let t0 = CACurrentMediaTime()
        rope.delete(start..<cursor)
        recordEdit(since: t0)
        cursor = start
        invalidate(from: line, linesShifted: joinsLines)
        goalColumn = nil
        revealCursor()
    }

    private func recordEdit(since t0: CFTimeInterval) {
        let ms = (CACurrentMediaTime() - t0) * 1000
        editStats.record(ms * 1000)
        lastEditMs = ms
        isModified = true
    }

    /// The duration of the most recent rope edit in ms, if one happened since the last call.
    public func takeLastEditMs() -> Double? {
        defer { lastEditMs = nil }
        return lastEditMs
    }

    private func invalidate(from line: Int, linesShifted: Bool) {
        if linesShifted { lineCache = lineCache.filter { $0.key < line } } else { lineCache[line] = nil }
        needsDisplay = true
    }

    public func moveCursor(by chars: Int) {
        cursor = chars < 0 ? rope.previousCharStart(cursor) : rope.nextCharEnd(cursor)
        goalColumn = nil
        revealCursor()
    }

    public func moveCursor(lines delta: Int) {
        let line = rope.line(at: cursor)
        let start = rope.offset(ofLine: line)
        let column = goalColumn ?? scalarCount(rope.bytes(from: start, maxBytes: cursor - start))
        let target = min(max(line + delta, 0), rope.lineCount - 1)
        let targetStart = rope.offset(ofLine: target)
        cursor = targetStart + rope.bytes(from: targetStart, maxScalars: column).count
        goalColumn = column
        revealCursor()
    }

    public func moveCursor(toLine line: Int) {
        cursor = rope.offset(ofLine: min(max(line, 0), rope.lineCount - 1))
        goalColumn = nil
        revealCursor()
    }

    private func moveCursor(toOffset off: Int) {
        cursor = off
        goalColumn = nil
        revealCursor()
    }

    private func page(_ direction: Int) {
        let n = max(1, Int(bounds.height / lineHeight) - 2) * direction
        scrollY += CGFloat(n) * lineHeight
        clampScroll()
        moveCursor(lines: n)
    }

    private func revealCursor() {
        let top = CGFloat(rope.line(at: cursor)) * lineHeight
        if top < scrollY {
            scrollY = top
        } else if top + lineHeight > scrollY + bounds.height {
            scrollY = top + lineHeight - bounds.height
        }
        clampScroll()
        needsDisplay = true
    }

    // MARK: - Keyboard and NSTextInputClient

    public override func keyDown(with event: NSEvent) {
        pendingKeyTime = event.timestamp
        interpretKeyEvents([event])
    }

    public override func doCommand(by selector: Selector) {
        let line = rope.line(at: cursor)
        switch NSStringFromSelector(selector) {
        case "moveLeft:": moveCursor(by: -1)
        case "moveRight:": moveCursor(by: 1)
        case "moveUp:": moveCursor(lines: -1)
        case "moveDown:": moveCursor(lines: 1)
        case "moveToBeginningOfLine:", "moveToLeftEndOfLine:": moveCursor(toOffset: rope.offset(ofLine: line))
        case "moveToEndOfLine:", "moveToRightEndOfLine:": moveCursor(toOffset: rope.lineEnd(line))
        case "moveToBeginningOfDocument:": moveCursor(toOffset: 0)
        case "moveToEndOfDocument:": moveCursor(toOffset: rope.byteCount)
        case "pageDown:", "scrollPageDown:": page(1)
        case "pageUp:", "scrollPageUp:": page(-1)
        case "deleteBackward:": deleteBackward()
        case "insertNewline:": insert("\n")
        case "insertTab:": insert("    ")
        default: break
        }
    }

    private func string(from value: Any) -> String {
        (value as? NSAttributedString)?.string ?? (value as? String) ?? ""
    }

    public func insertText(_ string: Any, replacementRange: NSRange) {
        let text = self.string(from: string)
        marked = nil
        if replacementRange.location != NSNotFound {
            let lo = rope.offset(atUTF16: replacementRange.location)
            let hi = rope.offset(atUTF16: replacementRange.location + replacementRange.length)
            if lo < hi {
                let line = rope.line(at: lo)
                rope.delete(lo..<hi)
                cursor = lo
                isModified = true
                invalidate(from: line, linesShifted: true)
            }
        }
        insert(text)
    }

    public func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let text = self.string(from: string)
        marked = text.isEmpty ? nil : text
        markedSelection = selectedRange
        needsDisplay = true
    }

    public func unmarkText() {
        if let m = marked {
            marked = nil
            insert(m)
        }
    }

    public func selectedRange() -> NSRange {
        let base = rope.utf16Offset(at: cursor)
        if marked != nil { return NSRange(location: base + markedSelection.location, length: markedSelection.length) }
        return NSRange(location: base, length: 0)
    }

    public func markedRange() -> NSRange {
        guard let m = marked else { return NSRange(location: NSNotFound, length: 0) }
        return NSRange(location: rope.utf16Offset(at: cursor), length: m.utf16.count)
    }

    public func hasMarkedText() -> Bool { marked != nil }

    public func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        let lo = rope.offset(atUTF16: range.location)
        let hi = rope.offset(atUTF16: range.location + range.length)
        let bytes = rope.bytes(from: lo, maxBytes: min(max(hi - lo, 0), 4096), stopAtNewline: false)
        let s = String(decoding: bytes, as: UTF8.self)
        actualRange?.pointee = NSRange(location: rope.utf16Offset(at: lo), length: s.utf16.count)
        return NSAttributedString(string: s)
    }

    public func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    public func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        actualRange?.pointee = range
        guard let window else { return .zero }
        return window.convertToScreen(convert(caretRect(), to: nil))
    }

    public func characterIndex(for point: NSPoint) -> Int { NSNotFound }
}
