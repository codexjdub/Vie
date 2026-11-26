import AppKit
import Testing
@testable import Vie

/// The icons beside names in the tree and ⌘P: a symbol for each kind of file, in its color.
@MainActor
@Suite struct FileIconTests {
    @Test func everySymbolExists() {
        for symbol in FileIcon.allSymbols {
            #expect(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil, "\(symbol)")
        }
    }

    @Test func kindsByNameAndExtension() {
        func symbol(_ name: String, folder: Bool = false) -> String {
            FileIcon.style(forName: name, isDirectory: folder).symbol
        }
        #expect(symbol("main.swift") == "swift")
        #expect(symbol("README.MD") == "doc.text")
        #expect(symbol("photo.JPEG") == "photo")
        #expect(symbol("Makefile") == "gearshape" && symbol(".gitignore") == "gearshape")
        #expect(symbol("build.sh") == "terminal" && symbol(".zshrc") == "terminal")
        #expect(symbol("archive.tar.gz") == "doc.zipper")
        #expect(symbol("notes") == "doc" && symbol(".hidden") == "doc" && symbol("odd.xyz") == "doc")
        #expect(symbol("Sources", folder: true) == "folder" && symbol("photos.png", folder: true) == "folder")
        #expect(FileIcon.style(forName: "app.ts", isDirectory: false).tint == .systemBlue)
        #expect(FileIcon.style(forName: "main.swift", isDirectory: false).tint == .systemOrange)
    }

    /// Files Vie shows in Quick Look rather than editing, known by their extension.
    @Test func binaryKindsByExtension() {
        for name in ["logo.PNG", "paper.pdf", "src.tar.gz", "font.woff2", ".DS_Store", "libz.dylib"] {
            #expect(FileIcon.isBinary(name: name), "\(name)")
        }
        for name in ["icon.svg", "main.swift", "notes.txt", "Info.plist", "Makefile", ".png"] {
            #expect(!FileIcon.isBinary(name: name), "\(name)")
        }
    }

    /// The tree grays names: faint for what git ignores, a medium gray for files Vie doesn't
    /// edit, and never a folder for its name.
    @Test func treeGraysIgnoredAndNonTextNames() {
        func color(_ name: String, folder: Bool = false, ignored: Bool = false) -> NSColor {
            FileTreeController.nameColor(name, isDirectory: folder, isIgnored: ignored)
        }
        #expect(color("main.swift") == .labelColor)
        #expect(color("logo.png") == .secondaryLabelColor)
        #expect(color("logo.png", ignored: true) == .tertiaryLabelColor)
        #expect(color("main.swift", ignored: true) == .tertiaryLabelColor)
        #expect(color("photos.zip", folder: true) == .labelColor)
    }

    /// Each kind's color is drawn softened, part of the way to gray, in light and dark mode;
    /// folders keep the accent color.
    @Test func colorsAreSoftened() throws {
        func rgb(_ color: NSColor, _ name: NSAppearance.Name) throws -> [CGFloat] {
            var out: [CGFloat] = []
            try #require(NSAppearance(named: name)).performAsCurrentDrawingAppearance {
                if let c = color.usingColorSpace(.sRGB) { out = [c.redComponent, c.greenComponent, c.blueComponent] }
            }
            return out
        }
        let swift = FileIcon.style(forName: "main.swift", isDirectory: false)
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let soft = try rgb(swift.color, name), orange = try rgb(.systemOrange, name), gray = try rgb(.systemGray, name)
            #expect(soft.count == 3 && soft != orange)
            for i in 0..<3 { #expect(soft[i] >= min(orange[i], gray[i]) - 0.01 && soft[i] <= max(orange[i], gray[i]) + 0.01) }
        }
        #expect(FileIcon.style(forName: "src", isDirectory: true).color == .controlAccentColor)
    }
}
