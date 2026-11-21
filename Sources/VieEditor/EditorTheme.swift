import AppKit

/// A color theme for one appearance: the editor's colors and the syntax colors. Vie has three
/// light and three dark ones; Settings picks one of each, and views use the one matching their
/// appearance.
public struct EditorTheme: Sendable, Hashable {
    public let name: String
    public let isDark: Bool
    let palette: Palette

    public static func == (a: EditorTheme, b: EditorTheme) -> Bool { a.name == b.name && a.isDark == b.isDark }
    public func hash(into hasher: inout Hasher) { hasher.combine(name); hasher.combine(isDark) }

    public static let all: [EditorTheme] = [vieLight, paper, daylight, vieDark, midnight, ember]
    public static var light: [EditorTheme] { all.filter { !$0.isDark } }
    public static var dark: [EditorTheme] { all.filter(\.isDark) }

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
    /// The syntax colors (comments first).
    public var syntaxColors: [CGColor] {
        let p = palette
        return [p.comment, p.keyword, p.string, p.cyan, p.orange, p.function, p.type, p.red, p.parameter, p.operator, p.punctuation]
    }
    public var lineNumberColor: CGColor { palette.lineNumber }

    // MARK: - The themes

    /// Cool grays with soft colors.
    static let vieDark = EditorTheme(name: "Vie Dark", isDark: true, palette: Palette(
        background: rgb(0.110, 0.118, 0.137), gutter: rgb(0.094, 0.102, 0.118), currentLine: rgb(0.145, 0.157, 0.184),
        text: rgb(0.851, 0.859, 0.878), lineNumber: rgb(0.400, 0.431, 0.482), cursor: rgb(0.380, 0.686, 0.937),
        selection: rgb(0.243, 0.380, 0.592, 0.75), inactiveSelection: rgb(0.333, 0.353, 0.396, 0.6),
        scrollbar: rgb(1, 1, 1, 0.18), searchMatch: rgb(0.851, 0.651, 0.251, 0.30), currentMatch: rgb(0.937, 0.659, 0.239, 0.65),
        statusBorder: rgb(0, 0, 0, 0.35), error: rgb(0.941, 0.443, 0.443), hudBackground: rgb(0, 0, 0, 0.72), hudText: rgb(0.6, 0.95, 0.7),
        comment: rgb(0.451, 0.494, 0.557), keyword: rgb(0.780, 0.471, 0.867), string: rgb(0.596, 0.765, 0.475),
        cyan: rgb(0.337, 0.714, 0.761), orange: rgb(0.820, 0.604, 0.400), function: rgb(0.380, 0.686, 0.937),
        type: rgb(0.898, 0.753, 0.482), red: rgb(0.890, 0.545, 0.565), parameter: rgb(0.843, 0.749, 0.659),
        operator: rgb(0.620, 0.690, 0.760), punctuation: rgb(0.580, 0.604, 0.651)))

    /// Near-black with bright text and vivid colors, for the most contrast.
    static let midnight = EditorTheme(name: "Midnight", isDark: true, palette: Palette(
        background: hex(0x0B0D12), gutter: hex(0x08090D), currentLine: hex(0x151924),
        text: hex(0xF2F4F8), lineNumber: hex(0x5A6275), cursor: hex(0x4FC3F7),
        selection: hex(0x4078DC, 0.55), inactiveSelection: hex(0x505868, 0.55),
        scrollbar: rgb(1, 1, 1, 0.22), searchMatch: hex(0xE0B040, 0.35), currentMatch: hex(0xF0B040, 0.70),
        statusBorder: rgb(0, 0, 0, 0.5), error: hex(0xFF6B6B), hudBackground: rgb(0, 0, 0, 0.72), hudText: rgb(0.6, 0.95, 0.7),
        comment: hex(0x7D879B), keyword: hex(0xD08CFF), string: hex(0x8FE388),
        cyan: hex(0x5DE4F0), orange: hex(0xFFB86B), function: hex(0x6CB6FF),
        type: hex(0xFFD866), red: hex(0xFF7A90), parameter: hex(0xF0D0B0),
        operator: hex(0xA8C7FA), punctuation: hex(0x9AA4B8)))

    /// Warm charcoal with amber, terracotta and olive.
    static let ember = EditorTheme(name: "Ember", isDark: true, palette: Palette(
        background: hex(0x1F1A17), gutter: hex(0x1A1613), currentLine: hex(0x2A2420),
        text: hex(0xE8DCCB), lineNumber: hex(0x6E6157), cursor: hex(0xFFB347),
        selection: hex(0xB06E3C, 0.45), inactiveSelection: hex(0x6E5F55, 0.5),
        scrollbar: rgb(1, 1, 1, 0.16), searchMatch: hex(0xE6B450, 0.30), currentMatch: hex(0xF0AA46, 0.65),
        statusBorder: rgb(0, 0, 0, 0.4), error: hex(0xF07167), hudBackground: rgb(0, 0, 0, 0.72), hudText: rgb(0.6, 0.95, 0.7),
        comment: hex(0x8E7E70), keyword: hex(0xE07A5F), string: hex(0xA9C46C),
        cyan: hex(0x7CB7C9), orange: hex(0xD9A0C8), function: hex(0xF2B35B),
        type: hex(0x9DC3B0), red: hex(0xE39B7B), parameter: hex(0xE6CFA8),
        operator: hex(0xC2AE98), punctuation: hex(0xA2917F)))

