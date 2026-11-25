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
