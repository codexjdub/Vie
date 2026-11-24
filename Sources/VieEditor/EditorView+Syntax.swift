import AppKit
import CoreText
import VieSyntax
import VieText

/// Syntax highlighting and themes: the view lays out each line piece with the highlighter's
/// spans for those bytes, and drops cached layouts when a parse or the appearance changes them.
extension EditorView {
    /// Files bigger than this are shown as plain text. A tree takes about 40 times the file's
    /// size in memory and the first parse about 140 ms per MB, so at 4 MB that's ~160 MB and
    /// half a second before colors appear; past it, plain text is the better trade.
    public static var syntaxSizeLimit = 4 * 1024 * 1024

    func restartSyntax() {
        syntax = nil
        if let language = syntaxLanguage, rope.byteCount <= Self.syntaxSizeLimit {
            let highlighter = SyntaxHighlighter(language: language, rope: rope)
            highlighter.onChange = { [weak self] ranges in self?.syntaxDidChange(ranges) }
            syntax = highlighter
        }
        hasStruckText = false
        dropLayouts { _ in true }
        needsDisplay = true
        onSyntaxChange?()
    }

    /// A parse landed: lay out again the lines whose highlighting may have changed.
    func syntaxDidChange(_ ranges: [Range<Int>]) {
        for r in ranges {
            let first = rope.line(at: min(r.lowerBound, rope.byteCount))
            let last = rope.line(at: min(max(r.upperBound, r.lowerBound), rope.byteCount))
            if last - first > lines.count {
                dropLayouts { $0 >= first && $0 <= last }
            } else {
                for line in first...last { lines[line] = nil }
            }
        }
        needsDisplay = true
        onSyntaxChange?()
    }

    /// The text in `range` with its syntax colors (plain until the first parse lands).
    func styledText(_ range: Range<Int>) -> NSMutableAttributedString {
        Theme.use(dark: drawsDark)
        let bytes = rope.bytes(in: range)
        let attr = NSMutableAttributedString(string: String(decoding: bytes, as: UTF8.self),
                                             attributes: [Highlighter.fontKey: font, Highlighter.colorKey: Theme.text,
                                                          Highlighter.paragraphKey: paragraph])
        guard let syntax, syntax.isReady else { return attr }
        let spans = syntax.spans(in: range)
        guard !spans.isEmpty else { return attr }
        // Byte offsets to UTF-16 offsets, walking the bytes once.
        var b = 0, u = 0
        func advance(to target: Int) {
            while b < target && b < bytes.count {
                let n = utf8Length(bytes[b])
                u += n == 4 ? 2 : 1
                b += n
            }
        }
        attr.beginEditing()
        // Same-styled spans with only spaces between them become one run (fewer runs for Core
        // Text to shape): `public static func` is one run, not five.
        var run: (u: Range<Int>, b: Int, style: Theme.Style, struck: Bool)?
        func apply(_ r: Range<Int>, _ style: Theme.Style, struck: Bool) {
            let r = NSRange(location: r.lowerBound, length: r.count)
            attr.addAttribute(Highlighter.colorKey, value: style.color, range: r)
            if style.bold || style.italic {
                let face = style.bold && style.italic ? boldItalicFont : style.bold ? boldFont : italicFont
                attr.addAttribute(Highlighter.fontKey, value: face, range: r)
            }
            if struck {
                attr.addAttribute(Highlighter.strikeKey, value: true, range: r)
                hasStruckText = true
            }
        }
        for span in spans {
            let start = span.range.lowerBound - range.lowerBound
            advance(to: start)
            let u0 = u
            advance(to: span.range.upperBound - range.lowerBound)
            guard u > u0 else { continue }
            let style = Theme.style(span.highlight)
            if let r = run, r.style.color === style.color, r.style.bold == style.bold, r.style.italic == style.italic,
               r.struck == span.struck, !span.struck || r.b == start,
               bytes[r.b..<start].allSatisfy({ $0 == 0x20 || $0 == 0x09 }) {
                run = (r.u.lowerBound..<u, b, style, span.struck)
                continue
            }
            if let r = run { apply(r.u, r.style, struck: r.struck) }
            run = (u0..<u, b, style, span.struck)
        }
        if let r = run { apply(r.u, r.style, struck: r.struck) }
        attr.endEditing()
        return attr
    }

    // MARK: - Appearance

    /// The editor's background in `appearance`, for views drawn next to it.
    public static func backgroundColor(for appearance: NSAppearance) -> NSColor {
        NSColor(cgColor: Theme.background(dark: appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)) ?? .textBackgroundColor
    }

    /// Whether this view draws with the dark theme: its appearance is dark.
    var drawsDark: Bool {
        if let dark = darkCache { return dark }
        let dark = Theme.isDarkAppearance(effectiveAppearance)
        darkCache = dark
        return dark
    }

    /// Picks the theme for this view's appearance, dropping layouts drawn in another theme or
    /// appearance. Each view keeps track of its own, so views in light and dark appearances
    /// side by side (the Settings previews) don't undo each other's layouts.
    func followTheme() {
        let dark = drawsDark
        Theme.use(dark: dark)
        let key = Theme.generation * 2 + (dark ? 1 : 0)
        guard themeGeneration != key else { return }
        themeGeneration = key
        dropLayouts { _ in true }
        Self.discard(numberCache)
        numberCache.removeAll()
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        darkCache = nil
        needsDisplay = true
    }
}
