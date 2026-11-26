import AppKit
import CoreText

/// The row of tabs above the editor: one per open buffer, with a close button (or a dot for
/// unsaved changes), drawn with Core Text like the rest of the editor. Tabs shrink to a
/// minimum width, then the row scrolls sideways. A tab can be dragged to another place in the
/// row, or onto another window's row.
public final class TabBarView: NSView, NSDraggingSource {
    public static let height: CGFloat = 30
    /// Tabs shrink no narrower than this; past it the row scrolls.
    public static let minimumTabWidth: CGFloat = 100
    /// What a dragged tab carries: "<window number>:<tab index>".
    public static let tabType = NSPasteboard.PasteboardType("io.github.codexjdub.vie.tab")

    public struct Tab: Equatable {
        public var title: String
        public var isDirty: Bool
        public var toolTip: String?
        /// A symbol for the file's kind, drawn before the title in `iconColor`.
        public var icon: NSImage?
        public var iconColor: NSColor?

        public init(title: String, isDirty: Bool, toolTip: String? = nil, icon: NSImage? = nil, iconColor: NSColor? = nil) {
            self.title = title
            self.isDirty = isDirty
            self.toolTip = toolTip
            self.icon = icon
            self.iconColor = iconColor
        }
    }

    /// The room an icon takes before the title.
    static let iconSpace: CGFloat = 18

    public var tabs: [Tab] = [] {
        didSet {
            guard tabs != oldValue else { return }
            // The tab being dragged went to another window.
            if tabs.count != oldValue.count { draggedIndex = nil }
            needsDisplay = true
            revealSelected()
            updateToolTips()
        }
    }
    public var selectedIndex: Int? {
        didSet {
            guard selectedIndex != oldValue else { return }
            needsDisplay = true
            revealSelected()
        }
    }
    /// Shows ⌘1–⌘9 on the first nine tabs (while ⌘ is held) in place of the close button.
    public var showsNumbers = false {
        didSet { if showsNumbers != oldValue { needsDisplay = true } }
    }
    public var onSelect: ((Int) -> Void)?
    public var onClose: ((Int) -> Void)?
    /// Double-click on the empty part of the bar.
    public var onNewTab: (() -> Void)?
    /// A tab dragged to another place in the row: its index, and its index afterwards.
    public var onMove: ((Int, Int) -> Void)?
    /// A tab from another window's row dropped here: that window's number, the tab's index
    /// there, and its index here.
    public var onDrop: ((Int, Int, Int) -> Void)?

    private let font = NSFont.systemFont(ofSize: 12) as CTFont
    private var hover: Int?
    private var hoverClose = false
    private var tracking: NSTrackingArea?
    /// How far the row is scrolled, when its tabs don't fit.
    private(set) var scrollX: CGFloat = 0
    /// The tab pressed, and where, until the mouse moves far enough to drag it.
    private var pressed: (index: Int, point: NSPoint)?
    /// The tab being dragged from this row, left out of it while the drag lasts.
    private(set) var draggedIndex: Int?
    /// Where a tab dragged over the row would go, counting the tabs not dragged; a gap shows.
    private(set) var dropIndex: Int?
    private var dropWidth: CGFloat = 0

    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        registerForDraggedTypes([Self.tabType])
        NotificationCenter.default.addObserver(self, selector: #selector(themeDidChange), name: Theme.didChange, object: nil)
    }

    @objc private func themeDidChange(_ note: Notification) { needsDisplay = true }

    public required init?(coder: NSCoder) { fatalError("not used") }

    public override var isFlipped: Bool { true }
    public override var isOpaque: Bool { true }

    /// The layer redraws only when asked, so a new size asks (see EditorView.setFrameSize).
    public override func setFrameSize(_ newSize: NSSize) {
        let resized = newSize != frame.size
        super.setFrameSize(newSize)
        if resized {
            needsDisplay = true
            revealSelected()
            updateToolTips()
        }
    }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - Layout

