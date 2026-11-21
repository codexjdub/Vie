import Foundation
import TreeSitter
import TreeSitterGrammars

/// A bundled grammar: which files use it, its parser, and its highlight and injection queries
/// (compiled on first use; query files are built into the app, see TreeSitterGrammars).
public final class SyntaxLanguage: @unchecked Sendable {
    /// The grammar's name, as code fences and injections use it ("swift", "markdown_inline").
    public let name: String
    /// For people ("Swift", "Markdown").
    public let displayName: String
    let pointer: OpaquePointer
    private let highlightFiles: [String]
    private let injectionFiles: [String]
    private let lock = NSLock()
    private var compiled: (highlights: Query?, injections: Query?, errors: [String])?

    init(_ name: String, _ displayName: String, _ language: OpaquePointer?, highlights: [String], injections: [String] = []) {
        self.name = name
        self.displayName = displayName
        pointer = language!
        highlightFiles = highlights
        injectionFiles = injections
    }

    var highlights: Query? { load().highlights }
    var injections: Query? { load().injections }

    /// Why this language's queries don't compile; empty when they do (a test checks).
    public var queryErrors: [String] { load().errors }

    private func load() -> (highlights: Query?, injections: Query?, errors: [String]) {
        lock.lock()
        defer { lock.unlock() }
        if let compiled { return compiled }
        var errors: [String] = []
        func compile(_ files: [String]) -> Query? {
            guard !files.isEmpty else { return nil }
            var source = ""
            for file in files {
                guard let text = vie_query_file(file) else {
                    errors.append("\(file): not bundled")
                    continue
                }
                source += String(cString: text) + "\n"
            }
            var error: String?
            let query = Query(language: pointer, source: source, error: &error)
            if let error { errors.append("\(files.joined(separator: " + ")): \(error)") }
            return query
        }
        let result = (compile(highlightFiles), compile(injectionFiles), errors)
        compiled = result
        return result
    }
}

extension SyntaxLanguage {
    /// Every bundled grammar. Later query files extend earlier ones and win where both match.
    public static let all: [SyntaxLanguage] = [
        SyntaxLanguage("bash", "Shell", tree_sitter_bash(), highlights: ["bash/highlights.scm"]),
        SyntaxLanguage("c", "C", tree_sitter_c(), highlights: ["c/highlights.scm"]),
        SyntaxLanguage("cpp", "C++", tree_sitter_cpp(), highlights: ["c/highlights.scm", "cpp/highlights.scm"]),
        SyntaxLanguage("css", "CSS", tree_sitter_css(), highlights: ["css/highlights.scm"]),
        SyntaxLanguage("go", "Go", tree_sitter_go(), highlights: ["go/highlights.scm"]),
        SyntaxLanguage("html", "HTML", tree_sitter_html(), highlights: ["html/highlights.scm"], injections: ["html/injections.scm"]),
        SyntaxLanguage("javascript", "JavaScript", tree_sitter_javascript(),
                       highlights: ["javascript/highlights.scm", "javascript/highlights-jsx.scm"]),
        SyntaxLanguage("json", "JSON", tree_sitter_json(), highlights: ["json/highlights.scm"]),
        SyntaxLanguage("markdown", "Markdown", tree_sitter_markdown(),
                       highlights: ["markdown/highlights.scm"], injections: ["markdown/injections.scm"]),
        SyntaxLanguage("markdown_inline", "Markdown", tree_sitter_markdown_inline(),
                       highlights: ["markdown_inline/highlights.scm"], injections: ["markdown_inline/injections.scm"]),
        SyntaxLanguage("python", "Python", tree_sitter_python(), highlights: ["python/highlights.scm"]),
        SyntaxLanguage("rust", "Rust", tree_sitter_rust(), highlights: ["rust/highlights.scm"]),
        SyntaxLanguage("swift", "Swift", tree_sitter_swift(), highlights: ["swift/highlights.scm"]),
        SyntaxLanguage("toml", "TOML", tree_sitter_toml(), highlights: ["toml/highlights.scm"]),
        SyntaxLanguage("tsx", "TSX", tree_sitter_tsx(),
                       highlights: ["javascript/highlights.scm", "javascript/highlights-jsx.scm", "typescript/highlights.scm"]),
        SyntaxLanguage("typescript", "TypeScript", tree_sitter_typescript(),
                       highlights: ["javascript/highlights.scm", "typescript/highlights.scm"]),
        SyntaxLanguage("yaml", "YAML", tree_sitter_yaml(), highlights: ["yaml/highlights.scm"]),
    ]

