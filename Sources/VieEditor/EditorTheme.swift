import AppKit

/// A color theme for one appearance: the editor's colors and the syntax colors. Vie has its
/// own light and dark themes and ports of popular ones (EditorTheme+Ports.swift); Settings
/// picks one of each, and views use the one matching their appearance.
public struct EditorTheme: Sendable, Hashable {
    public let name: String
    public let isDark: Bool
    let palette: Palette

    public static func == (a: EditorTheme, b: EditorTheme) -> Bool { a.name == b.name && a.isDark == b.isDark }
    public func hash(into hasher: inout Hasher) { hasher.combine(name); hasher.combine(isDark) }

    /// Vie's own themes, which Settings lists first.
    static let vie: [EditorTheme] = [vieLight, paper, mint, neonLight, vieDark, ember]
    public static let all: [EditorTheme] = vie + ports
    public static var light: [EditorTheme] { all.filter { !$0.isDark } }
    public static var dark: [EditorTheme] { all.filter(\.isDark) }

    /// Whether this is one of Vie's own themes rather than a port.
    public var isVie: Bool { Self.vie.contains(self) }

    /// The theme called `name` for that appearance, or Vie Light or Vie Dark.
    public static func named(_ name: String?, dark: Bool) -> EditorTheme {
        all.first { $0.name == name && $0.isDark == dark } ?? (dark ? vieDark : vieLight)
    }

    /// Chooses the themes every view uses from now on; open views redraw.
    @MainActor public static func use(light: EditorTheme, dark: EditorTheme) {
        Theme.choose(light: light, dark: dark)
    }

    /// Posted when the themes in use change.
    public static let didChange = Notification.Name("VieThemeDidChange")

    /// The themes in use.
    @MainActor public static var inUse: (light: EditorTheme, dark: EditorTheme) { Theme.themes }

    /// Text and background colors, for tests and swatches.
    public var textColor: CGColor { palette.text }
    public var backgroundColor: CGColor { palette.background }
    public var commentColor: CGColor { palette.syntax.comment.color }
    /// The syntax colors other than comments.
    public var codeColors: [CGColor] { palette.syntax.code.map(\.color) }
    public var lineNumberColor: CGColor { palette.lineNumber }

    // MARK: - Vie's themes

    /// Cool grays with soft colors (the syntax colors are One Dark's).
    static let vieDark = EditorTheme(name: "Vie Dark", isDark: true, palette: Palette(
        background: rgb(0.110, 0.118, 0.137), gutter: rgb(0.094, 0.102, 0.118), bar: rgb(0.094, 0.102, 0.118),
        currentLine: rgb(0.145, 0.157, 0.184), text: rgb(0.851, 0.859, 0.878), lineNumber: rgb(0.400, 0.431, 0.482), secondaryText: rgb(0.400, 0.431, 0.482),
        cursor: rgb(0.380, 0.686, 0.937), cursorText: rgb(0.110, 0.118, 0.137),
        selection: rgb(0.243, 0.380, 0.592, 0.75), inactiveSelection: rgb(0.333, 0.353, 0.396, 0.6),
        scrollbar: rgb(1, 1, 1, 0.18), searchMatch: rgb(0.851, 0.651, 0.251, 0.30), currentMatch: rgb(0.937, 0.659, 0.239, 0.65),
        statusBorder: rgb(0, 0, 0, 0.35), error: rgb(0.941, 0.443, 0.443),
        syntax: .grouped(comment: rgb(0.451, 0.494, 0.557), keyword: rgb(0.780, 0.471, 0.867), string: rgb(0.596, 0.765, 0.475),
                         builtin: rgb(0.337, 0.714, 0.761), constant: rgb(0.820, 0.604, 0.400), function: rgb(0.380, 0.686, 0.937),
                         type: rgb(0.898, 0.753, 0.482), member: rgb(0.890, 0.545, 0.565), parameter: rgb(0.843, 0.749, 0.659),
                         operator: rgb(0.620, 0.690, 0.760), punctuation: rgb(0.580, 0.604, 0.651))))