    private func titleLine(_ s: String, color: CGColor) -> CTLine {
        CTLineCreateWithAttributedString(Highlighter.plain(s, font: font, color: color) as CFAttributedString)
    }

    /// Each tab's width: sized to its title within limits, squeezed when they don't all fit,
    /// down to the minimum.
    func tabWidths() -> [CGFloat] {
        let natural = tabs.map { tab -> CGFloat in
            let w = CTLineGetTypographicBounds(titleLine(tab.title, color: Theme.text), nil, nil, nil)
            let icon = tab.icon == nil ? 0 : Self.iconSpace
            return min(max(w + 48 + icon, Self.minimumTabWidth), 240 + icon)
        }
        let total = natural.reduce(0, +)
        guard total > bounds.width, total > 0 else { return natural }
        return natural.map { max(floor($0 * bounds.width / total), Self.minimumTabWidth) }
    }

    /// The width of all the tabs, which is more than the view's when the row scrolls.
    var contentWidth: CGFloat { tabWidths().reduce(0, +) }

    /// The tabs' frames in the view, left to right, scrolled: a tab being dragged from the row
    /// is left out, and a gap shows where a tab dragged over it would go.
    private func layout() -> [(index: Int, rect: CGRect)] {
        let widths = tabWidths()
        var x = -scrollX
        var out: [(index: Int, rect: CGRect)] = []
        for i in tabs.indices where i != draggedIndex {
            if out.count == dropIndex { x += dropWidth }
            out.append((i, CGRect(x: x, y: 0, width: widths[i], height: bounds.height)))
            x += widths[i]
        }
        return out
    }

    /// Each tab's frame in the view, by index (zero for a tab being dragged).
    func tabRects() -> [CGRect] {
        var rects = Array(repeating: CGRect.zero, count: tabs.count)
        for (i, rect) in layout() { rects[i] = rect }
        return rects
    }

    private func closeRect(_ tab: CGRect) -> CGRect {
        CGRect(x: tab.maxX - 24, y: (tab.height - 16) / 2, width: 16, height: 16)
    }

    private func index(at p: NSPoint) -> Int? {
        layout().first { $0.rect.contains(p) }?.index
    }

    // MARK: - Scrolling

    public override func scrollWheel(with event: NSEvent) {
        guard contentWidth > bounds.width else { return super.scrollWheel(with: event) }
        // Sideways on a trackpad; a mouse wheel's up and down scroll sideways too.
        var delta = abs(event.scrollingDeltaX) >= abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
        // A wheel's notch (a line) moves about two fifths of a tab.
        if !event.hasPreciseScrollingDeltas { delta *= 40 }
        scroll(to: scrollX - delta)
    }

    func scroll(to x: CGFloat) {
        let x = min(max(x, 0), max(contentWidth - bounds.width, 0))
        guard x != scrollX else { return }
        scrollX = x
        hover = nil
        needsDisplay = true
        updateToolTips()
    }

    /// Scrolls the current tab into view (and keeps the row from scrolling past its end).
    private func revealSelected() {
        guard let i = selectedIndex, tabs.indices.contains(i) else { return scroll(to: scrollX) }
        let widths = tabWidths()
        let minX = widths[..<i].reduce(0, +), maxX = minX + widths[i]
        if minX < scrollX {
            scroll(to: minX)
        } else if maxX > scrollX + bounds.width {
            scroll(to: maxX - bounds.width)
        } else {
            scroll(to: scrollX)
        }
    }

