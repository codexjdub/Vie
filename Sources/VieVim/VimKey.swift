/// One key press as the Vim engine sees it. Printable keys are their character; control keys
/// are control characters (⌃R is U+0012, ⌃H is U+0008, Esc is U+001B, Enter is "\r");
/// Backspace (the Mac delete key) is DEL, U+007F; arrows and friends use AppKit's function-key
/// code points (U+F700…).
public struct VimKey: Hashable, Sendable, CustomStringConvertible {
    public let character: Character

    public init(_ character: Character) {
        self.character = character
    }

    public static let escape = VimKey("\u{1B}")
    public static let enter = VimKey("\r")
    public static let newline = VimKey("\n")
    public static let tab = VimKey("\t")
    /// ⇧Tab in Insert mode (outdents a Markdown list item; otherwise it's Tab, as in Vim).
    public static let backtab = VimKey("\u{F8FE}")
    public static let backspace = VimKey("\u{7F}")
    public static let delete = VimKey("\u{F728}")
    public static let up = VimKey("\u{F700}")
    public static let down = VimKey("\u{F701}")
    public static let left = VimKey("\u{F702}")
    public static let right = VimKey("\u{F703}")
    public static let home = VimKey("\u{F729}")
    public static let end = VimKey("\u{F72B}")
    public static let pageUp = VimKey("\u{F72C}")
    public static let pageDown = VimKey("\u{F72D}")
    /// ⌥J and ⌥K, which move lines (LazyVim's mapping); `<M-j>` and `<M-k>` in notation.
    public static let altJ = VimKey("\u{F8F1}")
    public static let altK = VimKey("\u{F8F2}")

    /// The control character for ⌃`c` (`c` is a letter or one of `@ [ \ ] ^ _`).
    public static func ctrl(_ c: Character) -> VimKey {
        let v = c.uppercased().unicodeScalars.first!.value
        return VimKey(Character(Unicode.Scalar(v & 0x1F)!))
    }

    var scalar: UInt32 { character.unicodeScalars.first!.value }

    /// Backspace in any of its spellings: ⌃H, and DEL (what the Mac delete key sends).
    var isBackspace: Bool { character == "\u{08}" || character == "\u{7F}" }

    var isEscape: Bool { character == "\u{1B}" }
    var isEnter: Bool { character == "\r" || character == "\n" }

    /// A key that types text in Insert mode (not a control character or function key).
    var isText: Bool {
        let v = scalar
        return v >= 0x20 && v != 0x7F && !(0xF700...0xF8FF).contains(v)
    }

    var digit: Int? {
        guard let v = character.wholeNumberValue, character.isASCII else { return nil }
        return v
    }

    private static let names: [(String, VimKey)] = [
        ("esc", .escape), ("cr", .enter), ("enter", .enter), ("return", .enter), ("nl", .newline),
        ("bs", .backspace), ("tab", .tab), ("space", VimKey(" ")), ("lt", VimKey("<")), ("bar", VimKey("|")),
        ("bslash", VimKey("\\")), ("del", .delete), ("up", .up), ("down", .down), ("left", .left),
        ("right", .right), ("home", .home), ("end", .end), ("pageup", .pageUp), ("pagedown", .pageDown),
        ("m-j", .altJ), ("m-k", .altK), ("a-j", .altJ), ("a-k", .altK),
    ]

    /// Keys from Vim notation: `<Esc>`, `<CR>`, `<C-v>` and the other names above are special;
    /// anything else, including a `<` that doesn't start one of them, is literal. (Keep the
    /// names in step with KEY_NAMES in scripts/vim-oracle.py.)
    public static func parse(_ notation: String) -> [VimKey] {
        let chars = Array(notation)
        var keys: [VimKey] = []
        var i = 0
        while i < chars.count {
            if chars[i] == "<", let close = chars[(i + 1)...].firstIndex(of: ">"), close - i <= 10 {
                let name = String(chars[(i + 1)..<close]).lowercased()
                if let key = names.first(where: { $0.0 == name })?.1 {
                    keys.append(key)
                    i = close + 1
                    continue
                }
                if name.count == 3, name.hasPrefix("c-"), let c = name.last {
                    keys.append(.ctrl(c))
                    i = close + 1
                    continue
                }
            }
            keys.append(VimKey(chars[i]))
            i += 1
        }
        return keys
    }

    /// Keys stored as register text (macros), the reverse of `text(of:)`.
    static func keys(from text: String) -> [VimKey] {
        var keys: [VimKey] = []
        for c in text {
            // "\r\n" is one Character; as keys they are two.
            if c.unicodeScalars.count > 1, let first = c.unicodeScalars.first, first.value < 0x20 {
                keys.append(contentsOf: c.unicodeScalars.map { VimKey(Character($0)) })
            } else {
                keys.append(VimKey(c))
            }
        }
        return keys
    }

    static func text(of keys: [VimKey]) -> String {
        var s = ""
        for k in keys { s.unicodeScalars.append(contentsOf: k.character.unicodeScalars) }
        return s
    }

    /// Vim notation for showing the key: `<Esc>`, `^R`, `x`.
    public var description: String {
        if let name = VimKey.names.first(where: { $0.1 == self && $0.0 != "enter" && $0.0 != "return" && $0.0 != "space" && $0.0 != "lt" && $0.0 != "bar" && $0.0 != "bslash" })?.0,
           !isText {
            return "<" + (name.count <= 3 ? name.uppercased() : name.prefix(1).uppercased() + name.dropFirst()) + ">"
        }
        let v = scalar
        if v < 0x20 { return "^" + String(Character(Unicode.Scalar(v + 0x40)!)) }
        if v == 0x7F { return "<BS>" }
        return String(character)
    }
}
