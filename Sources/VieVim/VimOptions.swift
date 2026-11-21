/// The Vim options Vie supports, with Vim's defaults except where noted. `:set` changes them.
/// (Keep the defaults in step with SETTINGS in scripts/vim-oracle.py.)
public struct VimOptions: Equatable, Sendable {
    public var tabstop = 4
    public var shiftwidth = 4
    public var expandtab = true
    public var autoindent = true          // Vim: off
    public var ignorecase = false
    public var smartcase = false
    public var hlsearch = true            // Vim: off
    public var incsearch = true           // Vim: off
    public var wrapscan = true
    public var joinspaces = false         // Vim: on
    public var startofline = true
    /// Soft wrap; the host follows it (per window, as in Vim).
    public var wrap = true

    public init() {}

    /// Copies the options Vim keeps per window or globally (searching, joining), leaving the
    /// per-buffer ones (tabs, indenting) alone.
    mutating func takeGlobals(from other: VimOptions) {
        ignorecase = other.ignorecase
        smartcase = other.smartcase
        hlsearch = other.hlsearch
        incsearch = other.incsearch
        wrapscan = other.wrapscan
        joinspaces = other.joinspaces
        startofline = other.startofline
    }

    private enum Kind { case bool(WritableKeyPath<VimOptions, Bool>), int(WritableKeyPath<VimOptions, Int>) }

    nonisolated(unsafe) private static let table: [(names: [String], kind: Kind)] = [
        (["tabstop", "ts"], .int(\.tabstop)),
        (["shiftwidth", "sw"], .int(\.shiftwidth)),
        (["expandtab", "et"], .bool(\.expandtab)),
        (["autoindent", "ai"], .bool(\.autoindent)),
        (["ignorecase", "ic"], .bool(\.ignorecase)),
        (["smartcase", "scs"], .bool(\.smartcase)),
        (["hlsearch", "hls"], .bool(\.hlsearch)),
        (["incsearch", "is"], .bool(\.incsearch)),
        (["wrapscan", "ws"], .bool(\.wrapscan)),
        (["joinspaces", "js"], .bool(\.joinspaces)),
        (["startofline", "sol"], .bool(\.startofline)),
        (["wrap"], .bool(\.wrap)),
    ]

    /// Applies the arguments of a `:set` command (`ts=8 noet ic? hls!`). Returns a message
    /// to show (an option's value for `opt?`, or an error), or nil.
    public mutating func set(_ arguments: String) -> String? {
        var shown: [String] = []
        for arg in arguments.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init) {
            var name = arg, value: String?
            if let eq = arg.firstIndex(where: { $0 == "=" || $0 == ":" }) {
                name = String(arg[..<eq])
                value = String(arg[arg.index(after: eq)...])
            }
            var query = false, invert = false, reset = false, negate = false
            if name.hasSuffix("?") { query = true; name.removeLast() }
            if name.hasSuffix("!") { invert = true; name.removeLast() }
            if name.hasSuffix("&") { reset = true; name.removeLast() }
            if name.hasPrefix("inv"), Self.find(String(name.dropFirst(3))) != nil { invert = true; name.removeFirst(3) }
            if name.hasPrefix("no"), Self.find(name) == nil, Self.find(String(name.dropFirst(2))) != nil { negate = true; name.removeFirst(2) }
            guard let kind = Self.find(name) else { return "E518: Unknown option: \(arg)" }
            let full = Self.table.first { $0.names.contains(name) }!.names[0]
            switch kind {
            case .bool(let path):
                if value != nil { return "E474: Invalid argument: \(arg)" }
                if query { shown.append((self[keyPath: path] ? "  " : "no") + full) }
                else if reset { self[keyPath: path] = VimOptions()[keyPath: path] }
                else if invert { self[keyPath: path].toggle() }
                else { self[keyPath: path] = !negate }
            case .int(let path):
                if let value {
                    guard let n = Int(value), n > 0, n <= 100 else { return "E487: Argument must be positive: \(arg)" }
                    self[keyPath: path] = n
                } else if reset {
                    self[keyPath: path] = VimOptions()[keyPath: path]
                } else if negate || invert {
                    return "E474: Invalid argument: \(arg)"
                } else {
                    shown.append("  \(full)=\(self[keyPath: path])")
                }
            }
        }
        return shown.isEmpty ? nil : shown.joined(separator: " ")
    }

    private static func find(_ name: String) -> Kind? {
        table.first { $0.names.contains(name) }?.kind
    }
}
