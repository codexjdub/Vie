/// How register text goes back into the buffer.
public enum RegisterKind: Equatable, Sendable {
    case charwise
    /// Whole lines; the text ends with "\n".
    case linewise
    /// A rectangle `width` display columns wide; the text is its lines joined with "\n".
    case blockwise(width: Int)
}

public struct Register: Equatable, Sendable {
    public var text: String
    public var kind: RegisterKind

    public init(text: String, kind: RegisterKind) {
        self.text = text
        self.kind = kind
    }

    var lines: [Substring] {
        var parts = text.split(separator: "\n", omittingEmptySubsequences: false)
        if kind == .linewise, parts.last == "" { parts.removeLast() }
        return parts
    }

    /// `other` appended, as `"Ayw` does.
    func appending(_ other: Register) -> Register {
        switch (kind, other.kind) {
        case (.charwise, .charwise):
            return Register(text: text + other.text, kind: .charwise)
        case (.linewise, _), (_, .linewise):
            let a = text.hasSuffix("\n") ? text : text + "\n"
            let b = other.text.hasSuffix("\n") ? other.text : other.text + "\n"
            return Register(text: a + b, kind: .linewise)
        default:
            let width = max(blockWidth, other.blockWidth)
            return Register(text: text + "\n" + other.text, kind: .blockwise(width: width))
        }
    }

    private var blockWidth: Int {
        if case .blockwise(let w) = kind { return w }
        return 0
    }
}

/// Vim's registers: unnamed, `0` (last yank), `1`–`9` (deletes, shifting), `-` (small
/// delete), `a`–`z` (`A`–`Z` append), `_` (black hole). The clipboard (`+`, `*`) and the
/// read-only ones (`.`, `:`, `/`) are handled by the engine.
struct Registers {
    private var store: [Character: Register] = [:]
    /// The register `""` refers to: the one written last.
    private(set) var unnamed: Character = "0"

    static func isValid(_ c: Character) -> Bool {
        c.isASCII && (c.isLetter || c.isNumber) || "\"-_+*.:/".contains(c)
    }

    static func isWritable(_ c: Character) -> Bool {
        c.isASCII && (c.isLetter || c.isNumber) || "\"-_+*".contains(c)
    }

    func get(_ name: Character) -> Register? {
        let name = name == "\"" ? unnamed : Character(name.lowercased())
        return store[name]
    }

    /// Stores text in a named register (appending for `A`–`Z`) and makes `""` point at it.
    mutating func set(_ name: Character, _ r: Register) {
        if name == "_" { return }
        if name.isUppercase, name.isASCII {
            let lower = Character(name.lowercased())
            store[lower] = store[lower].map { $0.appending(r) } ?? r
            unnamed = lower
        } else {
            store[name] = r
            unnamed = name
        }
    }

    mutating func restoreUnnamed(_ name: Character) { unnamed = name }

    mutating func clear(_ name: Character) { store[name] = nil }

    /// Records a yank: into `name` if given, else into `0`.
    mutating func yank(_ r: Register, into name: Character?) {
        guard let name, name != "\"" else { return set("0", r) }
        set(name, r)
    }

    /// Records a delete or change, as op_delete does: the named register if given; `1` (after
    /// shifting `1`–`8` down) for line-wise or multi-line deletes and the motions that always
    /// use it; else `-` when no register was named.
    mutating func delete(_ r: Register, into name: Character?, multiLine: Bool, useRegOne: Bool) {
        if name == "_" { return }
        let named = name.flatMap { $0 == "\"" ? nil : $0 }
        if let named { set(named, r) }
        if r.kind == .linewise || multiLine || useRegOne {
            for i in stride(from: 9, to: 1, by: -1) {
                store[Character(String(i))] = store[Character(String(i - 1))]
            }
            store["1"] = r
            unnamed = "1"
        }
        if named == nil && r.kind != .linewise && !multiLine {
            store["-"] = r
            unnamed = "-"
        }
    }
}
