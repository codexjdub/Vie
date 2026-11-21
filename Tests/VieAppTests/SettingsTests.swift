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

    @Test func fontMenuListsSFMonoTheBundledFontsThenInstalledOnes() {
        let fonts = SettingsWindowController.fontChoices()
        #expect(fonts.vie.map(\.title) == ["SF Mono", "JetBrains Mono", "Terminus TTF"])
        #expect(fonts.vie.map(\.name) == [nil, "JetBrains Mono", "Terminus (TTF)"])
        #expect(fonts.installed.contains { $0.name == "Menlo" && $0.title == "Menlo" })
    }

    /// The preview (a Vie editor inside the SwiftUI form) follows the settings, wherever they
    /// change: the form's controls, the menus, ⌘+ and ⌘−.
    @Test func previewFollowsTheSettings() async throws {
        defer { cleanUp() }
        let s = AppSettings(defaults: defaults)
        let c = SettingsWindowController(settings: s)
        let root = try #require(c.window?.contentView)
        func preview() -> EditorView? {
            var stack = [root]
            while let v = stack.popLast() {
                if let e = v as? EditorView { return e }
                stack += v.subviews
            }
            return nil
        }
        root.layoutSubtreeIfNeeded()
        let view = try #require(preview())
        #expect(view.editorFont == EditorFont())
        s.font = EditorFont(name: "Menlo", size: 16, ligatures: true)
        for _ in 0..<50 where view.editorFont != s.font {
            try await Task.sleep(for: .milliseconds(10))
            root.layoutSubtreeIfNeeded()
        }
        #expect(view.editorFont == EditorFont(name: "Menlo", size: 16, ligatures: true))
        #expect(view.wrapsLines && view.syntaxLanguage?.name == "swift")
    }

    @Test func settingsMenuItem() throws {
        let vie = try #require(MainMenu.build().items.first?.submenu)
        let item = try #require(vie.items.first { $0.title == "Settings…" })
        #expect(item.keyEquivalent == "," && item.keyEquivalentModifierMask == .command)
        #expect(item.action == #selector(AppDelegate.showSettings(_:)))
    }

    /// The Settings window with JetBrains Mono chosen. Set VIE_SNAPSHOT_DIR to write a PNG.
    @Test func rendersSettingsWindow() throws {
        defer { cleanUp() }
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Vendor/fonts")
        for url in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        where url.pathExtension == "ttf" { CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil) }
        let s = AppSettings(defaults: defaults)
        s.font = EditorFont(name: "JetBrains Mono", size: 14)
        let c = SettingsWindowController(settings: s)
        c.window?.appearance = NSAppearance(named: .aqua)
        let view = try #require(c.window?.contentView)
        view.layoutSubtreeIfNeeded()
        #expect(view.fittingSize.width > 400 && view.fittingSize.height > 250)
        c.window?.setContentSize(view.fittingSize)
        view.layoutSubtreeIfNeeded()
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        if let out = ProcessInfo.processInfo.environment["VIE_SNAPSHOT_DIR"], let png = rep.representation(using: .png, properties: [:]) {
            try png.write(to: URL(fileURLWithPath: out).appendingPathComponent("settings.png"))
        }
    }
}