    // MARK: - Drawing

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    public override func draw(_ dirtyRect: NSRect) {
        Theme.update(for: effectiveAppearance)
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setFillColor(Theme.bar)
        ctx.fill(bounds)
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        let ascent = CTFontGetAscent(font), descent = CTFontGetDescent(font)
        let baseline = round((bounds.height + ascent - descent) / 2)
        for (i, r) in layout() where r.maxX > 0 && r.minX < bounds.width {
            let tab = tabs[i]
            let selected = i == selectedIndex
            if selected {
                ctx.setFillColor(Theme.background)
                ctx.fill(r)
                ctx.setFillColor(Theme.cursor)
                ctx.fill(CGRect(x: r.minX, y: 0, width: r.width, height: 2))
            } else if i == hover {
                ctx.setFillColor(Theme.currentLine)
                ctx.fill(r)
            }
            ctx.setFillColor(Theme.statusBorder)
            ctx.fill(CGRect(x: r.maxX - 1, y: 0, width: 1, height: r.height))

            let color = selected ? Theme.text : Theme.secondaryText
            let iconSpace = tab.icon == nil ? 0 : Self.iconSpace
            let available = Double(r.width - 12 - 30 - iconSpace)
            var line = titleLine(tab.title, color: color)
            if CTLineGetTypographicBounds(line, nil, nil, nil) > available,
               let truncated = CTLineCreateTruncatedLine(line, max(available, 8), .end, titleLine("…", color: color)) {
                line = truncated
            }
            ctx.saveGState()
            ctx.clip(to: CGRect(x: r.minX, y: 0, width: r.width - 28, height: r.height))
            if let icon = tab.icon {
                drawIcon(icon, color: tab.iconColor ?? NSColor(cgColor: color) ?? .secondaryLabelColor,
                         centeredAt: CGPoint(x: r.minX + 17, y: r.midY), dimmed: !selected)
            }
            ctx.textPosition = CGPoint(x: r.minX + 12 + iconSpace, y: baseline)
            CTLineDraw(line, ctx)
            ctx.restoreGState()

            let close = closeRect(r)
            if showsNumbers && i < 9 {
                let number = titleLine("⌘\(i + 1)", color: color)
                let width = CTLineGetTypographicBounds(number, nil, nil, nil)
                ctx.textPosition = CGPoint(x: close.maxX - CGFloat(width), y: baseline)
                CTLineDraw(number, ctx)
            } else if i == hover || (selected && !tab.isDirty) {
                if i == hover && hoverClose {
                    ctx.setFillColor(Theme.scrollbar)
                    ctx.addPath(CGPath(roundedRect: close, cornerWidth: 3, cornerHeight: 3, transform: nil))
                    ctx.fillPath()
                }
                ctx.setStrokeColor(color)
                ctx.setLineWidth(1.25)
                let inset = close.insetBy(dx: 4.5, dy: 4.5)
                ctx.move(to: CGPoint(x: inset.minX, y: inset.minY))
                ctx.addLine(to: CGPoint(x: inset.maxX, y: inset.maxY))
                ctx.move(to: CGPoint(x: inset.maxX, y: inset.minY))
                ctx.addLine(to: CGPoint(x: inset.minX, y: inset.maxY))
                ctx.strokePath()
            } else if tab.isDirty {
                ctx.setFillColor(color)
                ctx.fillEllipse(in: CGRect(x: close.midX - 3.5, y: close.midY - 3.5, width: 7, height: 7))
            }
        }
        ctx.setFillColor(Theme.statusBorder)
        ctx.fill(CGRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1))
    }

    /// A tab's symbol at its own size, in its color; fainter on tabs not shown, as their
    /// titles are.
    private func drawIcon(_ icon: NSImage, color: NSColor, centeredAt center: CGPoint, dimmed: Bool) {
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        let image = icon.withSymbolConfiguration(config) ?? icon
        let size = image.size
        let rect = NSRect(x: round(center.x - size.width / 2), y: round(center.y - size.height / 2), width: size.width, height: size.height)
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: dimmed ? 0.6 : 1, respectFlipped: true, hints: nil)
    }

    // MARK: - Mouse

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
        updateToolTips()
    }

    /// Tool tip owners aren't retained by the view.
    private var tipOwners: [NSString] = []

    private func updateToolTips() {
        removeAllToolTips()
        tipOwners = tabs.map { ($0.toolTip ?? $0.title) as NSString }
        for (i, r) in layout() where tabs[i].toolTip != nil && r.intersects(bounds) {
            addToolTip(r.intersection(bounds), owner: tipOwners[i], userData: nil)
        }
    }

    public override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let i = index(at: p)
        let onClose = i.map { closeRect(tabRects()[$0]).contains(p) } ?? false
        if i != hover || onClose != hoverClose {
            hover = i
            hoverClose = onClose
            needsDisplay = true
        }
    }

    public override func mouseExited(with event: NSEvent) {
        hover = nil
        hoverClose = false
        needsDisplay = true
    }

    public override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let i = index(at: p) else {
            if event.clickCount == 2 { onNewTab?() }
            return
        }
        if closeRect(tabRects()[i]).contains(p) {
            onClose?(i)
        } else {
            onSelect?(i)
            pressed = (i, p)
        }
    }

    public override func mouseDragged(with event: NSEvent) {
        guard let (i, start) = pressed, tabs.indices.contains(i) else { return }
        let p = convert(event.locationInWindow, from: nil)
        guard hypot(p.x - start.x, p.y - start.y) > 4 else { return }
        pressed = nil
        beginDragging(i, with: event)
    }

    public override func mouseUp(with event: NSEvent) { pressed = nil }

    public override func otherMouseDown(with event: NSEvent) {
        if let i = index(at: convert(event.locationInWindow, from: nil)) { onClose?(i) }
    }

    // MARK: - Dragging tabs

    /// Starts dragging a tab: a picture of it follows the pointer, and a gap holds its place
    /// while the pointer is over the row.
    private func beginDragging(_ i: Int, with event: NSEvent) {
        let rect = tabRects()[i]
        let picture = NSImage(size: rect.size)
        if let rep = bitmapImageRepForCachingDisplay(in: rect) {
            cacheDisplay(in: rect, to: rep)
            picture.addRepresentation(rep)
        }
        let item = NSPasteboardItem()
        item.setString("\(window?.windowNumber ?? 0):\(i)", forType: Self.tabType)
        let dragged = NSDraggingItem(pasteboardWriter: item)
        dragged.setDraggingFrame(rect, contents: picture)
        hover = nil
        draggedIndex = i
        dropIndex = i
        dropWidth = rect.width
        needsDisplay = true
        beginDraggingSession(with: [dragged], event: event, source: self)
    }

    public func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    public func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        draggedIndex = nil
        dropIndex = nil
        needsDisplay = true
    }

    /// Where a tab dropped at `x` goes: the number of tabs (leaving out one being dragged
    /// from here) whose middle is left of it.
    func insertionIndex(at x: CGFloat) -> Int {
        let widths = tabWidths()
        var left = -scrollX
        var n = 0
        for i in tabs.indices where i != draggedIndex {
            if left + widths[i] / 2 < x { n += 1 }
            left += widths[i]
        }
        return n
    }

    public override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        draggingUpdated(sender)
    }

    public override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingPasteboard.string(forType: Self.tabType) != nil else { return [] }
        let p = convert(sender.draggingLocation, from: nil)
        // Near either end of a row that scrolls, scroll.
        if p.x < 30 { scroll(to: scrollX - 8) } else if p.x > bounds.width - 30 { scroll(to: scrollX + 8) }
        if draggedIndex == nil { dropWidth = Self.minimumTabWidth }
        let index = insertionIndex(at: p.x)
        if index != dropIndex {
            dropIndex = index
            needsDisplay = true
        }
        return .move
    }

    public override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        dropIndex = nil
        needsDisplay = true
    }

    public override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let payload = sender.draggingPasteboard.string(forType: Self.tabType), let to = dropIndex else { return false }
        let parts = payload.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return false }
        dropIndex = nil
        needsDisplay = true
        if let from = draggedIndex {
            draggedIndex = nil
            if from != to { onMove?(from, to) }
        } else {
            onDrop?(parts[0], parts[1], to)
        }
        return true
    }
}