    private static let byName = Dictionary(uniqueKeysWithValues: all.map { ($0.name, $0) })

    private static let aliases: [String: String] = [
        "sh": "bash", "shell": "bash", "zsh": "bash", "ksh": "bash", "console": "bash",
        "h": "c", "c++": "cpp", "cc": "cpp", "cxx": "cpp", "hpp": "cpp",
        "golang": "go", "htm": "html", "xhtml": "html",
        "js": "javascript", "jsx": "javascript", "mjs": "javascript", "cjs": "javascript", "node": "javascript",
        "jsonc": "json", "md": "markdown", "py": "python", "python3": "python", "rs": "rust",
        "ts": "typescript", "yml": "yaml",
        // Vim's names for these filetypes.
        "javascriptreact": "javascript", "typescriptreact": "tsx",
    ]

    private static let extensions: [String: String] = [
        "sh": "bash", "bash": "bash", "zsh": "bash", "ksh": "bash",
        "c": "c", "h": "c",
        "cc": "cpp", "cpp": "cpp", "cxx": "cpp", "c++": "cpp", "hh": "cpp", "hpp": "cpp", "hxx": "cpp", "h++": "cpp",
        "ipp": "cpp", "inl": "cpp", "tcc": "cpp",
        "css": "css", "go": "go", "html": "html", "htm": "html", "xhtml": "html",
        "js": "javascript", "mjs": "javascript", "cjs": "javascript", "jsx": "javascript",
        "json": "json", "jsonc": "json", "geojson": "json", "webmanifest": "json",
        "md": "markdown", "markdown": "markdown", "mdown": "markdown", "mkd": "markdown",
        "py": "python", "pyi": "python", "pyw": "python", "rs": "rust", "swift": "swift", "toml": "toml",
        "ts": "typescript", "mts": "typescript", "cts": "typescript", "tsx": "tsx",
        "yaml": "yaml", "yml": "yaml",
    ]

    private static let fileNames: [String: String] = [
        ".bashrc": "bash", ".bash_profile": "bash", ".bash_login": "bash", ".bash_logout": "bash",
        ".profile": "bash", ".zshrc": "bash", ".zprofile": "bash", ".zshenv": "bash", ".zlogin": "bash",
        "PKGBUILD": "bash", "Pipfile": "toml", "Cargo.lock": "toml",
    ]

    /// A language by the name code fences and injections use ("swift", "js", "c++").
    public static func named(_ name: String) -> SyntaxLanguage? {
        let key = name.trimmingCharacters(in: .whitespaces).lowercased()
        return byName[key] ?? aliases[key].flatMap { byName[$0] }
    }

    /// The language of a file, from its name, its extension, or a `#!` first line.
    public static func forFile(named fileName: String, firstLine: String? = nil) -> SyntaxLanguage? {
        if let name = fileNames[fileName] { return byName[name] }
        let ext = (fileName as NSString).pathExtension.lowercased()
        if let name = extensions[ext] { return byName[name] }
        guard let line = firstLine, line.hasPrefix("#!") else { return nil }
        // "#!/usr/bin/env python3", "#!/bin/zsh -f": the interpreter's name, version stripped.
        let words = line.dropFirst(2).split(separator: " ")
        guard var program = words.first.map({ String($0.split(separator: "/").last ?? $0) }) else { return nil }
        if program == "env", words.count > 1 {
            program = String(words.dropFirst().first { !$0.hasPrefix("-") } ?? "")
        }
        let base = program.trimmingCharacters(in: CharacterSet(charactersIn: "0123456789."))
        switch base {
        case "sh", "bash", "zsh", "ksh", "dash": return byName["bash"]
        case "python": return byName["python"]
        case "node", "deno", "bun": return byName["javascript"]
        default: return nil
        }
    }
}
