/// What the Tab key inserts: a tab character or a number of spaces.
public enum Indentation: Equatable, Sendable {
    case tabs
    case spaces(Int)

    public var text: String {
        switch self {
        case .tabs: "\t"
        case .spaces(let n): String(repeating: " ", count: n)
        }
    }

    /// Guesses a file's indentation from its first lines: tabs if more lines start with a tab
    /// than with spaces, otherwise the most common change in leading spaces between lines.
    /// Returns nil when the sample has no indented lines.
    public static func detect(in rope: Rope, sampleLines: Int = 2000) -> Indentation? {
        let end = rope.offset(ofLine: sampleLines)
        let text = rope.bytes(in: 0..<min(end, 256 * 1024))
        var tabLines = 0, spaceLines = 0, previous = 0
        var deltas: [Int: Int] = [:]
        var lineStart = true, spaces = 0, inLeading = false
        for b in text {
            if lineStart {
                lineStart = false
                inLeading = true
                spaces = 0
                if b == 0x09 { tabLines += 1; inLeading = false; continue }
            }
            if b == 0x0A {
                lineStart = true
                inLeading = false
                continue
            }
            guard inLeading else { continue }
            if b == 0x20 {
                spaces += 1
                continue
            }
            inLeading = false
            if spaces > 0 { spaceLines += 1 }
            let delta = abs(spaces - previous)
            if delta > 1 && delta <= 8 { deltas[delta, default: 0] += 1 }
            previous = spaces
        }
        if tabLines == 0 && spaceLines == 0 { return nil }
        if tabLines > spaceLines { return .tabs }
        let width = deltas.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }?.key ?? 4
        return .spaces(width)
    }
}
