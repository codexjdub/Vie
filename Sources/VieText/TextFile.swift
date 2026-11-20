import Foundation

/// Line ending style of a file. Buffers always use `\n`; the file's style is restored on save.
public enum LineEnding: String, Sendable, CaseIterable {
    case lf, crlf, cr

    public var name: String {
        switch self {
        case .lf: "LF"
        case .crlf: "CRLF"
        case .cr: "CR"
        }
    }

    var bytes: [UInt8] {
        switch self {
        case .lf: [0x0A]
        case .crlf: [0x0D, 0x0A]
        case .cr: [0x0D]
        }
    }
}

/// How a file's text is stored on disk.
public struct TextFormat: Equatable, Sendable {
    public var encoding: String.Encoding
    public var hasBOM: Bool
    public var lineEnding: LineEnding

    public init(encoding: String.Encoding = .utf8, hasBOM: Bool = false, lineEnding: LineEnding = .lf) {
        self.encoding = encoding
        self.hasBOM = hasBOM
        self.lineEnding = lineEnding
    }

    public static let utf8 = TextFormat()

    /// For example "UTF-8 · LF" or "Shift JIS · CRLF".
    public var description: String {
        var name = String.localizedName(of: encoding)
        if hasBOM && encoding == .utf8 { name += " with BOM" }
        return "\(name) · \(lineEnding.name)"
    }
}

public enum TextFileError: Error, Equatable, LocalizedError {
    /// The file has NUL bytes and isn't UTF-16 or UTF-32 with a byte order mark.
    case binary
    /// The file has a byte order mark but its contents don't decode.
    case undecodable(String.Encoding)
    /// The text contains characters the target encoding can't store.
    case unrepresentable(String.Encoding)

    public var errorDescription: String? {
        switch self {
        case .binary: "The file looks like a binary file, not text."
        case .undecodable(let e): "The file isn't valid \(String.localizedName(of: e))."
        case .unrepresentable(let e): "The text contains characters that \(String.localizedName(of: e)) can't store."
        }
    }
}

/// Text read from a file: the rope (UTF-8 with `\n` line endings) and how to write it back.
public struct DecodedText: Sendable {
    public var rope: Rope
    public var format: TextFormat
    /// True when the file mixed line ending styles; saving writes them all as `format.lineEnding`.
    public var hadMixedLineEndings: Bool
}

/// Converts between files on disk and ropes.
///
/// Reading: UTF-8 is used directly (a 100 MB ASCII file is scanned at memory speed and never
/// copied into a String). Files with a byte order mark use its encoding. Anything else is
/// detected among common legacy encodings (Shift JIS, EUC-JP, GB 18030, Big5, EUC-KR,
/// Windows-1252, Mac Roman), falling back to ISO Latin 1, which accepts any bytes.
public enum TextFile {
    public static func read(contentsOf url: URL) throws -> DecodedText {
        try decode(Data(contentsOf: url, options: .alwaysMapped))
    }

    public static func decode(_ data: Data) throws -> DecodedText {
        let boms: [([UInt8], String.Encoding)] = [
            ([0xEF, 0xBB, 0xBF], .utf8),
            ([0xFF, 0xFE, 0x00, 0x00], .utf32LittleEndian),
            ([0x00, 0x00, 0xFE, 0xFF], .utf32BigEndian),
            ([0xFF, 0xFE], .utf16LittleEndian),
            ([0xFE, 0xFF], .utf16BigEndian),
        ]
        for (bom, encoding) in boms where data.starts(with: bom) {
            let body = data.dropFirst(bom.count)
            if encoding == .utf8 {
                let result = body.withUnsafeBytes { fromUTF8($0.bindMemory(to: UInt8.self)) }
                if var result {
                    result.format.hasBOM = true
                    return result
                }
                throw TextFileError.undecodable(.utf8)
            }
            guard let string = String(data: body, encoding: encoding) else { throw TextFileError.undecodable(encoding) }
            return fromString(string, format: TextFormat(encoding: encoding, hasBOM: true))
        }

        if let result = data.withUnsafeBytes({ fromUTF8($0.bindMemory(to: UInt8.self)) }) { return result }
        if data.prefix(8192).contains(0) { throw TextFileError.binary }
        return decodeLegacy(data)
    }