    /// Warm charcoal with amber, terracotta and olive.
    static let ember = EditorTheme(name: "Ember", isDark: true, palette: Palette(
        background: hex(0x1F1A17), gutter: hex(0x1A1613), bar: hex(0x1A1613), currentLine: hex(0x2A2420),
        text: hex(0xE8DCCB), lineNumber: hex(0x6E6157), secondaryText: hex(0x6E6157), cursor: hex(0xFFB347), cursorText: hex(0x1F1A17),
        selection: hex(0xB06E3C, 0.45), inactiveSelection: hex(0x6E5F55, 0.5),
        scrollbar: rgb(1, 1, 1, 0.16), searchMatch: hex(0xE6B450, 0.30), currentMatch: hex(0xF0AA46, 0.65),
        statusBorder: rgb(0, 0, 0, 0.4), error: hex(0xF07167),
        syntax: .grouped(comment: hex(0x8E7E70), keyword: hex(0xE07A5F), string: hex(0xA9C46C),
                         builtin: hex(0x7CB7C9), constant: hex(0xD9A0C8), function: hex(0xF2B35B),
                         type: hex(0x9DC3B0), member: hex(0xE39B7B), parameter: hex(0xE6CFA8),
                         operator: hex(0xC2AE98), punctuation: hex(0xA2917F))))

    /// Near-white with clear, saturated colors.
    static let vieLight = EditorTheme(name: "Vie Light", isDark: false, palette: Palette(
        background: rgb(0.996, 0.996, 0.996), gutter: rgb(0.961, 0.961, 0.969), bar: rgb(0.961, 0.961, 0.969),
        currentLine: rgb(0.937, 0.945, 0.965), text: rgb(0.141, 0.153, 0.180), lineNumber: rgb(0.580, 0.600, 0.640), secondaryText: rgb(0.580, 0.600, 0.640),
        cursor: rgb(0.149, 0.435, 0.894), cursorText: rgb(0.996, 0.996, 0.996),
        selection: rgb(0.643, 0.784, 0.984, 0.75), inactiveSelection: rgb(0.812, 0.831, 0.871, 0.8),
        scrollbar: rgb(0, 0, 0, 0.22), searchMatch: rgb(0.980, 0.800, 0.251, 0.40), currentMatch: rgb(0.980, 0.651, 0.149, 0.70),
        statusBorder: rgb(0, 0, 0, 0.12), error: rgb(0.800, 0.200, 0.200),
        syntax: .grouped(comment: rgb(0.478, 0.518, 0.561), keyword: rgb(0.608, 0.188, 0.702), string: rgb(0.247, 0.494, 0.157),
                         builtin: rgb(0.039, 0.478, 0.529), constant: rgb(0.698, 0.380, 0.020), function: rgb(0.110, 0.388, 0.800),
                         type: rgb(0.580, 0.408, 0.000), member: rgb(0.749, 0.231, 0.290), parameter: rgb(0.541, 0.353, 0.212),
                         operator: rgb(0.298, 0.396, 0.498), punctuation: rgb(0.420, 0.447, 0.502))))

    /// Warm cream with ink-like colors.
    static let paper = EditorTheme(name: "Paper", isDark: false, palette: Palette(
        background: hex(0xFAF6EE), gutter: hex(0xF2EDE2), bar: hex(0xF2EDE2), currentLine: hex(0xF0E9DA),
        text: hex(0x2E2A24), lineNumber: hex(0xA39A8A), secondaryText: hex(0xA39A8A), cursor: hex(0xC2410C), cursorText: hex(0xFAF6EE),
        selection: hex(0xD6B478, 0.45), inactiveSelection: hex(0xC8BEAA, 0.5),
        scrollbar: rgb(0, 0, 0, 0.20), searchMatch: hex(0xF0BE3C, 0.40), currentMatch: hex(0xEB9628, 0.65),
        statusBorder: rgb(0, 0, 0, 0.10), error: hex(0xB42318),
        syntax: .grouped(comment: hex(0x857B6B), keyword: hex(0xA23B72), string: hex(0x4D7C0F),
                         builtin: hex(0x0E7490), constant: hex(0xB45309), function: hex(0x2B59A3),
                         type: hex(0x8A5A00), member: hex(0xB42345), parameter: hex(0x7C4A2D),
                         operator: hex(0x5B5348), punctuation: hex(0x776D60))))

