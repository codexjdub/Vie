import Foundation
import Testing
@testable import VieText

@Suite struct TextFileTests {
    private func text(_ r: Rope) -> String { r.string(in: 0..<r.byteCount) }

    @Test func plainUTF8() throws {
        let d = try TextFile.decode(Data("héllo\nworld 🚀\n".utf8))
        #expect(text(d.rope) == "héllo\nworld 🚀\n")
        #expect(d.format == .utf8)
        #expect(try TextFile.encode(d.rope, as: d.format) == Data("héllo\nworld 🚀\n".utf8))
    }

    @Test func emptyFile() throws {
        let d = try TextFile.decode(Data())
        #expect(d.rope.isEmpty && d.format == .utf8)
    }

    @Test func utf8WithBOM() throws {
        let data = Data([0xEF, 0xBB, 0xBF] + Array("bom\r\nhere".utf8))
        let d = try TextFile.decode(data)
        #expect(text(d.rope) == "bom\nhere")
        #expect(d.format == TextFormat(encoding: .utf8, hasBOM: true, lineEnding: .crlf))
        #expect(try TextFile.encode(d.rope, as: d.format) == data)
    }

    @Test(arguments: [LineEnding.crlf, .cr])
    func lineEndingsRoundTrip(ending: LineEnding) throws {
        let sep = ending == .crlf ? "\r\n" : "\r"
        let original = ["one", "two", "", "four"].joined(separator: sep) + sep
        let d = try TextFile.decode(Data(original.utf8))
        #expect(text(d.rope) == "one\ntwo\n\nfour\n")
        #expect(d.format.lineEnding == ending)
        #expect(!d.hadMixedLineEndings)
        #expect(try TextFile.encode(d.rope, as: d.format) == Data(original.utf8))
    }

    @Test func mixedLineEndingsUseTheMostCommon() throws {
        let d = try TextFile.decode(Data("a\r\nb\r\nc\nd\r".utf8))
        #expect(text(d.rope) == "a\nb\nc\nd\n")
        #expect(d.format.lineEnding == .crlf)
        #expect(d.hadMixedLineEndings)
    }

    @Test func longASCIIRunsWithCarriageReturns() throws {
        // The CR sits past the 32-byte fast path's first blocks.
        let body = String(repeating: "x", count: 100) + "\r\n" + String(repeating: "y", count: 100)
        let d = try TextFile.decode(Data(body.utf8))
        #expect(d.format.lineEnding == .crlf)
        #expect(d.rope.lineCount == 2)
    }

    @Test(arguments: [String.Encoding.utf16LittleEndian, .utf16BigEndian, .utf32LittleEndian])
    func unicodeWithBOM(encoding: String.Encoding) throws {
        let format = TextFormat(encoding: encoding, hasBOM: true, lineEnding: .crlf)
        let data = try TextFile.encode(Rope("日本語\nテキスト 🚀\n"), as: format)
        let d = try TextFile.decode(data)
        #expect(text(d.rope) == "日本語\nテキスト 🚀\n")
        #expect(d.format == format)
        #expect(try TextFile.encode(d.rope, as: d.format) == data)
    }

    @Test func shiftJIS() throws {
        let original = "これは日本語のテキストです。\r\n二行目もあります。\r\n"
        let data = try #require(original.data(using: .shiftJIS))
        let d = try TextFile.decode(data)
        #expect(d.format.encoding == .shiftJIS)
        #expect(d.format.lineEnding == .crlf)
        #expect(text(d.rope) == "これは日本語のテキストです。\n二行目もあります。\n")
        #expect(try TextFile.encode(d.rope, as: d.format) == data)
    }

    @Test func latin1Fallback() throws {
        let data = Data([0x63, 0x61, 0x66, 0xE9, 0x0A]) // "café\n" in Latin 1 / Windows-1252
        let d = try TextFile.decode(data)
        #expect(text(d.rope) == "café\n")
        #expect(d.format.encoding != .utf8)
        #expect(try TextFile.encode(d.rope, as: d.format) == data)
    }

    @Test func invalidUTF8IsNotUTF8() throws {
        #expect(Array("ok 日本".utf8).withUnsafeBufferPointer { ByteScan($0) }.isValidUTF8)
        for bad: [UInt8] in [[0xC0, 0x80], [0xED, 0xA0, 0x80], [0xF4, 0x90, 0x80, 0x80], [0xE6, 0x97], [0x80]] {
            let scan = bad.withUnsafeBufferPointer { ByteScan($0) }
            #expect(!scan.isValidUTF8, "\(bad)")
        }
    }

