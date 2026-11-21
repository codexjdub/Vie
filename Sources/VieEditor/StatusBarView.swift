import AppKit
import CoreText
import VieVim

/// The strip under the text: the Vim mode or command line (or a message) on the left, the
/// keys of an unfinished command, the cursor position and the Vim switch on the right.
public final class StatusBarView: NSView, NSViewToolTipOwner {
    public static let height: CGFloat = 22

    public weak var editor: EditorView?
    /// Whether Vim mode is on, for the switch at the right end, a "V" (nil: no switch).
    public var vimSwitch: Bool? {
        didSet {
            guard vimSwitch != oldValue else { return }
            if (vimSwitch == nil) != (oldValue == nil) { updateSwitchRects() }
            refresh()
        }
    }
    /// A click on the switch.
    public var onVimSwitch: (() -> Void)?
    private let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular) as CTFont
    private(set) var shown = Content()

    struct Content: Equatable {
        var left = ""
        var leftIsError = false
        /// Cursor position in `left` (in characters) when it's the command line.
        var commandLineCursor: Int?
        var right = ""
        var vim: Bool?
    }

    public init(frame: NSRect, editor: EditorView?) {
        self.editor = editor
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
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
            updateSwitchRects()
        }
    }

    private lazy var switchLabelWidth = CTLineGetTypographicBounds(switchLabel(Theme.text), nil, nil, nil)

    private func switchLabel(_ color: CGColor) -> CTLine {
        CTLineCreateWithAttributedString(Highlighter.plain("V", font: font, color: color) as CFAttributedString)
    }

    private var baseline: CGFloat { round((bounds.height + 1 + CTFontGetAscent(font) - CTFontGetDescent(font)) / 2) }

    /// Where the Vim switch is drawn and clicked (empty without one).
    var vimSwitchRect: CGRect {
        guard vimSwitch != nil else { return .zero }
        let width = ceil(switchLabelWidth) + 10, height: CGFloat = 16
        let middle = baseline - (CTFontGetAscent(font) - CTFontGetDescent(font)) / 2
        return CGRect(x: bounds.width - 6 - width, y: round(middle - height / 2), width: width, height: height)
    }

    public override func mouseDown(with event: NSEvent) {
        if vimSwitchRect.contains(convert(event.locationInWindow, from: nil)) { onVimSwitch?() } else { super.mouseDown(with: event) }
    }

    public override func resetCursorRects() {
        if vimSwitch != nil { addCursorRect(vimSwitchRect, cursor: .pointingHand) }
    }

    private func updateSwitchRects() {
        removeAllToolTips()
        if vimSwitch != nil { addToolTip(vimSwitchRect, owner: self, userData: nil) }
        window?.invalidateCursorRects(for: self)
    }

    public func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint,
                     userData data: UnsafeMutableRawPointer?) -> String {
        vimSwitch == true ? "Vim mode is on. Click or press ⌃⌘V to turn it off."
            : "Vim mode is off. Click or press ⌃⌘V to turn it on."
    }

    /// Re-reads the editor's state, and redraws only if what's shown changed.
    public func refresh() {
        var c = Content(vim: vimSwitch)
        guard let editor else {
            if shown != c {
                shown = c
                needsDisplay = true
            }
            return
        }
        if let vim = editor.vim {
            if let line = vim.commandLineText {
                c.left = line
                c.commandLineCursor = vim.commandLineCursor
            } else if vim.mode == .normal, let message = vim.message {
                c.left = message
                c.leftIsError = vim.messageIsError
            } else {
                c.left = vim.modeText
            }
            c.right = vim.pendingText
        }
        let rope = editor.rope
        let off = editor.caretOffset
        let line = rope.line(at: off)
        let start = rope.offset(ofLine: line)
        let column = off - start <= 4096 ? rope.string(in: start..<off).count : rope.utf16Offset(at: off) - rope.utf16Offset(at: start)
        let position = "Ln \(line + 1), Col \(column + 1)"
        c.right = c.right.isEmpty ? position : c.right + "    " + position
        if c != shown {
            shown = c
            needsDisplay = true
        }
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    public override func draw(_ dirtyRect: NSRect) {
        Theme.update(for: effectiveAppearance)
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setFillColor(Theme.bar)
        ctx.fill(bounds)
        ctx.setFillColor(Theme.statusBorder)
        ctx.fill(CGRect(x: 0, y: 0, width: bounds.width, height: 1))
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        let ascent = CTFontGetAscent(font), descent = CTFontGetDescent(font)
        let baseline = self.baseline
        let inset: CGFloat = 12

        // The Vim switch: filled when on, outlined when off.
        var rightEdge = bounds.width - inset
        if let on = shown.vim {
            let rect = vimSwitchRect
            let pill = CGPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 4, cornerHeight: 4, transform: nil)
            if on {
                ctx.setFillColor(Theme.selection)
                ctx.addPath(pill)
                ctx.fillPath()
            } else {
                ctx.setStrokeColor(Theme.secondaryText.copy(alpha: 0.5) ?? Theme.secondaryText)
                ctx.setLineWidth(1)
                ctx.addPath(pill)
                ctx.strokePath()
            }
            ctx.textPosition = CGPoint(x: rect.minX + (rect.width - switchLabelWidth) / 2, y: baseline)
            CTLineDraw(switchLabel(on ? Theme.text : Theme.secondaryText), ctx)
            rightEdge = rect.minX - 10
        }

        let right = CTLineCreateWithAttributedString(Highlighter.plain(shown.right, font: font, color: Theme.secondaryText) as CFAttributedString)
        let rightWidth = CTLineGetTypographicBounds(right, nil, nil, nil)
        ctx.textPosition = CGPoint(x: rightEdge - rightWidth, y: baseline)
        CTLineDraw(right, ctx)

        let color = shown.leftIsError ? Theme.error : Theme.text
        let left = CTLineCreateWithAttributedString(Highlighter.plain(shown.left, font: font, color: color) as CFAttributedString)
        ctx.saveGState()
        ctx.clip(to: CGRect(x: 0, y: 0, width: max(0, rightEdge - rightWidth - inset * 2), height: bounds.height))
        ctx.textPosition = CGPoint(x: inset, y: baseline)
        CTLineDraw(left, ctx)
        if let cursor = shown.commandLineCursor {
            let index = String(shown.left.prefix(cursor)).utf16.count
            let x = inset + CTLineGetOffsetForStringIndex(left, index, nil)
            ctx.setFillColor(Theme.cursor)
            ctx.fill(CGRect(x: round(x), y: baseline - ascent, width: 2, height: ascent + descent))
        }
        ctx.restoreGState()
    }
}