    /// Pale mint with deep, earthy colors.
    static let mint = EditorTheme(name: "Mint", isDark: false, palette: Palette(
        background: hex(0xEFF7EF), gutter: hex(0xE6F0E7), bar: hex(0xE6F0E7), currentLine: hex(0xE2EFE3),
        text: hex(0x1E2A22), lineNumber: hex(0x7D8C80), secondaryText: hex(0x7D8C80), cursor: hex(0x0F7A47), cursorText: hex(0xEFF7EF),
        selection: hex(0x8FD3B6, 0.6), inactiveSelection: hex(0xB9CDBF, 0.55),
        scrollbar: rgb(0, 0, 0, 0.20), searchMatch: hex(0xF0BE3C, 0.40), currentMatch: hex(0xEB9628, 0.65),
        statusBorder: rgb(0, 0, 0, 0.10), error: hex(0xB42318),
        syntax: .grouped(comment: hex(0x5F6E62), keyword: hex(0x86267F), string: hex(0x2C6512),
                         builtin: hex(0x0A6670), constant: hex(0x9A4600), function: hex(0x1D50A6),
                         type: hex(0x735000), member: hex(0xA0233A), parameter: hex(0x6E4127),
                         operator: hex(0x4A5751), punctuation: hex(0x5C6962))))


    /// Dracula's colors made for daylight: its hues as vivid as they go on light lavender, at
    /// 4.0:1 rather than Vie's usual 4.5:1 so they keep their glow, with strings nudged to
    /// amber, types to azure, functions to lime and parameters to red-orange, where Dracula's
    /// own pale hues would go muddy. Dracula's comment color, and its background as the text.
    /// The line numbers sit quietly in a gray band, so the colors have the attention.
    static let neonLight = EditorTheme(name: "Neon Light", isDark: false, palette: Palette(
        background: hex(0xFBFAFF), gutter: hex(0xF4F4F7), bar: hex(0xF7F6FF), currentLine: hex(0xF3F0FF),
        text: hex(0x282A36), lineNumber: hex(0x9C9CAB), secondaryText: hex(0x847EA8), cursor: hex(0x9900FF), cursorText: hex(0xFBFAFF),
        selection: hex(0xC9B0FF, 0.5), inactiveSelection: hex(0xD6D0EA, 0.55),
        scrollbar: rgb(0, 0, 0, 0.20), searchMatch: hex(0xFFC83D, 0.45), currentMatch: hex(0xFF8A3D, 0.6),
        statusBorder: rgb(0, 0, 0, 0.08), error: hex(0xE80029),
        syntax: .dracula(foreground: 0x282A36, comment: 0x6272A4, orange: 0xD74F00, yellow: 0xA57200, green: 0x2A8F00,
                         cyan: 0x0083BD, purple: 0x9900FF, pink: 0xE900A4)))
}

/// One theme's colors.
struct Palette: Sendable {
    var background, gutter, bar, currentLine, text, lineNumber: CGColor
    /// Quieter text in the bars: unselected tabs, the status bar's position.
    var secondaryText: CGColor
    var cursor, cursorText: CGColor
    var selection, inactiveSelection, scrollbar, searchMatch, currentMatch, statusBorder, error: CGColor
    var syntax: Syntax
    var hudBackground = rgb(0, 0, 0, 0.72), hudText = rgb(0.6, 0.95, 0.7)
}

extension Palette {
    /// A port: the colors the original theme defines, and the rest worked out from them.
    /// `gutter` is the line numbers' background (the editor's unless the theme gives one);
    /// the tab and status bars are a shade darker than the editor, with their quieter text in
    /// the line number or comment color, whichever reads better (some themes keep line
    /// numbers very dim).
    init(dark: Bool, background: CGColor, gutter: CGColor? = nil, currentLine: CGColor, text: CGColor,
         lineNumber: CGColor, cursor: CGColor, cursorText: CGColor? = nil, selection: CGColor,
         search: CGColor, currentSearch: CGColor, error: CGColor, syntax: Syntax) {
        self.init(background: background, gutter: gutter ?? background,
                  bar: mix(background, rgb(0, 0, 0), dark ? 0.2 : 0.04), currentLine: currentLine,
                  text: text, lineNumber: lineNumber,
                  secondaryText: contrast(lineNumber, background) >= contrast(syntax.comment.color, background) ? lineNumber : syntax.comment.color,
                  cursor: cursor, cursorText: cursorText ?? background,
                  selection: selection, inactiveSelection: selection.copy(alpha: selection.alpha * 0.5) ?? selection,
                  scrollbar: dark ? rgb(1, 1, 1, 0.18) : rgb(0, 0, 0, 0.22), searchMatch: search, currentMatch: currentSearch,
                  statusBorder: dark ? rgb(0, 0, 0, 0.35) : rgb(0, 0, 0, 0.12), error: error, syntax: syntax)
    }
}