    @Test func binaryFilesAreRejected() {
        #expect(throws: TextFileError.binary) {
            try TextFile.decode(Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0xFF]))
        }
    }

    /// The quick check agrees with `decode`: NUL bytes make a file binary unless it has a byte
    /// order mark or is UTF-8. It reads only the first 8 KB, and a character cut off at the end
    /// of them doesn't count as invalid UTF-8.
    @Test func looksBinary() throws {
        func decodeRefuses(_ d: Data) -> Bool {
            do { _ = try TextFile.decode(d); return false } catch { return error as? TextFileError == .binary }
        }
        let samples: [(Data, Bool)] = [
            (Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0xFF]), true), // PNG
            (Data([0xE6, 0x97, 0x00]), true), // a cut character, then NUL: not UTF-8
            (Data("plain\n".utf8), false),
            (Data(), false),
            (Data("a\0b\0".utf8), false), // UTF-8, NULs and all
            (Data([0xFF, 0xFE, 0x61, 0x00]), false), // UTF-16 with its mark
            (Data([0xE9, 0x00]), true), // Latin 1 with a NUL
        ]
        for (data, binary) in samples {
            #expect(TextFile.looksBinary(data, isWhole: true) == binary, "\(Array(data))")
            #expect(decodeRefuses(data) == binary, "\(Array(data))")
        }

        var cut = Data(repeating: 0x61, count: TextFile.binaryWindow - 2) // "日" cut by the window
        cut[0] = 0
        cut += Data("日本".utf8)
        #expect(!TextFile.looksBinary(cut, isWhole: false) && !decodeRefuses(cut))

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vie-binary-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let big = dir.appendingPathComponent("big.bin")
        try (Data([0x00, 0xFF]) + Data(repeating: 0x61, count: 100_000)).write(to: big)
        #expect(TextFile.looksBinary(at: big))
        let text = dir.appendingPathComponent("text.txt")
        try Data("text\n".utf8).write(to: text)
        #expect(!TextFile.looksBinary(at: text) && !TextFile.looksBinary(at: dir) && !TextFile.looksBinary(at: dir.appendingPathComponent("none")))
    }

    @Test func unrepresentableCharacters() {
        #expect(throws: TextFileError.unrepresentable(.shiftJIS)) {
            try TextFile.encode(Rope("emoji 🚀"), as: TextFormat(encoding: .shiftJIS))
        }
    }

    @Test func readsMappedFiles() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vie-test-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("from disk\r\n".utf8).write(to: url)
        let d = try TextFile.read(contentsOf: url)
        #expect(text(d.rope) == "from disk\n" && d.format.lineEnding == .crlf)
    }

    /// Reopen with Encoding: the bytes read as the encoding asked for, not the one guessed.
    @Test func decodesAsAChosenEncoding() throws {
        let sjis = Data([0x82, 0xA0, 0x0D, 0x0A])  // あ, CRLF
        let d = try TextFile.decode(sjis, as: .shiftJIS)
        #expect(text(d.rope) == "あ\n" && d.format == TextFormat(encoding: .shiftJIS, lineEnding: .crlf))
        // The same bytes as Latin 1 are two characters.
        #expect(try text(TextFile.decode(sjis, as: .isoLatin1).rope) == "\u{82}\u{A0}\n")
        #expect(throws: TextFileError.undecodable(.utf8)) { try TextFile.decode(sjis, as: .utf8) }
        // A byte order mark is skipped and kept.
        let bom = try TextFile.decode(Data([0xEF, 0xBB, 0xBF, 0x61]), as: .utf8)
        #expect(text(bom.rope) == "a" && bom.format.hasBOM)
        let utf16 = try TextFile.decode(Data([0x61, 0x00]), as: .utf16LittleEndian)
        #expect(text(utf16.rope) == "a" && !utf16.format.hasBOM)
    }

    @Test func formatNames() {
        #expect(TextFormat.utf8.description == "UTF-8 · LF")
        #expect(TextFormat(encoding: .utf8, hasBOM: true, lineEnding: .crlf).description == "UTF-8 with BOM · CRLF")
        #expect(TextFormat(encoding: .shiftJIS, lineEnding: .cr).description == "Shift JIS · CR")
        #expect(TextFormat(encoding: .utf32LittleEndian, hasBOM: true).encodingName == String.localizedName(of: .utf32LittleEndian))
        #expect(TextFormat(encoding: .isoLatin1).vimEncodingName == "latin1")
        #expect(LineEnding.allCases.map(\.vimName) == ["unix", "dos", "mac"])
        #expect(LineEnding(vimName: "dos") == .crlf && LineEnding(vimName: "windows") == nil)
        #expect(TextEncoding.named("utf8")?.encoding == .utf8 && TextEncoding.named("utf8")?.hasBOM == false)
        #expect(TextEncoding.named("Shift_JIS")?.encoding == .shiftJIS)
        #expect(TextEncoding.named("iso-8859-1")?.encoding == .isoLatin1)
        #expect(TextEncoding.named("utf-16")?.encoding == .utf16BigEndian)
        #expect(TextEncoding.named("klingon") == nil)
    }
}
