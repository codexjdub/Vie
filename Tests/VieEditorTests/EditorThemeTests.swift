import AppKit
import Testing
import VieText
@testable import VieEditor

/// Color themes: readable colors, choosing themes, the ports' styles, and views in light and
/// dark appearances side by side keeping their own colors.
@MainActor
@Suite struct EditorThemeTests {
    /// WCAG contrast ratio of two opaque sRGB colors.
    private func contrast(_ a: CGColor, _ b: CGColor) -> Double {
        func luminance(_ c: CGColor) -> Double {
            let rgb = (c.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil) ?? c).components!
            let lin = rgb.prefix(3).map { v -> Double in
                let v = Double(v)
                return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * lin[0] + 0.7152 * lin[1] + 0.0722 * lin[2]
        }
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    private func color(_ attr: NSAttributedString) -> CGColor {
        attr.attribute(Highlighter.colorKey, at: 0, effectiveRange: nil) as! CGColor
    }

    private func restoreDefaults() {
        EditorTheme.use(light: .named(nil, dark: false), dark: .named(nil, dark: true))
    }

    @Test func vieThemesFirstThenThePortsWithUniqueNames() {
        #expect(EditorTheme.light.map(\.name) == [
            "Vie Light", "Paper", "Mint", "Alucard", "Catppuccin Latte", "GitHub Light", "Gruvbox Light", "One Light",
            "Rosé Pine Dawn", "Solarized Light", "Tokyo Night Day",
        ])
        #expect(EditorTheme.dark.map(\.name) == [
            "Vie Dark", "Ember", "Catppuccin Frappé", "Catppuccin Macchiato", "Catppuccin Mocha", "Dracula", "GitHub Dark",
            "Gruvbox Dark", "Nord", "One Dark", "Rosé Pine", "Rosé Pine Moon", "Solarized Dark", "Tokyo Night",
            "Tokyo Night Storm", "Tokyo Night Moon",
        ])
        #expect(Set(EditorTheme.all.map(\.name)).count == EditorTheme.all.count)
        #expect(EditorTheme.all.filter(\.isVie).map(\.name) == ["Vie Light", "Paper", "Mint", "Vie Dark", "Ember"])
        #expect(EditorTheme.named("Paper", dark: false).name == "Paper")
        #expect(EditorTheme.named("Nord", dark: true).name == "Nord")
        // A theme of the other appearance, a removed one, or none, gives the default.
        #expect(EditorTheme.named("Paper", dark: true).name == "Vie Dark")
        #expect(EditorTheme.named("Midnight", dark: true).name == "Vie Dark")
        #expect(EditorTheme.named(nil, dark: false).name == "Vie Light")
    }

    /// Vie's own themes: text at least 7:1 against the background, code 4.5:1 (comments 3.5:1,
    /// being quieter on purpose), line numbers 2.5:1.
    @Test func vieThemesAreReadable() {
        for theme in EditorTheme.all where theme.isVie {
            check(theme, text: 7, code: 4.5, comments: 3.5, lineNumbers: 2.5)
        }
    }

    /// Ports keep their originals' colors, some of them much softer than Vie's own (Solarized
    /// Light's text is 4.1:1, Rosé Pine Dawn's gold 2.1:1); this only catches a color
    /// that's gone missing against its background.
    @Test func portsAreLegible() {
        for theme in EditorTheme.all where !theme.isVie {
            check(theme, text: 4, code: 1.9, comments: 1.9, lineNumbers: 1.4)
        }
    }

    private func check(_ theme: EditorTheme, text: Double, code: Double, comments: Double, lineNumbers: Double,
                       sourceLocation: SourceLocation = #_sourceLocation) {
        let bg = theme.backgroundColor
        func ratio(_ c: CGColor) -> String { String(format: "%.2f", contrast(c, bg)) }
        #expect(contrast(theme.textColor, bg) >= text, "\(theme.name) text: \(ratio(theme.textColor))", sourceLocation: sourceLocation)
        #expect(contrast(theme.commentColor, bg) >= comments, "\(theme.name) comments: \(ratio(theme.commentColor))",
                sourceLocation: sourceLocation)
        for (i, c) in theme.codeColors.enumerated() {
            #expect(contrast(c, bg) >= code, "\(theme.name) code color \(i): \(ratio(c))", sourceLocation: sourceLocation)
        }
        #expect(contrast(theme.lineNumberColor, bg) >= lineNumbers, "\(theme.name) line numbers: \(ratio(theme.lineNumberColor))",
                sourceLocation: sourceLocation)
    }

    /// Ports color kinds apart that Vie's own themes group, and draw some bold or italic.
    @Test func portsKeepTheirOwnColorsAndStyles() {
        defer { restoreDefaults() }
        EditorTheme.use(light: .named(nil, dark: false), dark: .named("Gruvbox Dark", dark: true))
        Theme.use(dark: true)
        #expect(Theme.style(.boolean).color == hex(0xD3869B))
        #expect(Theme.style(.builtinConstant).color == hex(0xFE8019))
        #expect(Theme.style(.function).bold && !Theme.style(.function).italic)
        #expect(Theme.style(.string).italic)
        EditorTheme.use(light: .named(nil, dark: false), dark: .named("Rosé Pine", dark: true))
        Theme.use(dark: true)
        #expect(Theme.style(.builtinVariable).bold && Theme.style(.builtinVariable).italic)
        #expect(Theme.cursorText == hex(0xE0DEF4))
        EditorTheme.use(light: .named(nil, dark: false), dark: .named("Tokyo Night", dark: true))
        Theme.use(dark: true)
        #expect(Theme.style(.punctuation).color == hex(0x89DDFF))
        #expect(Theme.style(.bracket).color == hex(0xA9B1D6))
        // Vie's own themes still group them.
        restoreDefaults()
        Theme.use(dark: true)
        #expect(Theme.style(.boolean).color == Theme.style(.number).color)
        #expect(Theme.style(.bracket).color == Theme.style(.punctuation).color)
        #expect(!Theme.style(.keyword).bold && !Theme.style(.comment).italic)
    }

    @Test func viewsInLightAndDarkAppearancesKeepTheirOwnColors() {
        defer { restoreDefaults() }
        let light = EditorView(frame: NSRect(x: 0, y: 0, width: 300, height: 100), buffer: Buffer(rope: Rope("hello\n")))
        let dark = EditorView(frame: NSRect(x: 0, y: 0, width: 300, height: 100), buffer: Buffer(rope: Rope("hello\n")))
        light.appearance = NSAppearance(named: .aqua)
        dark.appearance = NSAppearance(named: .darkAqua)
        for _ in 0..<2 {
            #expect(color(light.styledText(0..<5)) == EditorTheme.named(nil, dark: false).textColor)
            #expect(color(dark.styledText(0..<5)) == EditorTheme.named(nil, dark: true).textColor)
        }
        EditorTheme.use(light: .named("Paper", dark: false), dark: .named("Nord", dark: true))
        #expect(EditorTheme.inUse.light.name == "Paper" && EditorTheme.inUse.dark.name == "Nord")
        #expect(color(dark.styledText(0..<5)) == EditorTheme.named("Nord", dark: true).textColor)
        #expect(color(light.styledText(0..<5)) == EditorTheme.named("Paper", dark: false).textColor)
        // Switching a view's appearance switches its colors.
        light.appearance = NSAppearance(named: .darkAqua)
        #expect(color(light.styledText(0..<5)) == EditorTheme.named("Nord", dark: true).textColor)
    }

    @Test func choosingThemesRedrawsTheViews() {
        defer { restoreDefaults() }
        let editor = EditorView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), buffer: Buffer(rope: Rope("hello\n")))
        let status = StatusBarView(frame: NSRect(x: 0, y: 0, width: 400, height: 22), editor: editor)
        let tabs = TabBarView(frame: NSRect(x: 0, y: 0, width: 400, height: 28))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 400), styleMask: [.titled],
                              backing: .buffered, defer: false)
        let views = [editor, status, tabs] as [NSView]
        for view in views {
            window.contentView?.addSubview(view)
            view.displayIfNeeded()
            RedrawRecorder.reset(view)
        }
        EditorTheme.use(light: .named("Solarized Light", dark: false), dark: .named("Ember", dark: true))
        for view in views { #expect(RedrawRecorder.askedForFullRedraw(view), "\(type(of: view))") }
        // Choosing the same themes again changes nothing.
        for view in views { RedrawRecorder.reset(view) }
        EditorTheme.use(light: .named("Solarized Light", dark: false), dark: .named("Ember", dark: true))
        for view in views { #expect(RedrawRecorder.requests(view).isEmpty, "\(type(of: view))") }
    }
}
