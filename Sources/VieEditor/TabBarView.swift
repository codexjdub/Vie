import AppKit
import CoreText

/// The row of tabs above the editor: one per open buffer, with a close button (or a dot for
/// unsaved changes), drawn with Core Text like the rest of the editor.
public final class TabBarView: NSView {
    public static let height: CGFloat = 30

    public struct Tab: Equatable {
        public var title: String
        public var isDirty: Bool
        public var toolTip: String?

        public init(title: String, isDirty: Bool, toolTip: String? = nil) {
            self.title = title
            self.isDirty = isDirty
            self.toolTip = toolTip
        }
    }

    public var tabs: [Tab] = [] {
        didSet {
            guard tabs != oldValue else { return }
            needsDisplay = true
            updateToolTips()
        }
    }
    public var selectedIndex: Int? {
        didSet { if selectedIndex != oldValue { needsDisplay = true } }
    }
    /// Shows ⌘1–⌘9 on the first nine tabs (while ⌘ is held) in place of the close button.
    public var showsNumbers = false {
        didSet { if showsNumbers != oldValue { needsDisplay = true } }
    }
    public var onSelect: ((Int) -> Void)?
    public var onClose: ((Int) -> Void)?
    /// Double-click on the empty part of the bar.
    public var onNewTab: (() -> Void)?

    private let font = NSFont.systemFont(ofSize: 12) as CTFont
    private var hover: Int?
    private var hoverClose = false
    private var tracking: NSTrackingArea?

    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    public required init?(coder: NSCoder) { fatalError("not used") }

    public override var isFlipped: Bool { true }
    public override var isOpaque: Bool { true }

    /// The layer redraws only when asked, so a new size asks (see EditorView.setFrameSize).
    public override func setFrameSize(_ newSize: NSSize) {
        let resized = newSize != frame.size
        super.setFrameSize(newSize)
        if resized { needsDisplay = true }
    }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - Layout

    private func titleLine(_ s: String, color: CGColor) -> CTLine {
        CTLineCreateWithAttributedString(Highlighter.plain(s, font: font, color: color) as CFAttributedString)
    }

    /// Each tab's frame: sized to its title within limits, squeezed when they don't fit.
    func tabRects() -> [CGRect] {
        guard !tabs.isEmpty else { return [] }
        let widths = tabs.map { tab -> CGFloat in
            let w = CTLineGetTypographicBounds(titleLine(tab.title, color: Theme.text), nil, nil, nil)
            return min(max(w + 48, 100), 240)
        }
        let total = widths.reduce(0, +)
        let scale = total > bounds.width ? max(bounds.width / total, 0) : 1
        var x: CGFloat = 0
        return widths.map { w in
            let width = max(floor(w * scale), 48)
            defer { x += width }
            return CGRect(x: x, y: 0, width: width, height: bounds.height)
        }
    }

    private func closeRect(_ tab: CGRect) -> CGRect {
        CGRect(x: tab.maxX - 24, y: (tab.height - 16) / 2, width: 16, height: 16)
    }

    private func index(at p: NSPoint) -> Int? {
        tabRects().firstIndex { $0.contains(p) }
    }

    // MARK: - Drawing

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    public override func draw(_ dirtyRect: NSRect) {
        Theme.update(for: effectiveAppearance)
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setFillColor(Theme.gutter)
        ctx.fill(bounds)
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        let ascent = CTFontGetAscent(font), descent = CTFontGetDescent(font)
        let baseline = round((bounds.height + ascent - descent) / 2)
        for (i, r) in tabRects().enumerated() {
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

            let color = selected ? Theme.text : Theme.lineNumber
            let available = Double(r.width - 12 - 30)
            var line = titleLine(tab.title, color: color)
            if CTLineGetTypographicBounds(line, nil, nil, nil) > available,
               let truncated = CTLineCreateTruncatedLine(line, max(available, 8), .end, titleLine("…", color: color)) {
                line = truncated
            }
            ctx.saveGState()
            ctx.clip(to: CGRect(x: r.minX, y: 0, width: r.width - 28, height: r.height))
            ctx.textPosition = CGPoint(x: r.minX + 12, y: baseline)
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
        for (i, r) in tabRects().enumerated() where tabs[i].toolTip != nil {
            addToolTip(r, owner: tipOwners[i], userData: nil)
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
        }
    }

    public override func otherMouseDown(with event: NSEvent) {
        if let i = index(at: convert(event.locationInWindow, from: nil)) { onClose?(i) }
    }
}