    /// Near-white with clear, saturated colors.
    static let vieLight = EditorTheme(name: "Vie Light", isDark: false, palette: Palette(
        background: rgb(0.996, 0.996, 0.996), gutter: rgb(0.961, 0.961, 0.969), currentLine: rgb(0.937, 0.945, 0.965),
        text: rgb(0.141, 0.153, 0.180), lineNumber: rgb(0.580, 0.600, 0.640), cursor: rgb(0.149, 0.435, 0.894),
        selection: rgb(0.643, 0.784, 0.984, 0.75), inactiveSelection: rgb(0.812, 0.831, 0.871, 0.8),
        scrollbar: rgb(0, 0, 0, 0.22), searchMatch: rgb(0.980, 0.800, 0.251, 0.40), currentMatch: rgb(0.980, 0.651, 0.149, 0.70),
        statusBorder: rgb(0, 0, 0, 0.12), error: rgb(0.800, 0.200, 0.200), hudBackground: rgb(0, 0, 0, 0.72), hudText: rgb(0.6, 0.95, 0.7),
        comment: rgb(0.478, 0.518, 0.561), keyword: rgb(0.608, 0.188, 0.702), string: rgb(0.247, 0.494, 0.157),
        cyan: rgb(0.039, 0.478, 0.529), orange: rgb(0.698, 0.380, 0.020), function: rgb(0.110, 0.388, 0.800),
        type: rgb(0.580, 0.408, 0.000), red: rgb(0.749, 0.231, 0.290), parameter: rgb(0.541, 0.353, 0.212),
        operator: rgb(0.298, 0.396, 0.498), punctuation: rgb(0.420, 0.447, 0.502)))

    /// Warm cream with ink-like colors.
    static let paper = EditorTheme(name: "Paper", isDark: false, palette: Palette(
        background: hex(0xFAF6EE), gutter: hex(0xF2EDE2), currentLine: hex(0xF0E9DA),
        text: hex(0x2E2A24), lineNumber: hex(0xA39A8A), cursor: hex(0xC2410C),
        selection: hex(0xD6B478, 0.45), inactiveSelection: hex(0xC8BEAA, 0.5),
        scrollbar: rgb(0, 0, 0, 0.20), searchMatch: hex(0xF0BE3C, 0.40), currentMatch: hex(0xEB9628, 0.65),
        statusBorder: rgb(0, 0, 0, 0.10), error: hex(0xB42318), hudBackground: rgb(0, 0, 0, 0.72), hudText: rgb(0.6, 0.95, 0.7),
        comment: hex(0x857B6B), keyword: hex(0xA23B72), string: hex(0x4D7C0F),
        cyan: hex(0x0E7490), orange: hex(0xB45309), function: hex(0x2B59A3),
        type: hex(0x8A5A00), red: hex(0xB42345), parameter: hex(0x7C4A2D),
        operator: hex(0x5B5348), punctuation: hex(0x776D60)))

    /// Pure white with black text and strong colors, for the most contrast.
    static let daylight = EditorTheme(name: "Daylight", isDark: false, palette: Palette(
        background: hex(0xFFFFFF), gutter: hex(0xF4F5F7), currentLine: hex(0xEEF3FB),
        text: hex(0x0A0A0A), lineNumber: hex(0x6B7280), cursor: hex(0x0050D0),
        selection: hex(0x78AAFF, 0.45), inactiveSelection: hex(0xC8CDD7, 0.7),
        scrollbar: rgb(0, 0, 0, 0.25), searchMatch: hex(0xFFD600, 0.45), currentMatch: hex(0xFF9600, 0.70),
        statusBorder: rgb(0, 0, 0, 0.15), error: hex(0xC00000), hudBackground: rgb(0, 0, 0, 0.72), hudText: rgb(0.6, 0.95, 0.7),
        comment: hex(0x5F6B7A), keyword: hex(0x9B00B5), string: hex(0x1A7F00),
        cyan: hex(0x00718A), orange: hex(0xB34700), function: hex(0x0047C2),
        type: hex(0x8A5300), red: hex(0xC2002F), parameter: hex(0x6E3B00),
        operator: hex(0x303A48), punctuation: hex(0x4A5260)))
}

/// One theme's colors.
struct Palette: Sendable {
    var background, gutter, currentLine, text, lineNumber, cursor, selection, inactiveSelection: CGColor
    var scrollbar, searchMatch, currentMatch, statusBorder, error, hudBackground, hudText: CGColor
    // Syntax.
    var comment, keyword, string, cyan, orange, function, type, red, parameter, `operator`, punctuation: CGColor
}

private func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: a)
}

private func hex(_ v: UInt32, _ a: CGFloat = 1) -> CGColor {
    rgb(CGFloat(v >> 16 & 0xFF) / 255, CGFloat(v >> 8 & 0xFF) / 255, CGFloat(v & 0xFF) / 255, a)
}
