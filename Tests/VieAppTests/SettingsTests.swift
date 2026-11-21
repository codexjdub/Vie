import AppKit
import CoreText
import Foundation
import Testing
import VieEditor
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

    @Test func settingsMenuItem() throws {
        let vie = try #require(MainMenu.build().items.first?.submenu)
        let item = try #require(vie.items.first { $0.title == "Settings…" })
        #expect(item.keyEquivalent == "," && item.keyEquivalentModifierMask == .command)
        #expect(item.action == #selector(AppDelegate.showSettings(_:)))
    }

    /// The Settings window with JetBrains Mono chosen. Set VIE_SNAPSHOT_DIR to write a PNG.
    @Test func rendersSettingsWindow() async throws {
        defer { cleanUp() }
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Vendor/fonts")
        for url in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        where url.pathExtension == "ttf" { CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil) }
        let s = AppSettings(defaults: defaults)
        s.font = EditorFont(name: "JetBrains Mono", size: 14)
        s.lightTheme = .named("Paper", dark: false)
        s.darkTheme = .named("Ember", dark: true)
        EditorTheme.use(light: s.lightTheme, dark: s.darkTheme)
        defer { EditorTheme.use(light: .named(nil, dark: false), dark: .named(nil, dark: true)) }
        let c = SettingsWindowController(settings: s)
        c.window?.appearance = NSAppearance(named: .aqua)
        let view = try #require(c.window?.contentView)
        view.layoutSubtreeIfNeeded()
        #expect(view.fittingSize.width > 400 && view.fittingSize.height > 250)
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
        if let out = ProcessInfo.processInfo.environment["VIE_SNAPSHOT_DIR"], let png = rep.representation(using: .png, properties: [:]) {
            try png.write(to: URL(fileURLWithPath: out).appendingPathComponent("settings.png"))
        }
    }
}
