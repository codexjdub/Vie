import AppKit
import CoreText
import Foundation
import Testing
import VieText
@testable import VieEditor

/// Font families: the bundled ones and their faces, falling back to SF Mono, ligatures, and
/// switching family in a view. The bundled fonts come from Vendor/fonts (`make fonts`),
/// registered for this process the way the app registers them for itself.
@MainActor
@Suite struct EditorFontTests {
    static let bundledFontsRegistered: Bool = {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Vendor/fonts")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for url in files where url.pathExtension == "ttf" { CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil) }
        return EditorFont.bundled.allSatisfy(EditorFont.isAvailable)
    }()

    private func family(_ font: CTFont) -> String { CTFontCopyFamilyName(font) as String }

    private func glyphs(_ text: String, _ font: CTFont) -> [CGGlyph] {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
        ]))
        return (CTLineGetGlyphRuns(line) as! [CTRun]).flatMap { run in
            var g = [CGGlyph](repeating: 0, count: CTRunGetGlyphCount(run))
            CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &g)
            return g
        }
    }

    @Test func bundledFamiliesHaveRegularBoldAndItalic() throws {
        try #require(Self.bundledFontsRegistered)
        for name in EditorFont.bundled {
            let faces = EditorFont(name: name, size: 14).faces()
            for face in [faces.regular, faces.bold, faces.italic] { #expect(family(face) == name) }
            let traits = CTFontGetSymbolicTraits(faces.regular)
            #expect(traits.contains(.traitMonoSpace) && !traits.contains(.traitBold) && !traits.contains(.traitItalic))
            #expect(CTFontGetSymbolicTraits(faces.bold).contains(.traitBold))
            #expect(CTFontGetSymbolicTraits(faces.italic).contains(.traitItalic))
            #expect(CTFontGetSize(faces.regular) == 14)
        }
    }

    @Test func aMissingFamilyFallsBackToSFMono() {
        let system = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular) as CTFont
        #expect(family(EditorFont(name: "No Such Font 4096").faces().regular) == family(system))
        #expect(family(EditorFont().faces().regular) == family(system))
        #expect(EditorFont.displayName(nil) == "SF Mono" && EditorFont.displayName("Terminus (TTF)") == "Terminus TTF")
    }

    @Test func ligaturesAreOffUnlessTurnedOn() throws {
        try #require(Self.bundledFontsRegistered)
        let text = "a != b -> c"
        let off = EditorFont(name: "JetBrains Mono").faces().regular
        let on = EditorFont(name: "JetBrains Mono", ligatures: true).faces().regular
        // Off: each character is its own glyph from the character map.
        var chars = Array(text.utf16), mapped = [CGGlyph](repeating: 0, count: chars.count)
        CTFontGetGlyphsForCharacters(off, &chars, &mapped, chars.count)
        #expect(glyphs(text, off) == mapped)
        #expect(glyphs(text, on) != mapped)
        // Bold and italic follow the setting too.
        let bold = EditorFont(name: "JetBrains Mono").faces().bold
        var boldMapped = [CGGlyph](repeating: 0, count: chars.count)
        CTFontGetGlyphsForCharacters(bold, &chars, &boldMapped, chars.count)
        #expect(glyphs(text, bold) == boldMapped)
    }

    @Test func switchingFamilyKeepsThePlace() throws {
        try #require(Self.bundledFontsRegistered)
        let text = (0..<500).map { "line \($0)\tend" }.joined(separator: "\n")
        let v = EditorView(frame: NSRect(x: 0, y: 0, width: 500, height: 300), buffer: Buffer(rope: Rope(text)))
        v.scroll(toLine: 200)
        let width = v.charWidth
        v.editorFont.name = "JetBrains Mono"
        #expect(family(v.font) == "JetBrains Mono" && family(v.boldFont) == "JetBrains Mono")
        #expect(v.charWidth != width)
        #expect(v.top.line == 200)
        // Tab stops follow the new character width.
        let line = v.rope.offset(ofLine: 3)
        #expect(abs(v.x(of: line + "line 3\t".utf8.count) - v.charWidth * 8) < 1)
        v.editorFont = EditorFont(name: "Terminus (TTF)", size: 14)
        #expect(family(v.font) == "Terminus (TTF)" && v.fontSize == 14 && v.top.line == 200)
    }

    @Test func installedFamiliesAreMonospacedAndExcludeTheBundledOnes() {
        let families = EditorFont.installedMonospacedFamilies()
        #expect(families.contains("Menlo"))
        #expect(!families.contains { $0.hasPrefix(".") || $0 == "SF Mono" || EditorFont.bundled.contains($0) })
    }
}
