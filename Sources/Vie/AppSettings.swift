import AppKit
import Observation
import VieEditor

/// The app's settings, kept in user defaults: Vim mode, wrapping, the editor font, the
/// appearance and the light and dark themes. Each can be set for one launch on the command
/// line (`-VimMode NO`, `-WrapLines NO`, `-FontName "JetBrains Mono"`, `-FontSize 16`,
/// `-Ligatures YES`, `-Appearance dark`, `-LightTheme Paper`, `-DarkTheme Nord`).
/// Observable, so the Settings window follows changes made from the menus; every change also
/// goes to `onChange`.
@MainActor @Observable
final class AppSettings {
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored var onChange: (() -> Void)?

    private enum Key {
        static let vimMode = "VimMode", wrapLines = "WrapLines", relativeLineNumbers = "RelativeLineNumbers"
        static let fontName = "FontName", fontSize = "FontSize", ligatures = "Ligatures"
        static let appearance = "Appearance", lightTheme = "LightTheme", darkTheme = "DarkTheme"
    }

    /// Light or dark for the whole app, or whichever the Mac uses.
    enum Appearance: String, CaseIterable {
        case system, light, dark

        var title: String { rawValue.capitalized }

        /// What NSApp.appearance is set to (nil follows the system).
        var nsAppearance: NSAppearance? {
            switch self {
            case .system: nil
            case .light: NSAppearance(named: .aqua)
            case .dark: NSAppearance(named: .darkAqua)
            }
        }
    }

    var vimMode: Bool {
        didSet { defaults.set(vimMode, forKey: Key.vimMode); onChange?() }
    }

    var wrapLines: Bool {
        didSet { defaults.set(wrapLines, forKey: Key.wrapLines); onChange?() }
    }

    var relativeLineNumbers: Bool {
        didSet { defaults.set(relativeLineNumbers, forKey: Key.relativeLineNumbers); onChange?() }
    }

    /// Family (nil for SF Mono), size (kept within `EditorFont.sizes`) and ligatures.
    var font: EditorFont {
        didSet {
            let size = Self.clamp(font.size)
            if size != font.size { font.size = size }
            // Default values aren't stored, so a later change of default reaches them.
            store(font.name, Key.fontName)
            store(size == EditorFont.defaultSize ? nil : Double(size), Key.fontSize)
            store(font.ligatures ? true : nil, Key.ligatures)
            onChange?()
        }
    }

    var appearance: Appearance {
        didSet { store(appearance == .system ? nil : appearance.rawValue, Key.appearance); onChange?() }
    }

    /// The theme for light appearances, and the one for dark.
    var lightTheme: EditorTheme {
        didSet { store(lightTheme == .named(nil, dark: false) ? nil : lightTheme.name, Key.lightTheme); onChange?() }
    }

    var darkTheme: EditorTheme {
        didSet { store(darkTheme == .named(nil, dark: true) ? nil : darkTheme.name, Key.darkTheme); onChange?() }
    }

    /// `measuring`: benchmarks always use the default font and themes, so runs stay comparable.
    init(defaults: UserDefaults = .standard, measuring: Bool = false) {
        self.defaults = defaults
        defaults.register(defaults: [Key.vimMode: true, Key.wrapLines: true])
        vimMode = defaults.bool(forKey: Key.vimMode)
        wrapLines = defaults.bool(forKey: Key.wrapLines)
        relativeLineNumbers = defaults.bool(forKey: Key.relativeLineNumbers)
        let size = CGFloat(defaults.double(forKey: Key.fontSize))
        font = measuring ? EditorFont() : EditorFont(name: defaults.string(forKey: Key.fontName),
                                                     size: size > 0 ? Self.clamp(size) : EditorFont.defaultSize,
                                                     ligatures: defaults.bool(forKey: Key.ligatures))
        appearance = measuring ? .system : defaults.string(forKey: Key.appearance).flatMap(Appearance.init) ?? .system
        lightTheme = .named(measuring ? nil : defaults.string(forKey: Key.lightTheme), dark: false)
        darkTheme = .named(measuring ? nil : defaults.string(forKey: Key.darkTheme), dark: true)
    }

    static func clamp(_ size: CGFloat) -> CGFloat {
        min(max(size.rounded(), EditorFont.sizes.lowerBound), EditorFont.sizes.upperBound)
    }

    private func store(_ value: Any?, _ key: String) {
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }
}
