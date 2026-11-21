import AppKit
import CoreText
import VieSyntax

/// The editor's colors, light and dark, following the system appearance; and the syntax colors.
@MainActor
enum Theme {
    /// Changes when the appearance switches, so views can drop layouts with old colors baked in.
    private(set) static var generation = 0
    private(set) static var isDark = true
    private static var palette = Palette.dark
    /// `style(_:)` for each highlight, by raw value.
    private static var styles = makeStyles()

    /// Follows `appearance`; returns true if the colors changed. Views call it before drawing.
    @discardableResult
    static func update(for appearance: NSAppearance) -> Bool {
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        guard dark != isDark else { return false }
        isDark = dark
        palette = dark ? .dark : .light
        styles = makeStyles()
        generation += 1
        return true
    }

    static var background: CGColor { palette.background }
    static func background(dark: Bool) -> CGColor { (dark ? Palette.dark : Palette.light).background }
    static var gutter: CGColor { palette.gutter }
    static var currentLine: CGColor { palette.currentLine }
    static var text: CGColor { palette.text }
    static var lineNumber: CGColor { palette.lineNumber }
    static var cursor: CGColor { palette.cursor }
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

    private static func makeStyles() -> [Style] {
        Highlight.allCases.map { makeStyle($0, palette) } // raw values count up from 0
    }

    private static func makeStyle(_ h: Highlight, _ p: Palette) -> Style {
        switch h {
        case .none: return (p.text, false, false)
        case .comment: return (p.comment, false, false)
        case .keyword, .specialPunctuation: return (p.keyword, false, false)
        case .string, .literal: return (p.string, false, false)
        case .escape, .builtinFunction, .label, .link: return (p.cyan, false, false)
        case .number, .constant, .builtinConstant, .attribute: return (p.orange, false, false)
        case .function: return (p.function, false, false)
        case .type, .builtinType, .module: return (p.type, false, false)
        case .builtinVariable, .property, .tag: return (p.red, false, false)
        case .parameter: return (p.parameter, false, false)
        case .operator: return (p.operator, false, false)
        case .punctuation: return (p.punctuation, false, false)
        case .heading: return (p.function, true, false)
        case .emphasis: return (p.text, false, true)
        case .strong: return (p.text, true, false)
        }
    }
}

private func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: a)
}

/// One appearance's colors.
private struct Palette {
    var background, gutter, currentLine, text, lineNumber, cursor, selection, inactiveSelection: CGColor
    var scrollbar, searchMatch, currentMatch, statusBorder, error, hudBackground, hudText: CGColor
    // Syntax.
    var comment, keyword, string, cyan, orange, function, type, red, parameter, `operator`, punctuation: CGColor

    static let dark = Palette(
        background: rgb(0.110, 0.118, 0.137), gutter: rgb(0.094, 0.102, 0.118), currentLine: rgb(0.145, 0.157, 0.184),
        text: rgb(0.851, 0.859, 0.878), lineNumber: rgb(0.400, 0.431, 0.482), cursor: rgb(0.380, 0.686, 0.937),
        selection: rgb(0.243, 0.380, 0.592, 0.75), inactiveSelection: rgb(0.333, 0.353, 0.396, 0.6),
        scrollbar: rgb(1, 1, 1, 0.18), searchMatch: rgb(0.851, 0.651, 0.251, 0.30), currentMatch: rgb(0.937, 0.659, 0.239, 0.65),
        statusBorder: rgb(0, 0, 0, 0.35), error: rgb(0.941, 0.443, 0.443), hudBackground: rgb(0, 0, 0, 0.72), hudText: rgb(0.6, 0.95, 0.7),
        comment: rgb(0.451, 0.494, 0.557), keyword: rgb(0.780, 0.471, 0.867), string: rgb(0.596, 0.765, 0.475),
        cyan: rgb(0.337, 0.714, 0.761), orange: rgb(0.820, 0.604, 0.400), function: rgb(0.380, 0.686, 0.937),
        type: rgb(0.898, 0.753, 0.482), red: rgb(0.890, 0.545, 0.565), parameter: rgb(0.843, 0.749, 0.659),
        operator: rgb(0.620, 0.690, 0.760), punctuation: rgb(0.580, 0.604, 0.651))

    static let light = Palette(
        background: rgb(0.996, 0.996, 0.996), gutter: rgb(0.961, 0.961, 0.969), currentLine: rgb(0.937, 0.945, 0.965),
        text: rgb(0.141, 0.153, 0.180), lineNumber: rgb(0.580, 0.600, 0.640), cursor: rgb(0.149, 0.435, 0.894),
        selection: rgb(0.643, 0.784, 0.984, 0.75), inactiveSelection: rgb(0.812, 0.831, 0.871, 0.8),
        scrollbar: rgb(0, 0, 0, 0.22), searchMatch: rgb(0.980, 0.800, 0.251, 0.40), currentMatch: rgb(0.980, 0.651, 0.149, 0.70),
        statusBorder: rgb(0, 0, 0, 0.12), error: rgb(0.800, 0.200, 0.200), hudBackground: rgb(0, 0, 0, 0.72), hudText: rgb(0.6, 0.95, 0.7),
        comment: rgb(0.478, 0.518, 0.561), keyword: rgb(0.608, 0.188, 0.702), string: rgb(0.247, 0.494, 0.157),
        cyan: rgb(0.039, 0.478, 0.529), orange: rgb(0.698, 0.380, 0.020), function: rgb(0.110, 0.388, 0.800),
        type: rgb(0.580, 0.408, 0.000), red: rgb(0.749, 0.231, 0.290), parameter: rgb(0.541, 0.353, 0.212),
        operator: rgb(0.298, 0.396, 0.498), punctuation: rgb(0.420, 0.447, 0.502))
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
