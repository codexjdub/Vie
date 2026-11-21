import AppKit
import Testing
import VieText
@testable import VieEditor

/// Color themes: readable colors, choosing themes, and views in light and dark appearances
/// side by side keeping their own colors.
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

    @Test func threeLightAndThreeDarkThemesWithUniqueNames() {
        #expect(EditorTheme.light.map(\.name) == ["Vie Light", "Paper", "Daylight"])
        #expect(EditorTheme.dark.map(\.name) == ["Vie Dark", "Midnight", "Ember"])
        #expect(EditorTheme.named("Paper", dark: false).name == "Paper")
        // A theme of the other appearance, or none, gives the default.
        #expect(EditorTheme.named("Paper", dark: true).name == "Vie Dark")
        #expect(EditorTheme.named(nil, dark: false).name == "Vie Light")
    }

    /// Text at least 7:1 against the background, syntax colors 4.5:1 (comments 3.5:1, being
    /// quieter on purpose), line numbers 2.5:1.
    @Test func everyThemeIsReadable() {
        for theme in EditorTheme.all {
            let bg = theme.backgroundColor
            #expect(contrast(theme.textColor, bg) >= 7, "\(theme.name) text")
            let syntax = theme.syntaxColors
            #expect(contrast(syntax[0], bg) >= 3.5, "\(theme.name) comments")
            for (i, c) in syntax.enumerated().dropFirst() {
                #expect(contrast(c, bg) >= 4.5, "\(theme.name) syntax color \(i): \(String(format: "%.2f", contrast(c, bg)))")
            }
            #expect(contrast(theme.lineNumberColor, bg) >= 2.5, "\(theme.name) line numbers")
        }
    }

    @Test func viewsInLightAndDarkAppearancesKeepTheirOwnColors() {
        defer { EditorTheme.use(light: .named(nil, dark: false), dark: .named(nil, dark: true)) }
        let light = EditorView(frame: NSRect(x: 0, y: 0, width: 300, height: 100), buffer: Buffer(rope: Rope("hello\n")))
        let dark = EditorView(frame: NSRect(x: 0, y: 0, width: 300, height: 100), buffer: Buffer(rope: Rope("hello\n")))
        light.appearance = NSAppearance(named: .aqua)
        dark.appearance = NSAppearance(named: .darkAqua)
        for _ in 0..<2 {
            #expect(color(light.styledText(0..<5)) == EditorTheme.named(nil, dark: false).textColor)
            #expect(color(dark.styledText(0..<5)) == EditorTheme.named(nil, dark: true).textColor)
        }
        EditorTheme.use(light: .named("Paper", dark: false), dark: .named("Midnight", dark: true))
        #expect(EditorTheme.inUse.light.name == "Paper" && EditorTheme.inUse.dark.name == "Midnight")
        #expect(color(dark.styledText(0..<5)) == EditorTheme.named("Midnight", dark: true).textColor)
        #expect(color(light.styledText(0..<5)) == EditorTheme.named("Paper", dark: false).textColor)
        // Switching a view's appearance switches its colors.
        light.appearance = NSAppearance(named: .darkAqua)
        #expect(color(light.styledText(0..<5)) == EditorTheme.named("Midnight", dark: true).textColor)
    }

    @Test func choosingThemesRedrawsTheViews() {
        defer { EditorTheme.use(light: .named(nil, dark: false), dark: .named(nil, dark: true)) }
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
        EditorTheme.use(light: .named("Daylight", dark: false), dark: .named("Ember", dark: true))
        for view in views { #expect(RedrawRecorder.askedForFullRedraw(view), "\(type(of: view))") }
        // Choosing the same themes again changes nothing.
        for view in views { RedrawRecorder.reset(view) }
        EditorTheme.use(light: .named("Daylight", dark: false), dark: .named("Ember", dark: true))
        for view in views { #expect(RedrawRecorder.requests(view).isEmpty, "\(type(of: view))") }
    }
}
