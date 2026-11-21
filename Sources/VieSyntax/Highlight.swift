/// What a piece of syntax is, for coloring. A theme gives each a color; capture names from the
/// grammars' queries map to them by their longest dotted prefix that has one, so
/// "function.method.call" is `.function` and "keyword.import" is `.keyword`.
public enum Highlight: UInt8, CaseIterable, Sendable {
    /// Default text (also what `@variable` maps to, so it can reset an outer highlight).
    case none
    case comment, keyword, string, escape, number, constant, builtinConstant
    case function, builtinFunction, type, builtinType, builtinVariable, parameter, property
    case `operator`, punctuation, specialPunctuation, tag, attribute, label, module
    /// Markup (Markdown).
    case heading, emphasis, strong, link, literal
    /// Split out from `builtinConstant` and `punctuation`, where themes color them apart.
    case boolean, bracket

    private static let names: [String: Highlight] = [
        "variable": .none, "none": .none,
        "comment": .comment,
        "keyword": .keyword, "include": .keyword, "conditional": .keyword, "repeat": .keyword,
        "exception": .keyword, "import": .keyword,
        // CSS at-rules.
        "media": .keyword, "supports": .keyword, "keyframes": .keyword, "charset": .keyword,
        "string": .string, "character": .string,
        "string.escape": .escape, "string.special": .escape, "string.regexp": .escape, "escape": .escape,
        "character.special": .escape,
        "string.special.key": .property,
        "number": .number, "float": .number,
        "boolean": .boolean, "constant.builtin": .builtinConstant,
        "constant": .constant,
        "function": .function, "method": .function,
        "function.builtin": .builtinFunction,
        "constructor": .type, "type": .type,
        "type.builtin": .builtinType,
        "variable.builtin": .builtinVariable,
        "variable.parameter": .parameter, "parameter": .parameter,
        "variable.member": .property, "property": .property, "field": .property,
        "operator": .operator,
        "punctuation": .punctuation, "delimiter": .punctuation, "punctuation.bracket": .bracket,
        "punctuation.special": .specialPunctuation, "embedded": .specialPunctuation,
        "tag": .tag, "attribute": .attribute, "label": .label,
        "module": .module, "namespace": .module,
        "text.title": .heading, "markup.heading": .heading,
        "text.emphasis": .emphasis, "markup.italic": .emphasis,
        "text.strong": .strong, "markup.bold": .strong, "markup.strong": .strong,
        "text.uri": .link, "text.reference": .link, "markup.link": .link,
        "text.literal": .literal, "markup.raw": .literal,
        // LaTeX math: Vie has no color of its own for it, and code's is the closest.
        "markup.math": .literal,
    ]

    /// The highlight for a query capture name, or nil for captures that aren't highlights
    /// (`@_name` helpers, `@injection.content`, `@spell`) and names with no known prefix.
    public init?(captureName: String) {
        if captureName.hasPrefix("_") || captureName.hasPrefix("injection.") { return nil }
        var name = Substring(captureName)
        while true {
            if let h = Self.names[String(name)] {
                self = h
                return
            }
            guard let dot = name.lastIndex(of: ".") else { return nil }
            name = name[..<dot]
        }
    }
}