    /// Returns nil if the bytes aren't valid UTF-8.
    private static func fromUTF8(_ p: UnsafeBufferPointer<UInt8>) -> DecodedText? {
        let scan = ByteScan(p)
        guard scan.isValidUTF8 else { return nil }
        if !scan.hasCR {
            return DecodedText(rope: Rope(bytes: UnsafeRawBufferPointer(p)), format: .utf8, hadMixedLineEndings: false)
        }
        let (bytes, ending, mixed) = normalizeLineEndings(p)
        return DecodedText(rope: Rope(bytes: bytes), format: TextFormat(lineEnding: ending), hadMixedLineEndings: mixed)
    }

    private static func fromString(_ string: String, format: TextFormat) -> DecodedText {
        var format = format
        let utf8 = Array(string.utf8)
        guard utf8.contains(0x0D) else { return DecodedText(rope: Rope(bytes: utf8), format: format, hadMixedLineEndings: false) }
        let (bytes, ending, mixed) = utf8.withUnsafeBufferPointer { normalizeLineEndings($0) }
        format.lineEnding = ending
        return DecodedText(rope: Rope(bytes: bytes), format: format, hadMixedLineEndings: mixed)
    }

    static let legacyEncodings: [String.Encoding] = {
        func cf(_ e: CFStringEncodings) -> String.Encoding {
            String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(e.rawValue)))
        }
        return [.shiftJIS, .japaneseEUC, cf(.GB_18030_2000), cf(.big5), cf(.EUC_KR), .windowsCP1252, .macOSRoman]
    }()

    private static func decodeLegacy(_ data: Data) -> DecodedText {
        var converted: NSString?
        var lossy: ObjCBool = false
        let raw = NSString.stringEncoding(for: data, encodingOptions: [
            .suggestedEncodingsKey: legacyEncodings.map { NSNumber(value: $0.rawValue) },
            .useOnlySuggestedEncodingsKey: true,
            .allowLossyKey: false,
        ], convertedString: &converted, usedLossyConversion: &lossy)
        if raw != 0, let string = converted as String?, !lossy.boolValue {
            return fromString(string, format: TextFormat(encoding: String.Encoding(rawValue: raw)))
        }
        let latin1 = String(decoding: data.map { UInt16($0) }, as: UTF16.self) // every byte is a Latin 1 character
        return fromString(latin1, format: TextFormat(encoding: .isoLatin1))
    }

    /// Converts CRLF and lone CR to LF. Returns the most common style and whether styles mixed.
    static func normalizeLineEndings(_ p: UnsafeBufferPointer<UInt8>) -> ([UInt8], LineEnding, Bool) {
        guard let base = p.baseAddress else { return ([], .lf, false) }
        var out: [UInt8] = []
        out.reserveCapacity(p.count)
        var crlf = 0, cr = 0
        var i = 0
        while i < p.count {
            guard let hit = memchr(base + i, 0x0D, p.count - i) else {
                out.append(contentsOf: UnsafeBufferPointer(rebasing: p[i...]))
                break
            }
            let j = UnsafeRawPointer(base).distance(to: UnsafeRawPointer(hit))
            out.append(contentsOf: UnsafeBufferPointer(rebasing: p[i..<j]))
            out.append(0x0A)
            if j + 1 < p.count && p[j + 1] == 0x0A {
                crlf += 1
                i = j + 2
            } else {
                cr += 1
                i = j + 1
            }
        }
        let lf = out.withUnsafeBufferPointer { Summary.of($0).newlines } - crlf - cr
        let ending: LineEnding = crlf >= lf && crlf >= cr ? .crlf : cr > lf ? .cr : .lf
        let styles = [lf, crlf, cr].filter { $0 > 0 }.count
        return (out, ending, styles > 1)
    }

    // MARK: - Writing

    /// The bytes to write for `rope` in `format`.
    public static func encode(_ rope: Rope, as format: TextFormat) throws -> Data {
        var utf8 = Data()
        utf8.reserveCapacity(rope.byteCount + (format.lineEnding == .crlf ? rope.lineCount : 0) + 3)
        if format.encoding == .utf8 && format.hasBOM { utf8.append(contentsOf: [0xEF, 0xBB, 0xBF]) }
        rope.forEachChunk { chunk in
            guard format.lineEnding != .lf, let base = chunk.baseAddress else {
                utf8.append(chunk)
                return
            }
            var i = 0
            while i < chunk.count {
                guard let hit = memchr(base + i, 0x0A, chunk.count - i) else {
                    utf8.append(UnsafeBufferPointer(rebasing: chunk[i...]))
                    break
                }
                let j = UnsafeRawPointer(base).distance(to: UnsafeRawPointer(hit))
                utf8.append(UnsafeBufferPointer(rebasing: chunk[i..<j]))
                utf8.append(contentsOf: format.lineEnding.bytes)
                i = j + 1
            }
        }
        if format.encoding == .utf8 { return utf8 }

        let string = String(decoding: utf8, as: UTF8.self)
        guard let encoded = string.data(using: format.encoding, allowLossyConversion: false) else {
            throw TextFileError.unrepresentable(format.encoding)
        }
        guard format.hasBOM else { return encoded }
        let bom: [UInt8] = switch format.encoding {
        case .utf16LittleEndian: [0xFF, 0xFE]
        case .utf16BigEndian: [0xFE, 0xFF]
        case .utf32LittleEndian: [0xFF, 0xFE, 0x00, 0x00]
        case .utf32BigEndian: [0x00, 0x00, 0xFE, 0xFF]
        default: []
        }
        return Data(bom) + encoded
    }
}

