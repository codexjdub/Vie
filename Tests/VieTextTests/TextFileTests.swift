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
}
