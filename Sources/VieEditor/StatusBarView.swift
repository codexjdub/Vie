import AppKit
import CoreText
import VieVim

/// The strip under the text: the Vim mode or command line (or a message) on the left, the
/// keys of an unfinished command and the cursor position on the right.
public final class StatusBarView: NSView {
    public static let height: CGFloat = 22

    public weak var editor: EditorView?
    private let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular) as CTFont
    private(set) var shown = Content()

    struct Content: Equatable {
        var left = ""
        var leftIsError = false
        /// Cursor position in `left` (in characters) when it's the command line.
        var commandLineCursor: Int?
        var right = ""
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
        if resized { needsDisplay = true }
    }

    /// Re-reads the editor's state, and redraws only if what's shown changed.
    public func refresh() {
        guard let editor else {
            if shown != Content() {
                shown = Content()
                needsDisplay = true
            }
            return
        }
        var c = Content()
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
        let baseline = round((bounds.height + 1 + ascent - descent) / 2)
        let inset: CGFloat = 12

        let right = CTLineCreateWithAttributedString(Highlighter.plain(shown.right, font: font, color: Theme.secondaryText) as CFAttributedString)
        let rightWidth = CTLineGetTypographicBounds(right, nil, nil, nil)
        ctx.textPosition = CGPoint(x: bounds.width - inset - rightWidth, y: baseline)
        CTLineDraw(right, ctx)

        let color = shown.leftIsError ? Theme.error : Theme.text
        let left = CTLineCreateWithAttributedString(Highlighter.plain(shown.left, font: font, color: color) as CFAttributedString)
        ctx.saveGState()
        ctx.clip(to: CGRect(x: 0, y: 0, width: max(0, bounds.width - rightWidth - inset * 3), height: bounds.height))
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