/// A syntax color, and whether its theme draws it bold or italic.
struct Ink: Sendable {
    var color: CGColor
    var isBold = false, isItalic = false

    var bold: Ink { var ink = self; ink.isBold = true; return ink }
    var italic: Ink { var ink = self; ink.isItalic = true; return ink }
}

/// The colors of code, one for each kind of highlight (`Theme.makeStyle` maps them).
struct Syntax: Sendable {
    var comment, keyword, string, escape, builtinFunction, label, link: Ink
    var number, constant, boolean, builtinConstant, attribute, function, type, builtinType, module: Ink
    var builtinVariable, property, tag, parameter, `operator`, punctuation, bracket, heading: Ink

    /// Everything but comments.
    var code: [Ink] {
        [keyword, string, escape, builtinFunction, label, link, number, constant, boolean, builtinConstant, attribute,
         function, type, builtinType, module, builtinVariable, property, tag, parameter, `operator`, punctuation, bracket, heading]
    }

    /// Vie's own themes group the kinds: escapes, built-in functions, labels and links share a
    /// color; so do numbers, constants and attributes; types and modules; built-in variables,
    /// properties and tags. Headings use the function color.
    static func grouped(comment: CGColor, keyword: CGColor, string: CGColor, builtin: CGColor, constant: CGColor,
                        function: CGColor, type: CGColor, member: CGColor, parameter: CGColor, operator: CGColor,
                        punctuation: CGColor) -> Syntax {
        let builtin = Ink(color: builtin), constant = Ink(color: constant), type = Ink(color: type), member = Ink(color: member)
        let punctuation = Ink(color: punctuation)
        return Syntax(comment: Ink(color: comment), keyword: Ink(color: keyword), string: Ink(color: string),
                      escape: builtin, builtinFunction: builtin, label: builtin, link: builtin,
                      number: constant, constant: constant, boolean: constant, builtinConstant: constant, attribute: constant,
                      function: Ink(color: function), type: type, builtinType: type, module: type,
                      builtinVariable: member, property: member, tag: member, parameter: Ink(color: parameter),
                      operator: Ink(color: `operator`), punctuation: punctuation, bracket: punctuation, heading: Ink(color: function))
    }
}

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: a)
}

/// An sRGB color from 0xRRGGBB.
func hex(_ v: UInt32, _ a: CGFloat = 1) -> CGColor {
    rgb(CGFloat(v >> 16 & 0xFF) / 255, CGFloat(v >> 8 & 0xFF) / 255, CGFloat(v & 0xFF) / 255, a)
}

/// The WCAG contrast ratio of two opaque colors.
func contrast(_ a: CGColor, _ b: CGColor) -> CGFloat {
    func luminance(_ c: CGColor) -> CGFloat {
        guard let rgb = c.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)?.components
        else { return 0 }
        let lin = rgb.prefix(3).map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin[0] + 0.7152 * lin[1] + 0.0722 * lin[2]
    }
    let (x, y) = (luminance(a), luminance(b))
    return (max(x, y) + 0.05) / (min(x, y) + 0.05)
}

/// `a` moved `t` of the way to `b`, in sRGB.
func mix(_ a: CGColor, _ b: CGColor, _ t: CGFloat) -> CGColor {
    let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let x = a.converted(to: srgb, intent: .defaultIntent, options: nil)?.components,
          let y = b.converted(to: srgb, intent: .defaultIntent, options: nil)?.components else { return a }
    return rgb(x[0] + (y[0] - x[0]) * t, x[1] + (y[1] - x[1]) * t, x[2] + (y[2] - x[2]) * t, x[3] + (y[3] - x[3]) * t)
}
