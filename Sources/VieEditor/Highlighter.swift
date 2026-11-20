import AppKit
import CoreText

enum Theme {
    static let background = CGColor(srgbRed: 0.110, green: 0.118, blue: 0.137, alpha: 1)
    static let gutter = CGColor(srgbRed: 0.094, green: 0.102, blue: 0.118, alpha: 1)
    static let currentLine = CGColor(srgbRed: 0.145, green: 0.157, blue: 0.184, alpha: 1)
    static let text = CGColor(srgbRed: 0.851, green: 0.859, blue: 0.878, alpha: 1)
    static let lineNumber = CGColor(srgbRed: 0.400, green: 0.431, blue: 0.482, alpha: 1)
    static let keyword = CGColor(srgbRed: 0.780, green: 0.471, blue: 0.867, alpha: 1)
    static let string = CGColor(srgbRed: 0.596, green: 0.765, blue: 0.475, alpha: 1)
    static let number = CGColor(srgbRed: 0.820, green: 0.604, blue: 0.400, alpha: 1)
    static let comment = CGColor(srgbRed: 0.451, green: 0.494, blue: 0.557, alpha: 1)
    static let cursor = CGColor(srgbRed: 0.380, green: 0.686, blue: 0.937, alpha: 1)
    static let selection = CGColor(srgbRed: 0.243, green: 0.380, blue: 0.592, alpha: 0.75)
    static let inactiveSelection = CGColor(srgbRed: 0.333, green: 0.353, blue: 0.396, alpha: 0.6)
    static let scrollbar = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.18)
    static let searchMatch = CGColor(srgbRed: 0.851, green: 0.651, blue: 0.251, alpha: 0.30)
    static let currentMatch = CGColor(srgbRed: 0.937, green: 0.659, blue: 0.239, alpha: 0.65)
    static let statusBorder = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.35)
    static let error = CGColor(srgbRed: 0.941, green: 0.443, blue: 0.443, alpha: 1)
    static let hudBackground = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.72)
    static let hudText = CGColor(srgbRed: 0.6, green: 0.95, blue: 0.7, alpha: 1)
}

/// A tiny per-line lexer standing in for tree-sitter until VieSyntax lands (M4), so line
/// layout pays for several colored runs per line as it will in the real editor.
enum Highlighter {
    static let fontKey = NSAttributedString.Key(kCTFontAttributeName as String)
    static let colorKey = NSAttributedString.Key(kCTForegroundColorAttributeName as String)
    static let paragraphKey = NSAttributedString.Key(kCTParagraphStyleAttributeName as String)
    static let underlineKey = NSAttributedString.Key(kCTUnderlineStyleAttributeName as String)

    private static let keywords: Set<String> = [
        "func", "let", "var", "if", "else", "return", "for", "in", "while", "struct", "class",
        "enum", "case", "switch", "import", "true", "false", "nil", "self", "guard", "where",
    ]

    static func paragraphStyle(tabWidth: CGFloat) -> CTParagraphStyle {
        var interval = tabWidth
        var stops: CFArray = NSArray()
        return withUnsafePointer(to: &interval) { ip in
            withUnsafePointer(to: &stops) { sp in
                let settings = [
                    CTParagraphStyleSetting(spec: .tabStops, valueSize: MemoryLayout<CFArray>.size, value: sp),
                    CTParagraphStyleSetting(spec: .defaultTabInterval, valueSize: MemoryLayout<CGFloat>.size, value: ip),
                ]
                return CTParagraphStyleCreate(settings, settings.count)
            }
        }
    }

    static func plain(_ s: String, font: CTFont, color: CGColor) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [fontKey: font, colorKey: color])
    }

    static func highlight(_ s: String, font: CTFont, paragraph: CTParagraphStyle) -> NSMutableAttributedString {
        let attr = NSMutableAttributedString(string: s, attributes: [fontKey: font, colorKey: Theme.text, paragraphKey: paragraph])
        let u = Array(s.utf16)
        let n = u.count
        func paint(_ a: Int, _ b: Int, _ c: CGColor) {
            attr.addAttribute(colorKey, value: c, range: NSRange(location: a, length: b - a))
        }
        var i = 0
        while i < n {
            let c = u[i]
            if c == 0x2F, i + 1 < n, u[i + 1] == 0x2F || u[i + 1] == 0x2A { // "//" or "/*"
                paint(i, n, Theme.comment)
                break
            }
            if c == 0x22 { // "
                var j = i + 1
                while j < n && u[j] != 0x22 { j += 1 }
                j = min(j + 1, n)
                paint(i, j, Theme.string)
                i = j
                continue
            }
            if isDigit(c) {
                var j = i + 1
                while j < n && (isDigit(u[j]) || u[j] == 0x2E) { j += 1 }
                paint(i, j, Theme.number)
                i = j
                continue
            }
            if isIdentStart(c) {
                var j = i + 1
                while j < n && (isIdentStart(u[j]) || isDigit(u[j])) { j += 1 }
                if j - i <= 6, keywords.contains(String(decoding: u[i..<j], as: UTF16.self)) {
                    paint(i, j, Theme.keyword)
                }
                i = j
                continue
            }
            i += 1
        }
        return attr
    }

    @inline(__always) private static func isDigit(_ c: UInt16) -> Bool { c >= 0x30 && c <= 0x39 }

    @inline(__always) private static func isIdentStart(_ c: UInt16) -> Bool {
        (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F
    }
}
