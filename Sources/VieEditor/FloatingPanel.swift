import AppKit

/// The look Vie's floating panels share (the ⌘P finder and the Space hint): the theme's
/// background tinted with its keyword color, so they stand apart from the text yet follow the
/// theme, with a thin border in that color and rounded corners.
@MainActor
public enum FloatingPanel {
    public static let cornerRadius: CGFloat = 10

    /// The theme in use for `appearance`.
    private static func palette(_ appearance: NSAppearance) -> (dark: Bool, palette: Palette) {
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return (dark, dark ? Theme.themes.dark.palette : Theme.themes.light.palette)
    }

    /// A fifth of the way to the keyword color in dark themes, an eighth in light ones; less
    /// where the theme's text would lose more than a tenth of its contrast (or drop under
    /// 4.5:1), as in themes whose text is soft to begin with, like Solarized.
    public static func background(_ appearance: NSAppearance) -> NSColor {
        let (dark, p) = palette(appearance)
        let accent = p.syntax.keyword.color
        let floor = min(4.5, contrast(p.text, p.background) * 0.9)
        var fraction: CGFloat = dark ? 0.2 : 0.12
        var tint = mix(p.background, accent, fraction)
        while contrast(p.text, tint) < floor && fraction > 0 {
            fraction = max(0, fraction - 0.01)
            tint = mix(p.background, accent, fraction)
        }
        return NSColor(cgColor: tint) ?? .windowBackgroundColor
    }

    public static func border(_ appearance: NSAppearance) -> NSColor {
        let (dark, p) = palette(appearance)
        return (NSColor(cgColor: p.syntax.keyword.color) ?? .controlAccentColor).withAlphaComponent(dark ? 0.5 : 0.4)
    }

    /// The highlight behind a chosen row (⌘P's selected file).
    public static func selection(_ appearance: NSAppearance) -> NSColor {
        let (dark, p) = palette(appearance)
        return (NSColor(cgColor: p.syntax.keyword.color) ?? .controlAccentColor).withAlphaComponent(dark ? 0.32 : 0.22)
    }
}
