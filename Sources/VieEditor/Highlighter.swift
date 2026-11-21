import AppKit
import CoreText
import VieSyntax

/// The colors views draw with: the chosen light or dark theme (see EditorTheme), picked for
/// the appearance of the view drawing or laying out text; and the syntax styles.
@MainActor
enum Theme {
    /// Changes when a chosen theme changes, so views drop layouts with old colors baked in.
    /// (Views also keep track of their own light or dark appearance.)
    private(set) static var generation = 0
    /// Posted when a chosen theme changes; views redraw.
    static let didChange = EditorTheme.didChange
    private(set) static var isDark = true
    private(set) static var themes = (light: EditorTheme.vieLight, dark: EditorTheme.vieDark)
    private static var tables = (light: makeStyles(EditorTheme.vieLight.palette), dark: makeStyles(EditorTheme.vieDark.palette))
    private static var palette = EditorTheme.vieDark.palette
    /// `style(_:)` for each highlight, by raw value.
    private static var styles = tables.dark

    /// Uses `light` and `dark` from now on.
    static func choose(light: EditorTheme, dark: EditorTheme) {
        guard light != themes.light || dark != themes.dark else { return }
        themes = (light, dark)
        tables = (makeStyles(light.palette), makeStyles(dark.palette))
        select(dark: isDark)
        generation += 1
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    /// Selects the colors for `appearance`; returns whether they're the dark ones. Views call
    /// it before drawing or laying out text.
    @discardableResult
    static func update(for appearance: NSAppearance) -> Bool {
        let dark = isDarkAppearance(appearance)
        use(dark: dark)
        return dark
    }

    /// Selects the dark or light colors.
    static func use(dark: Bool) {
        if dark != isDark { select(dark: dark) }
    }

    static func isDarkAppearance(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    private static func select(dark: Bool) {
        isDark = dark
        palette = dark ? themes.dark.palette : themes.light.palette
        styles = dark ? tables.dark : tables.light
    }

    static var background: CGColor { palette.background }
    static func background(dark: Bool) -> CGColor { (dark ? themes.dark : themes.light).palette.background }
    static var gutter: CGColor { palette.gutter }
    /// The tab and status bars.
    static var bar: CGColor { palette.bar }
    static var currentLine: CGColor { palette.currentLine }
    static var text: CGColor { palette.text }
    static var lineNumber: CGColor { palette.lineNumber }
    static var secondaryText: CGColor { palette.secondaryText }
    static var cursor: CGColor { palette.cursor }
    /// The character under a block cursor.
    static var cursorText: CGColor { palette.cursorText }
    static var selection: CGColor { palette.selection }
    static var inactiveSelection: CGColor { palette.inactiveSelection }
    static var scrollbar: CGColor { palette.scrollbar }
    static var searchMatch: CGColor { palette.searchMatch }
    static var currentMatch: CGColor { palette.currentMatch }
    static var statusBorder: CGColor { palette.statusBorder }
    static var error: CGColor { palette.error }
    static var hudBackground: CGColor { palette.hudBackground }
    static var hudText: CGColor { palette.hudText }

    typealias Style = (color: CGColor, bold: Bool, italic: Bool)

    /// How a highlight is drawn: its color, and bold or italic for markup.
    static func style(_ h: Highlight) -> Style { styles[Int(h.rawValue)] }

    private static func makeStyles(_ p: Palette) -> [Style] {
        Highlight.allCases.map { makeStyle($0, p) } // raw values count up from 0
    }

    private static func makeStyle(_ h: Highlight, _ p: Palette) -> Style {
        let s = p.syntax
        let ink: Ink
        switch h {
        case .none: return (p.text, false, false)
        case .emphasis: return (p.text, false, true)
        case .strong: return (p.text, true, false)
        case .heading: return (s.heading.color, true, s.heading.isItalic)
        case .comment: ink = s.comment
        case .keyword, .specialPunctuation: ink = s.keyword
        case .string, .literal: ink = s.string
        case .escape: ink = s.escape
        case .builtinFunction: ink = s.builtinFunction
        case .label: ink = s.label
        case .link: ink = s.link
        case .number: ink = s.number
        case .constant: ink = s.constant
        case .boolean: ink = s.boolean
        case .builtinConstant: ink = s.builtinConstant
        case .attribute: ink = s.attribute
        case .function: ink = s.function
        case .type: ink = s.type
        case .builtinType: ink = s.builtinType
        case .module: ink = s.module
        case .builtinVariable: ink = s.builtinVariable
        case .property: ink = s.property
        case .tag: ink = s.tag
        case .parameter: ink = s.parameter
        case .operator: ink = s.operator
        case .punctuation: ink = s.punctuation
        case .bracket: ink = s.bracket
        }
        return (ink.color, ink.isBold, ink.isItalic)
    }
}

/// Attributed-string helpers for laying out text with Core Text.
enum Highlighter {
    static let fontKey = NSAttributedString.Key(kCTFontAttributeName as String)
    static let colorKey = NSAttributedString.Key(kCTForegroundColorAttributeName as String)
    static let paragraphKey = NSAttributedString.Key(kCTParagraphStyleAttributeName as String)
    static let underlineKey = NSAttributedString.Key(kCTUnderlineStyleAttributeName as String)

    static func paragraphStyle(tabWidth: CGFloat) -> CTParagraphStyle {
        var interval = tabWidth
        var stops: CFArray = NSArray()
        return withUnsafePointer(to: &interval) { ip in
            withUnsafePointer(to: &stops) { sp in
                let settings = [
                    CTParagraphStyleSetting(spec: .tabStops, valueSize: MemoryLayout<CFArray>.size, value: sp),
                    CTParagraphStyleSetting(spec: .defaultTabInterval, valueSize: MemoryLayout<CGFloat>.size, value: ip),
                ]
                return CTParagraphStyleCreate(settings, settings.count)
            }
        }
    }

    static func plain(_ s: String, font: CTFont, color: CGColor) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [fontKey: font, colorKey: color])
    }
}
