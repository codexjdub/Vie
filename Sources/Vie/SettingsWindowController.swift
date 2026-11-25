import AppKit
import SwiftUI
import VieEditor
import VieSyntax
import VieText

/// Vie ▸ Settings (⌘,): a SwiftUI form in an AppKit window (the app has no SwiftUI life cycle,
/// so no Settings scene). Changes apply at once, to every window.
@MainActor
final class SettingsWindowController: NSWindowController {
    init(settings: AppSettings) {
        let host = NSHostingController(rootView: SettingsView(settings: settings, fonts: Self.fontChoices()))
        host.sizingOptions = .preferredContentSize
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable]
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// The font menu: SF Mono and the bundled fonts, then the monospaced fonts installed on
    /// this Mac. Each entry is a family name (nil for SF Mono) and its title.
    static func fontChoices() -> FontChoices {
        let choice = { (name: String?) in FontChoice(name: name, title: EditorFont.displayName(name)) }
        return FontChoices(vie: [choice(nil)] + EditorFont.bundled.map(choice),
                           installed: EditorFont.installedMonospacedFamilies().map(choice))
    }
}

struct FontChoice: Hashable {
    let name: String?
    let title: String
}

struct FontChoices {
    let vie: [FontChoice]
    let installed: [FontChoice]
}

struct SettingsView: View {
    @Bindable var settings: AppSettings
    let fonts: FontChoices

    var body: some View {
        Form {
            Picker("Font:", selection: $settings.font.name) {
                ForEach(fonts.vie, id: \.self) { Text($0.title).tag($0.name) }
                if !fonts.installed.isEmpty {
                    Divider()
                    ForEach(fonts.installed, id: \.self) { Text($0.title).tag($0.name) }
                }
            }
            .frame(width: 260)
            LabeledContent("Size:") {
                HStack(spacing: 4) {
                    TextField("Size", value: size, format: .number)
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 44)
                    Stepper("Size", value: size, in: Int(EditorFont.sizes.lowerBound)...Int(EditorFont.sizes.upperBound))
                        .labelsHidden()
                    Text("pt")
                }
            }
            Toggle("Ligatures: != as ≠, -> as →", isOn: $settings.font.ligatures)
            Divider()
            LabeledContent("Appearance:") {
                Picker("Appearance", selection: $settings.appearance) {
                    ForEach(AppSettings.Appearance.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .frame(width: 260, alignment: .leading)
            }
            // Only the themes in use: both when following the system, else the one that applies.
            // The other choice is kept, just not shown.
            let system = settings.appearance == .system
            if settings.appearance != .dark {
                themeMenu(system ? "When light:" : "Theme:", $settings.lightTheme, EditorTheme.light)
                preview(dark: false)
            }
            if settings.appearance != .light {
                themeMenu(system ? "When dark:" : "Theme:", $settings.darkTheme, EditorTheme.dark)
                preview(dark: true)
            }
            Divider()
            LabeledContent("Editing:") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Vim mode", isOn: $settings.vimMode)
                    Toggle("Wrap lines", isOn: $settings.wrapLines)
                    Toggle("Relative line numbers", isOn: $settings.relativeLineNumbers)
                }
            }
        }
        .formStyle(.columns)
        .padding(20)
        .fixedSize()
    }

    /// Vie's own themes, then the ports of popular ones.
    private func themeMenu(_ label: String, _ selection: Binding<EditorTheme>, _ themes: [EditorTheme]) -> some View {
        Picker(label, selection: selection) {
            ForEach(themes.filter(\.isVie), id: \.self) { Text($0.name).tag($0) }
            Divider()
            ForEach(themes.filter { !$0.isVie }, id: \.self) { Text($0.name).tag($0) }
        }
        .frame(width: 260)
    }

    /// The chosen light or dark theme, in the font chosen above.
    private func preview(dark: Bool) -> some View {
        EditorPreview(font: settings.font, dark: dark)
            .frame(width: 420, height: 120)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color(nsColor: .separatorColor)))
    }

    /// The size in whole points; AppSettings keeps it in range.
    private var size: Binding<Int> {
        Binding(get: { Int(settings.font.size) }, set: { settings.font.size = CGFloat($0) })
    }
}

/// A small Vie editor showing highlighted Swift in the chosen font, in a light or dark
/// appearance (so it draws with that theme, whatever the app's appearance).
struct EditorPreview: NSViewRepresentable {
    let font: EditorFont
    let dark: Bool

    /// Short enough not to reach the edge at the default size; lines aren't wrapped, so at
    /// bigger sizes they run off it, as in the editor.
    static let sample = """
        // 0O 1lI  != -> <= ==
        func greet(_ name: String) {
            let message = "Hi, \\(name)!"
            print(message)
        }
        """

    func makeNSView(context: Context) -> EditorView {
        let view = EditorView(frame: NSRect(x: 0, y: 0, width: 420, height: 130), buffer: Buffer(rope: Rope(Self.sample)))
        view.syntaxLanguage = SyntaxLanguage.forFile(named: "sample.swift", firstLine: "")
        view.editorFont = font
        view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        return view
    }

    func updateNSView(_ view: EditorView, context: Context) {
        view.editorFont = font
    }
}
