import VieText

/// A position as Vim thinks of it: 0-based line and byte column. Column == line length is
/// "on the end of the line" (Vim's NUL), where the cursor can rest only in Insert and Visual
/// mode or on an empty line.
struct Pos: Comparable, Hashable, Sendable {
    var line: Int
    var col: Int

    init(_ line: Int, _ col: Int) {
        self.line = line
        self.col = col
    }

    static func < (a: Pos, b: Pos) -> Bool { a.line != b.line ? a.line < b.line : a.col < b.col }
}

// MARK: - Characters within a line

@inline(__always) func isBlank(_ b: UInt8) -> Bool { b == 0x20 || b == 0x09 }

/// End of the user-perceived character (grapheme) starting at `col`.
func nextCharCol(_ b: [UInt8], _ col: Int) -> Int {
    guard col < b.count else { return b.count }
    if b[col] < 0x80 && (col + 1 == b.count || b[col + 1] < 0x80) { return col + 1 }
    var window = 32
    while true {
        var end = min(b.count, col + window)
        while end < b.count && isContinuation(b[end]) { end += 1 }
        let len = String(decoding: b[col..<end], as: UTF8.self).first.map { $0.utf8.count } ?? 1
        if col + len < end || end == b.count { return min(col + max(len, 1), b.count) }
        window *= 4
    }
}

/// Start of the user-perceived character (grapheme) ending at `col`.
func prevCharCol(_ b: [UInt8], _ col: Int) -> Int {
    guard col > 0 else { return 0 }
    let col = min(col, b.count)
    if b[col - 1] < 0x80 { return col - 1 }
    var window = 32
    while true {
        var start = max(0, col - window)
        while start > 0 && isContinuation(b[start]) { start -= 1 }
        let len = String(decoding: b[start..<col], as: UTF8.self).last.map { $0.utf8.count } ?? 1
        if col - len > start || start == 0 { return max(col - max(len, 1), 0) }
        window *= 4
    }
}

/// The first scalar of the character at `col` (U+0000 past the end).
func scalarAt(_ b: [UInt8], _ col: Int) -> Unicode.Scalar {
    guard col < b.count else { return "\u{0}" }
    let b0 = UInt32(b[col])
    if b0 < 0x80 { return Unicode.Scalar(b0)! }
    let len = utf8Length(b[col])
    guard col + len <= b.count else { return "\u{FFFD}" }
    var v: UInt32
    switch len {
    case 2: v = (b0 & 0x1F) << 6 | UInt32(b[col + 1] & 0x3F)
    case 3: v = (b0 & 0x0F) << 12 | UInt32(b[col + 1] & 0x3F) << 6 | UInt32(b[col + 2] & 0x3F)
    default: v = (b0 & 0x07) << 18 | UInt32(b[col + 1] & 0x3F) << 12 | UInt32(b[col + 2] & 0x3F) << 6 | UInt32(b[col + 3] & 0x3F)
    }
    return Unicode.Scalar(v) ?? "\u{FFFD}"
}

/// Whether the character at `col` is a Vim keyword character (letters, digits, `_`).
func isKeywordChar(_ b: [UInt8], _ col: Int) -> Bool { col < b.count && vimClass(scalarAt(b, col)) >= 2 }

// MARK: - Character classes

/// Vim's character class (utf_class): 0 blank, 1 punctuation, 2 word, 3 emoji, and separate
/// classes for CJK scripts so 日本語のテキスト splits into 日本語 · の · テキスト.
func vimClass(_ s: Unicode.Scalar) -> Int {
    let c = s.value
    if c < 0x100 {
        if c == 0x20 || c == 0x09 || c == 0 || c == 0xA0 { return 0 }
        if (0x30...0x39).contains(c) || (0x41...0x5A).contains(c) || (0x61...0x7A).contains(c) || c == 0x5F || c >= 0xC0 {
            return 2
        }
        return 1
    }
    if s.properties.isEmoji { return 3 }
    for r in classRanges where r.0 <= c && c <= r.1 { return r.2 }
    return 2
}