/// One pass over a file's bytes: is it valid UTF-8, and does it contain carriage returns?
/// ASCII runs are checked 32 bytes at a time.
struct ByteScan {
    var isValidUTF8 = true
    var hasCR = false

    init(_ p: UnsafeBufferPointer<UInt8>) {
        guard let base = p.baseAddress else { return }
        let raw = UnsafeRawPointer(base)
        let n = p.count
        let high: UInt64 = 0x8080_8080_8080_8080, ones: UInt64 = 0x0101_0101_0101_0101
        let crs: UInt64 = 0x0D0D_0D0D_0D0D_0D0D
        var crBits: UInt64 = 0
        @inline(__always) func crIn(_ w: UInt64) -> UInt64 {
            let x = w ^ crs
            return (x &- ones) & ~x & high
        }
        var i = 0
        while i < n {
            if i + 32 <= n {
                let a = raw.loadUnaligned(fromByteOffset: i, as: UInt64.self)
                let b = raw.loadUnaligned(fromByteOffset: i + 8, as: UInt64.self)
                let c = raw.loadUnaligned(fromByteOffset: i + 16, as: UInt64.self)
                let d = raw.loadUnaligned(fromByteOffset: i + 24, as: UInt64.self)
                if (a | b | c | d) & high == 0 {
                    crBits |= crIn(a) | crIn(b) | crIn(c) | crIn(d)
                    i += 32
                    continue
                }
            }
            let b0 = p[i]
            if b0 < 0x80 {
                if b0 == 0x0D { hasCR = true }
                i += 1
                continue
            }
            guard let len = ByteScan.sequenceLength(p, i) else {
                isValidUTF8 = false
                return
            }
            i += len
        }
        if crBits != 0 { hasCR = true }
    }

    /// Length of the valid multi-byte UTF-8 sequence at `i`, or nil (Unicode table 3-7).
    static func sequenceLength(_ p: UnsafeBufferPointer<UInt8>, _ i: Int) -> Int? {
        let b0 = p[i]
        let n = p.count - i
        @inline(__always) func cont(_ k: Int, _ lo: UInt8 = 0x80, _ hi: UInt8 = 0xBF) -> Bool {
            k < n && p[i + k] >= lo && p[i + k] <= hi
        }
        switch b0 {
        case 0xC2...0xDF: return cont(1) ? 2 : nil
        case 0xE0: return cont(1, 0xA0) && cont(2) ? 3 : nil
        case 0xE1...0xEC, 0xEE...0xEF: return cont(1) && cont(2) ? 3 : nil
        case 0xED: return cont(1, 0x80, 0x9F) && cont(2) ? 3 : nil
        case 0xF0: return cont(1, 0x90) && cont(2) && cont(3) ? 4 : nil
        case 0xF1...0xF3: return cont(1) && cont(2) && cont(3) ? 4 : nil
        case 0xF4: return cont(1, 0x80, 0x8F) && cont(2) && cont(3) ? 4 : nil
        default: return nil
        }
    }
}
