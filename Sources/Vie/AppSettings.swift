import AppKit
import Observation
import VieEditor

/// The app's settings, kept in user defaults: Vim mode, wrapping and the editor font. Each can
/// be set for one launch on the command line (`-VimMode NO`, `-WrapLines NO`, `-FontName
/// "JetBrains Mono"`, `-FontSize 16`, `-Ligatures YES`). Observable, so the Settings window
/// follows changes made from the menus; every change also goes to `onChange`.
@MainActor @Observable
final class AppSettings {
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored var onChange: (() -> Void)?

    private enum Key {
        static let vimMode = "VimMode", wrapLines = "WrapLines"
        static let fontName = "FontName", fontSize = "FontSize", ligatures = "Ligatures"
    }

    var vimMode: Bool {
        didSet { defaults.set(vimMode, forKey: Key.vimMode); onChange?() }
    }

    var wrapLines: Bool {
        didSet { defaults.set(wrapLines, forKey: Key.wrapLines); onChange?() }
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

    /// `measuring`: benchmarks always use the default font, so runs stay comparable.
    init(defaults: UserDefaults = .standard, measuring: Bool = false) {
        self.defaults = defaults
        defaults.register(defaults: [Key.vimMode: true, Key.wrapLines: true])
        vimMode = defaults.bool(forKey: Key.vimMode)
        wrapLines = defaults.bool(forKey: Key.wrapLines)
        let size = CGFloat(defaults.double(forKey: Key.fontSize))
        font = measuring ? EditorFont() : EditorFont(name: defaults.string(forKey: Key.fontName),
                                                     size: size > 0 ? Self.clamp(size) : EditorFont.defaultSize,
                                                     ligatures: defaults.bool(forKey: Key.ligatures))
    }

    static func clamp(_ size: CGFloat) -> CGFloat {
        min(max(size.rounded(), EditorFont.sizes.lowerBound), EditorFont.sizes.upperBound)
    }

    private func store(_ value: Any?, _ key: String) {
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }
}
