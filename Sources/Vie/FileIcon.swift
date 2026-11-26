import AppKit

/// The small symbol the tree and ⌘P show beside a name: what kind of item it is, in a color
/// for that kind, as code editors do (the Swift bird, braces for code in the language's color,
/// a picture for images), softened toward gray so the tree stays quiet. Finder's own icons
/// would all be the same white page at this size.
@MainActor
enum FileIcon {
    struct Style: Equatable {
        let symbol: String
        /// The kind's own color (orange for Swift)…
        let tint: NSColor
        /// …and the one drawn: softened (see `soften`), unless `muted` is false.
        let color: NSColor

        init(symbol: String, color tint: NSColor, muted: Bool = true) {
            self.symbol = symbol
            self.tint = tint
            color = muted ? FileIcon.soften(tint) : tint
        }
    }

    /// `color` mixed 40% of the way to gray, for light and dark mode each.
    nonisolated static func soften(_ color: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            var mixed = color
            appearance.performAsCurrentDrawingAppearance {
                if let c = color.usingColorSpace(.sRGB), let gray = NSColor.systemGray.usingColorSpace(.sRGB) {
                    mixed = c.blended(withFraction: 0.4, of: gray) ?? c
                }
            }
            return mixed
        }
    }

    /// Folders keep the accent color, as in Finder's sidebar.
    private static let folder = Style(symbol: "folder", color: .controlAccentColor, muted: false)

    /// The symbol and color for an item named `name`.
    static func style(forName name: String, isDirectory: Bool) -> Style {
        if isDirectory { return folder }
        let lower = name.lowercased()
        if let style = byName[lower] { return style }
        let ext = lower.hasPrefix(".") && !lower.dropFirst().contains(".") ? "" : (lower as NSString).pathExtension
        return byExtension[ext] ?? plain
    }

    /// The symbol's image (shared between rows), tinted with `contentTintColor`.
    static func image(_ style: Style) -> NSImage? {
        if let image = images[style.symbol] { return image }
        let image = NSImage(systemSymbolName: style.symbol, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: plain.symbol, accessibilityDescription: nil)
        images[style.symbol] = image
        return image
    }

    private static var images: [String: NSImage?] = [:]

    static let plain = Style(symbol: "doc", color: .secondaryLabelColor, muted: false)

    private static func code(_ color: NSColor) -> Style { Style(symbol: "curlybraces", color: color) }

    private static let text = Style(symbol: "doc.plaintext", color: .secondaryLabelColor, muted: false)
    private static let markdown = Style(symbol: "doc.text", color: .systemBlue)
    private static let picture = Style(symbol: "photo", color: .systemPurple)
    private static let video = Style(symbol: "film", color: .systemPink)
    private static let audio = Style(symbol: "waveform", color: .systemPink)
    private static let pdf = Style(symbol: "doc.richtext", color: .systemRed)
    private static let archive = Style(symbol: "doc.zipper", color: .systemBrown)
    private static let shell = Style(symbol: "terminal", color: .systemGreen)
    private static let config = Style(symbol: "gearshape", color: .systemGray)
    private static let markup = Style(symbol: "chevron.left.forwardslash.chevron.right", color: .systemOrange)
    private static let data = Style(symbol: "curlybraces.square", color: .systemYellow)
    private static let stylesheet = Style(symbol: "paintbrush", color: .systemPurple)
    private static let tex = Style(symbol: "function", color: .systemTeal)
    private static let table = Style(symbol: "tablecells", color: .systemGreen)
    private static let font = Style(symbol: "textformat", color: .systemGray)
    private static let database = Style(symbol: "cylinder", color: .systemOrange)

    /// Files known by their whole name, which often have no extension.
    private static let byName: [String: Style] = [
        "makefile": config, "gnumakefile": config, "dockerfile": config, "containerfile": config,
        "justfile": config, "procfile": config, "gemfile": config, "brewfile": config,
        ".gitignore": config, ".gitattributes": config, ".gitmodules": config, ".editorconfig": config,
        ".env": config, ".npmrc": config, ".swift-version": config, ".swiftformat": config,
        ".zshrc": shell, ".zprofile": shell, ".bashrc": shell, ".bash_profile": shell, ".profile": shell,
        "license": text, "copying": text,
    ]

    private static let byExtension: [String: Style] = {
        var map: [String: Style] = ["swift": Style(symbol: "swift", color: .systemOrange)]
        func add(_ style: Style, _ exts: String) {
            for ext in exts.split(separator: " ") { map[String(ext)] = style }
        }
        add(code(.systemYellow), "js mjs cjs jsx")
        add(code(.systemBlue), "ts mts cts tsx")
        add(code(.systemBlue), "py pyi")
        add(code(.systemBrown), "rs")
        add(code(.systemCyan), "go")
        add(code(.systemBlue), "c h m")
        add(code(.systemIndigo), "cc cpp cxx hpp hh hxx mm")
        add(code(.systemRed), "rb java")
        add(code(.systemPurple), "kt kts php")
        add(code(.systemTeal), "lua zig")
        add(code(.systemGray), "cs scala ex exs erl hs ml el clj dart r")
        add(markdown, "md markdown mdx")
        add(text, "txt text log rtf")
        add(picture, "png jpg jpeg gif heic heif webp tif tiff bmp ico icns svg")
        add(video, "mov mp4 m4v avi mkv webm")
        add(audio, "mp3 m4a wav aif aiff flac aac ogg")
        add(pdf, "pdf")
        add(archive, "zip tar gz tgz bz2 xz 7z rar zst dmg")
        add(shell, "sh bash zsh fish command")
        add(config, "yml yaml toml ini cfg conf plist xcconfig entitlements resolved lock")
        add(markup, "html htm xhtml xml xib storyboard vue svelte")
        add(data, "json jsonc json5 geojson")
        add(stylesheet, "css scss sass less")
        add(tex, "tex sty cls ltx bib")
        add(table, "csv tsv")
        add(font, "ttf otf woff woff2")
        add(database, "sql sqlite db")
        return map
    }()

    /// Whether a file named `name` is one Vie shows in Quick Look rather than editing (a
    /// picture, a PDF, an archive), going by its extension, so the tree can gray it. Opening a
    /// file still checks its bytes, which catches what names miss (a binary plist).
    static func isBinary(name: String) -> Bool {
        let lower = name.lowercased()
        if lower == ".ds_store" { return true }
        return binaryExtensions.contains((lower as NSString).pathExtension)
    }

    /// Kinds that aren't text. SVG is a picture but is text, so it isn't here.
    private static let binaryExtensions = Set("""
        png jpg jpeg gif heic heif webp tif tiff bmp ico icns psd sketch \
        mov mp4 m4v avi mkv webm mp3 m4a wav aif aiff flac aac ogg \
        pdf zip tar gz tgz bz2 xz 7z rar zst dmg iso jar \
        ttf otf woff woff2 sqlite db \
        o a so dylib dll exe bin class pyc wasm \
        doc docx xls xlsx ppt pptx key pages numbers
        """.split(whereSeparator: \.isWhitespace).map(String.init))

    /// Every symbol the table uses, for a test that they all exist on this macOS.
    static var allSymbols: Set<String> {
        Set(byExtension.values.map(\.symbol) + byName.values.map(\.symbol) + [plain.symbol, "folder"])
    }
}