private let classRanges: [(UInt32, UInt32, Int)] = [
    (0x037E, 0x037E, 1), (0x0387, 0x0387, 1), (0x055A, 0x055F, 1), (0x0589, 0x0589, 1), (0x05BE, 0x05BE, 1),
    (0x05C0, 0x05C0, 1), (0x05C3, 0x05C3, 1), (0x05F3, 0x05F4, 1), (0x060C, 0x060C, 1), (0x061B, 0x061B, 1),
    (0x061F, 0x061F, 1), (0x066A, 0x066D, 1), (0x06D4, 0x06D4, 1), (0x0700, 0x070D, 1), (0x0964, 0x0965, 1),
    (0x0970, 0x0970, 1), (0x0DF4, 0x0DF4, 1), (0x0E4F, 0x0E4F, 1), (0x0E5A, 0x0E5B, 1), (0x0F04, 0x0F12, 1),
    (0x0F3A, 0x0F3D, 1), (0x0F85, 0x0F85, 1), (0x104A, 0x104F, 1), (0x10FB, 0x10FB, 1), (0x1361, 0x1368, 1),
    (0x166D, 0x166E, 1), (0x1680, 0x1680, 0), (0x169B, 0x169C, 1), (0x16EB, 0x16ED, 1), (0x1735, 0x1736, 1),
    (0x17D4, 0x17DC, 1), (0x1800, 0x180A, 1), (0x2000, 0x200B, 0), (0x200C, 0x2027, 1), (0x2028, 0x2029, 0),
    (0x202A, 0x202E, 1), (0x202F, 0x202F, 0), (0x2030, 0x205E, 1), (0x205F, 0x205F, 0), (0x2070, 0x207F, 0x2070),
    (0x2080, 0x2094, 0x2080), (0x2060, 0x27FF, 1), (0x2800, 0x28FF, 0x2800), (0x2900, 0x2998, 1),
    (0x29D8, 0x29DB, 1), (0x29FC, 0x29FD, 1), (0x2E00, 0x2E7F, 1), (0x3000, 0x3000, 0), (0x3001, 0x3020, 1),
    (0x3030, 0x3030, 1), (0x303D, 0x303D, 1), (0x3040, 0x309F, 0x3040), (0x30A0, 0x30FF, 0x30A0),
    (0x3300, 0x9FFF, 0x4E00), (0xAC00, 0xD7A3, 0xAC00), (0xF900, 0xFAFF, 0x4E00), (0xFD3E, 0xFD3F, 1),
    (0xFE30, 0xFE6B, 1), (0xFF00, 0xFF0F, 1), (0xFF1A, 0xFF20, 1), (0xFF3B, 0xFF40, 1), (0xFF5B, 0xFF65, 1),
    (0x1D000, 0x1D24F, 1), (0x1D400, 0x1D7FF, 1), (0x1F000, 0x1F2FF, 1), (0x1F300, 0x1F9FF, 1),
    (0x20000, 0x2A6DF, 0x4E00), (0x2A700, 0x2B73F, 0x4E00), (0x2B740, 0x2B81F, 0x4E00), (0x2F800, 0x2FA1F, 0x4E00),
]

// MARK: - Display columns

/// Screen cells for a character other than Tab: 2 for East Asian wide characters and emoji.
func cellWidth(_ s: Unicode.Scalar) -> Int {
    let c = s.value
    if c < 0x1100 { return 1 }
    switch c {
    case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xA000...0xA4CF,
         0xA960...0xA97F, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE10...0xFE19, 0xFE30...0xFE6F, 0xFF00...0xFF60,
         0xFFE0...0xFFE6, 0x1B000...0x1B2FF, 0x1F300...0x1F64F, 0x1F680...0x1F6FF, 0x1F900...0x1F9FF,
         0x1FA70...0x1FAFF, 0x20000...0x2FFFD, 0x30000...0x3FFFD:
        return 2
    default:
        return s.properties.isEmojiPresentation ? 2 : 1
    }
}

