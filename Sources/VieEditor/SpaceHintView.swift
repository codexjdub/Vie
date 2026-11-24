import AppKit
import VieSyntax
import VieVim

/// The box that lists what can follow Space in Vim mode, as LazyVim's which-key does: the keys
/// typed so far ("Space f"), then a row per key with what it does, a group ("+file/find")
/// leading to more keys. It sits at the bottom right of the editor, in the theme's status bar
/// colors and the editor's font.
final class SpaceHintView: NSView {
    private(set) var items: [VimSpaceItem] = []
    private(set) var heading = ""
    private var font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    private var bold = NSFont.monospacedSystemFont(ofSize: 13, weight: .bold)

    private let pad = NSSize(width: 12, height: 8)

    override var isFlipped: Bool { true }

    /// Shows `items` under `heading` in `font`.
    func show(_ items: [VimSpaceItem], heading: String, font: NSFont) {
        self.items = items
        self.heading = heading
        self.font = font
        bold = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        setFrameSize(neededSize)
        needsDisplay = true
    }

    private var rowHeight: CGFloat { ceil(font.ascender - font.descender + font.leading) + 4 }

    private func label(_ key: Character) -> String { key == " " ? "␣" : String(key) }

    private func width(_ text: String, _ font: NSFont) -> CGFloat {
        NSAttributedString(string: text, attributes: [.font: font]).size().width
    }

    private var keyWidth: CGFloat { items.map { width(label($0.key), bold) }.max() ?? 0 }
    private var gap: CGFloat { width("  ", font) }

    private var neededSize: NSSize {
        let rows = items.map { keyWidth + gap + width($0.title, font) }
        let w = max(rows.max() ?? 0, width(heading, font)) + pad.width * 2
        let h = CGFloat(items.count + 1) * rowHeight + 4 + pad.height * 2
        return NSSize(width: ceil(w), height: ceil(h))
    }

    override func draw(_ dirtyRect: NSRect) {
        let box = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        NSColor(cgColor: Theme.bar)?.setFill()
        box.fill()
        NSColor(cgColor: Theme.statusBorder)?.setStroke()
        box.lineWidth = 1
        box.stroke()
        let inset = (rowHeight - (font.ascender - font.descender)) / 2
        func draw(_ text: String, x: CGFloat, y: CGFloat, _ color: CGColor, _ font: NSFont) {
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(cgColor: color) ?? .textColor]
            NSAttributedString(string: text, attributes: attributes).draw(at: NSPoint(x: x, y: y + inset))
        }
        var y = pad.height
        draw(heading, x: pad.width, y: y, Theme.secondaryText, font)
        y += rowHeight + 4
        let keyColor = Theme.style(.keyword).color, groupColor = Theme.style(.function).color
        for item in items {
            draw(label(item.key), x: pad.width, y: y, keyColor, bold)
            draw(item.title, x: pad.width + keyWidth + gap, y: y, item.isGroup ? groupColor : Theme.text, font)
            y += rowHeight
        }
    }
}

extension EditorView {
    /// Shows, updates or hides the Space hint to match the engine: after `spaceHintDelay` for
    /// a first Space (so a quick Space e doesn't flash it), then at once as keys narrow it.
    func updateSpaceHint() {
        guard let vim, let items = vim.spaceHint, let prefix = vim.spacePrefix else {
            spaceHintShow?.cancel()
            spaceHintShow = nil
            spaceHint?.removeFromSuperview()
            spaceHint = nil
            return
        }
        if let hint = spaceHint {
            place(hint, items, prefix)
            return
        }
        guard spaceHintShow == nil else { return }
        let show = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.spaceHintShow = nil
            guard let items = self.vim?.spaceHint, let prefix = self.vim?.spacePrefix else { return }
            let hint = SpaceHintView()
            hint.autoresizingMask = [.minXMargin, .minYMargin]
            self.addSubview(hint)
            self.spaceHint = hint
            self.place(hint, items, prefix)
        }
        spaceHintShow = show
        DispatchQueue.main.asyncAfter(deadline: .now() + spaceHintDelay, execute: show)
    }

    /// What the hint shows (for tests): its heading and each row as "key title"; nil when hidden.
    public var shownSpaceHint: [String]? {
        guard let hint = spaceHint else { return nil }
        return [hint.heading] + hint.items.map { "\($0.key == " " ? "␣" : String($0.key)) \($0.title)" }
    }

    /// Fills the hint and puts it at the bottom right, clear of the scrollbar.
    private func place(_ hint: SpaceHintView, _ items: [VimSpaceItem], _ prefix: String) {
        hint.show(items, heading: (["Space"] + prefix.map(String.init)).joined(separator: " "), font: font as NSFont)
        hint.setFrameOrigin(NSPoint(x: bounds.maxX - hint.frame.width - 20, y: bounds.maxY - hint.frame.height - 12))
    }
}
