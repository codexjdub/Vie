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
        #expect(FileIcon.style(forName: "app.ts", isDirectory: false).color == .systemBlue)
        #expect(FileIcon.style(forName: "main.swift", isDirectory: false).color == .systemOrange)
    }
}