/// Cells taken by the character at `col` when it starts at display column `vcol`.
func cellsAt(_ b: [UInt8], _ col: Int, vcol: Int, tabstop: Int) -> Int {
    guard col < b.count else { return 1 }
    let c = b[col]
    if c == 0x09 { return tabstop - vcol % tabstop }
    if c < 0x80 { return 1 }
    return cellWidth(scalarAt(b, col))
}

/// Display column where the character at `col` starts.
func vcolOf(_ b: [UInt8], _ col: Int, tabstop: Int) -> Int {
    var v = 0, i = 0
    let end = min(col, b.count)
    while i < end {
        let c = b[i]
        if c == 0x09 { v += tabstop - v % tabstop; i += 1 }
        else if c < 0x80 { v += 1; i += 1 }
        else { v += cellWidth(scalarAt(b, i)); i = nextCharCol(b, i) }
    }
    return v + max(0, col - b.count)
}

/// Column of the character covering display column `want`. Past the end of the line this is
/// the last character, or the end of the line when `oneMore`.
func colForVcol(_ b: [UInt8], _ want: Int, tabstop: Int, oneMore: Bool) -> Int {
    var v = 0, i = 0
    while i < b.count {
        let w = cellsAt(b, i, vcol: v, tabstop: tabstop)
        if v + w > want { return i }
        let n = b[i] < 0x80 ? i + 1 : nextCharCol(b, i)
        if n >= b.count { return oneMore ? b.count : i }
        v += w
        i = n
    }
    return 0
}

/// Display width of a whole line (or its first `col` bytes).
func displayWidth(_ b: [UInt8], tabstop: Int) -> Int { vcolOf(b, b.count, tabstop: tabstop) }

/// Leading blanks of a line: their byte length and display width.
func indentOf(_ b: [UInt8], tabstop: Int) -> (bytes: Int, width: Int) {
    var i = 0
    while i < b.count && isBlank(b[i]) { i += 1 }
    return (i, vcolOf(b, i, tabstop: tabstop))
}

/// Whitespace that indents to `width` columns.
func indentText(width: Int, options: VimOptions) -> [UInt8] {
    guard width > 0 else { return [] }
    if options.expandtab { return [UInt8](repeating: 0x20, count: width) }
    return [UInt8](repeating: 0x09, count: width / options.tabstop) + [UInt8](repeating: 0x20, count: width % options.tabstop)
}

// MARK: - Case

enum CaseChange { case toggle, upper, lower }

/// Changes the case of every character in `bytes` (one scalar for one scalar, as Vim does).
func changeCase(_ bytes: [UInt8], _ how: CaseChange) -> [UInt8] {
    if bytes.allSatisfy({ $0 < 0x80 }) {
        return bytes.map { c in
            let isUpper = c >= 0x41 && c <= 0x5A, isLower = c >= 0x61 && c <= 0x7A
            switch how {
            case .upper: return isLower ? c - 32 : c
            case .lower: return isUpper ? c + 32 : c
            case .toggle: return isUpper ? c + 32 : isLower ? c - 32 : c
            }
        }
    }
    var out = String.UnicodeScalarView()
    for s in String(decoding: bytes, as: UTF8.self).unicodeScalars {
        let p = s.properties
        func single(_ m: String) -> Unicode.Scalar { m.unicodeScalars.count == 1 ? m.unicodeScalars.first! : s }
        switch how {
        case .upper: out.append(p.isLowercase ? single(p.uppercaseMapping) : s)
        case .lower: out.append(p.isUppercase ? single(p.lowercaseMapping) : s)
        case .toggle: out.append(p.isUppercase ? single(p.lowercaseMapping) : p.isLowercase ? single(p.uppercaseMapping) : s)
        }
    }
    return Array(String(out).utf8)
}
