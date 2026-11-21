import AppKit
import CoreText
import Foundation
import Testing
import VieEditor
import VieSyntax
import VieText
@testable import Vie

/// Settings: kept in user defaults (defaults aren't stored), and the Settings window's controls.
@MainActor
@Suite struct SettingsTests {
    private let suiteName = "vie-settings-test-\(UUID().uuidString)"
    private let defaults: UserDefaults

    init() {
        defaults = UserDefaults(suiteName: suiteName)!
        _ = NSApplication.shared
    }

    private func cleanUp() { defaults.removePersistentDomain(forName: suiteName) }

    @Test func settingsRoundTripAndLeaveDefaultsUnstored() {
        defer { cleanUp() }
        let s = AppSettings(defaults: defaults)
        var changes = 0
        s.onChange = { changes += 1 }
        #expect(s.vimMode && s.wrapLines && s.font == EditorFont())
        s.font = EditorFont(name: "JetBrains Mono", size: 15, ligatures: true)
        s.vimMode = false
        #expect(changes == 2)
        let again = AppSettings(defaults: defaults)
        #expect(again.font == EditorFont(name: "JetBrains Mono", size: 15, ligatures: true) && !again.vimMode)
        s.font = EditorFont()
        #expect(defaults.object(forKey: "FontName") == nil && defaults.object(forKey: "FontSize") == nil
                && defaults.object(forKey: "Ligatures") == nil)
        s.font.size = 100
        #expect(s.font.size == EditorFont.sizes.upperBound)
        #expect(AppSettings(defaults: defaults, measuring: true).font == EditorFont())
    }

    @Test func appearanceAndThemesRoundTripAndLeaveDefaultsUnstored() {
        defer { cleanUp() }
        let s = AppSettings(defaults: defaults)
        #expect(s.appearance == .system && s.lightTheme.name == "Vie Light" && s.darkTheme.name == "Vie Dark")
        s.appearance = .dark
        s.lightTheme = .named("Paper", dark: false)
        s.darkTheme = .named("Ember", dark: true)
        let again = AppSettings(defaults: defaults)
        #expect(again.appearance == .dark && again.lightTheme.name == "Paper" && again.darkTheme.name == "Ember")
        let measuring = AppSettings(defaults: defaults, measuring: true)
        #expect(measuring.appearance == .system && measuring.darkTheme.name == "Vie Dark")
        s.appearance = .system
        s.lightTheme = .named(nil, dark: false)
        s.darkTheme = .named(nil, dark: true)
        #expect(defaults.object(forKey: "Appearance") == nil && defaults.object(forKey: "LightTheme") == nil
                && defaults.object(forKey: "DarkTheme") == nil)
        // An unknown stored name falls back to the default.
        defaults.set("Nope", forKey: "DarkTheme")
        defaults.set("sideways", forKey: "Appearance")
        let odd = AppSettings(defaults: defaults)
        #expect(odd.darkTheme.name == "Vie Dark" && odd.appearance == .system)
        #expect(AppSettings.Appearance.system.nsAppearance == nil)
        #expect(AppSettings.Appearance.light.nsAppearance?.name == .aqua && AppSettings.Appearance.dark.nsAppearance?.name == .darkAqua)
    }

    @Test func fontMenuListsSFMonoTheBundledFontsThenInstalledOnes() {
        let fonts = SettingsWindowController.fontChoices()
        #expect(fonts.vie.map(\.title) == ["SF Mono", "JetBrains Mono", "Terminus TTF"])
        #expect(fonts.vie.map(\.name) == [nil, "JetBrains Mono", "Terminus (TTF)"])
        #expect(fonts.installed.contains { $0.name == "Menlo" && $0.title == "Menlo" })
    }

    /// The previews (Vie editors inside the SwiftUI form, one light, one dark) follow the
    /// settings, wherever they change: the form's controls, the menus, ⌘+ and ⌘−.
    @Test func previewsFollowTheSettings() async throws {
        defer { cleanUp() }
        let s = AppSettings(defaults: defaults)
        let c = SettingsWindowController(settings: s)
        let root = try #require(c.window?.contentView)
        func previews() -> [EditorView] {
            var found: [EditorView] = [], stack = [root]
            while let v = stack.popLast() {
                if let e = v as? EditorView { found.append(e) }
                stack += v.subviews
            }
            return found
        }
        root.layoutSubtreeIfNeeded()
        let views = previews()
        #expect(views.count == 2)
        #expect(Set(views.compactMap { $0.appearance?.name }) == [.aqua, .darkAqua])
        #expect(views.allSatisfy { $0.editorFont == EditorFont() })
        s.font = EditorFont(name: "Menlo", size: 16, ligatures: true)
        for _ in 0..<50 where views.contains(where: { $0.editorFont != s.font }) {
            try await Task.sleep(for: .milliseconds(10))
            root.layoutSubtreeIfNeeded()
        }
        #expect(views.allSatisfy { $0.editorFont == EditorFont(name: "Menlo", size: 16, ligatures: true) })
        #expect(views.allSatisfy { $0.wrapsLines && $0.syntaxLanguage?.name == "swift" })
    }

    /// Only the themes in use are shown: both when following the system, else just the light
    /// or dark one. The window fits the form, keeping its top edge where it was.
    @Test func themeMenusFollowTheAppearance() async throws {
        defer { cleanUp() }
        let s = AppSettings(defaults: defaults)
        let c = SettingsWindowController(settings: s)
        let window = try #require(c.window), root = try #require(window.contentView)
        func previews() -> [NSAppearance.Name] {
            var found: [NSAppearance.Name] = [], stack = [root]
            while let v = stack.popLast() {
                if let e = v as? EditorView, let name = e.appearance?.name { found.append(name) }
                stack += v.subviews
            }
            return found.sorted { $0.rawValue < $1.rawValue }
        }
        func settle(until done: () -> Bool) async throws {
            for _ in 0..<100 where !done() {
                try await Task.sleep(for: .milliseconds(10))
                root.layoutSubtreeIfNeeded()
            }
        }
        try await settle { window.frame.height > 300 }
        #expect(previews() == [.aqua, .darkAqua])
        let full = window.frame
        s.appearance = .dark
        try await settle { previews() == [.darkAqua] && window.frame.height < full.height }
        #expect(previews() == [.darkAqua])
        #expect(window.frame.height < full.height - 100 && window.frame.maxY == full.maxY)
        s.appearance = .light
        try await settle { previews() == [.aqua] }
        #expect(previews() == [.aqua])
        s.appearance = .system
        try await settle { previews().count == 2 && window.frame.height == full.height }
        #expect(previews() == [.aqua, .darkAqua] && window.frame.height == full.height && window.frame.maxY == full.maxY)
    }

    /// Edit ▸ Vim Mode is ⌃⌘V, and nothing else in the menus is.
    @Test func vimModeMenuItem() throws {
        let items = MainMenu.build().items.compactMap(\.submenu).flatMap(\.items)
        let item = try #require(items.first { $0.title == "Vim Mode" })
        #expect(item.keyEquivalent == "v" && item.keyEquivalentModifierMask == [.command, .control])
        #expect(item.action == #selector(AppDelegate.toggleVimMode(_:)))
        #expect(items.filter { $0.keyEquivalent == "v" && $0.keyEquivalentModifierMask == [.command, .control] }.count == 1)
    }

    @Test func settingsMenuItem() throws {
        let vie = try #require(MainMenu.build().items.first?.submenu)
        let item = try #require(vie.items.first { $0.title == "Settings…" })
        #expect(item.keyEquivalent == "," && item.keyEquivalentModifierMask == .command)
        #expect(item.action == #selector(AppDelegate.showSettings(_:)))
    }

    /// The Settings window with JetBrains Mono chosen, following the system (light) and set to
    /// Dark. Set VIE_SNAPSHOT_DIR to write settings.png and settings-dark.png.
    @Test(.serialized, arguments: [AppSettings.Appearance.system, .dark])
    func rendersSettingsWindow(appearance: AppSettings.Appearance) async throws {
        defer { cleanUp() }
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Vendor/fonts")
        for url in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        where url.pathExtension == "ttf" { CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil) }
        let s = AppSettings(defaults: defaults)
        s.font = EditorFont(name: "JetBrains Mono", size: 14)
        s.lightTheme = .named("Paper", dark: false)
        s.darkTheme = .named("Ember", dark: true)
        s.appearance = appearance
        EditorTheme.use(light: s.lightTheme, dark: s.darkTheme)
        defer { EditorTheme.use(light: .named(nil, dark: false), dark: .named(nil, dark: true)) }
        let c = SettingsWindowController(settings: s)
        c.window?.appearance = NSAppearance(named: appearance == .dark ? .darkAqua : .aqua)
        let view = try #require(c.window?.contentView)
        view.layoutSubtreeIfNeeded()
        #expect(view.fittingSize.width > 400 && view.fittingSize.height > 200)
        c.window?.setContentSize(view.fittingSize)
        view.layoutSubtreeIfNeeded()
        // Let the previews' first parse land, so they show syntax colors.
        var stack = [view], previews: [EditorView] = []
        while let v = stack.popLast() { if let e = v as? EditorView { previews.append(e) }; stack += v.subviews }
        for _ in 0..<100 where previews.contains(where: { $0.syntax?.isReady != true }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let out = ProcessInfo.processInfo.environment["VIE_SNAPSHOT_DIR"] else { return }
        // The capture leaves out the window's background, so draw it underneath.
        let image = NSImage(size: view.bounds.size)
        image.lockFocus()
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            view.bounds.fill()
        }
        rep.draw(in: view.bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
        image.unlockFocus()
        let tiff = try #require(image.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: out).appendingPathComponent(appearance == .dark ? "settings-dark.png" : "settings.png"))
    }

    /// Every theme on one sheet, for checking ports against their originals. Only with
    /// VIE_SNAPSHOT_DIR set (it writes themes.png there).
    @Test func rendersEveryTheme() async throws {
        guard let out = ProcessInfo.processInfo.environment["VIE_SNAPSHOT_DIR"] else { return }
        defer { EditorTheme.use(light: .named(nil, dark: false), dark: .named(nil, dark: true)) }
        let sample = """
            // A comment, 0O 1lI
            @MainActor struct Greeter: View {
                let name: String, count = 3
                func greet(_ who: String) -> String? {
                    if self.count > 0 && true { return "Hi, \\(who)!\\n" }
                    return nil
                }
            }
            """
        let tile = NSSize(width: 460, height: 240), columns = 2
        let themes = EditorTheme.all
        let rows = (themes.count + columns - 1) / columns
        let sheet = NSImage(size: NSSize(width: tile.width * CGFloat(columns), height: tile.height * CGFloat(rows)))
        var tiles: [(NSBitmapImageRep, String)] = []
        for theme in themes {
            EditorTheme.use(light: theme.isDark ? .named(nil, dark: false) : theme, dark: theme.isDark ? theme : .named(nil, dark: true))
            // Tab bar, editor and status bar, as in a window.
            let view = NSView(frame: NSRect(x: 0, y: 0, width: tile.width, height: tile.height - 22))
            view.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
            let editor = EditorView(frame: NSRect(x: 0, y: 22, width: tile.width, height: view.frame.height - 50),
                                    buffer: Buffer(rope: Rope(sample)))
            editor.syntaxLanguage = SyntaxLanguage.forFile(named: "sample.swift", firstLine: "")
            editor.editorFont = EditorFont(name: "JetBrains Mono", size: 12)
            let tabs = TabBarView(frame: NSRect(x: 0, y: view.frame.height - 28, width: tile.width, height: 28))
            tabs.tabs = [.init(title: "Greeter.swift", isDirty: false), .init(title: "README.md", isDirty: true)]
            tabs.selectedIndex = 0
            let status = StatusBarView(frame: NSRect(x: 0, y: 0, width: tile.width, height: 22), editor: editor)
            for v in [editor, tabs, status] as [NSView] { view.addSubview(v) }
            for _ in 0..<100 where editor.syntax?.isReady != true { try await Task.sleep(for: .milliseconds(10)) }
            let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            tiles.append((rep, theme.name))
        }
        sheet.lockFocus()
        NSColor.windowBackgroundColor.setFill()
        NSRect(origin: .zero, size: sheet.size).fill()
        for (i, (rep, name)) in tiles.enumerated() {
            let x = CGFloat(i % columns) * tile.width, top = sheet.size.height - CGFloat(i / columns) * tile.height
            (name as NSString).draw(at: NSPoint(x: x + 6, y: top - 17), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 12)])
            rep.draw(in: NSRect(x: x, y: top - tile.height, width: tile.width, height: tile.height - 22))
        }
        sheet.unlockFocus()
        let tiff = try #require(sheet.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: out).appendingPathComponent("themes.png"))
    }
}
