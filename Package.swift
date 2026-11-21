// swift-tools-version:6.0
import PackageDescription

// Module layout and dependency direction: see PLAN.md, "Architecture".
let package = Package(
    name: "Vie",
    platforms: [.macOS("27.0")],
    products: [
        .executable(name: "Vie", targets: ["Vie"]),
        .executable(name: "vie-dev", targets: ["vie-dev"]),
    ],
    targets: [
        // App shell: windows, menus, launch options, benchmark mode.
        .executableTarget(name: "Vie", dependencies: ["VieEditor", "VieWorkspace", "VieText", "VieVim", "VieSyntax"]),

        // The text view: Core Text rendering, layout cache, input, scrolling.
        .target(name: "VieEditor", dependencies: ["VieText", "VieVim", "VieSyntax"]),

        // Pure Swift, no AppKit.
        .target(name: "VieVim", dependencies: ["VieText"]),
        .target(name: "VieSyntax", dependencies: ["VieText", "TreeSitter", "TreeSitterGrammars"]),

        // tree-sitter and its grammars, in C. The sources are downloaded into Vendor/ (a link
        // outside the repo) by scripts/fetch-grammars.sh, which make runs first.
        .target(
            name: "TreeSitter",
            path: "Vendor/tree-sitter/lib",
            sources: ["src/lib.c"],
            publicHeadersPath: "include",
            cSettings: [.headerSearchPath("src"), .define("_POSIX_C_SOURCE", to: "200112L"), .define("_DEFAULT_SOURCE"), .unsafeFlags(["-w"])]
        ),
        // One file per grammar parser or scanner, each including the vendored source, plus the
        // highlight queries compiled in. Warnings in generated code are not ours to fix.
        // TypeScript's shared scanner header includes tree_sitter/parser.h from the grammar's src.
        .target(
            name: "TreeSitterGrammars",
            dependencies: ["TreeSitter"],
            exclude: ["queries"],
            cSettings: [.headerSearchPath("../../Vendor/typescript/typescript/src"), .unsafeFlags(["-w"])]
        ),
        .target(name: "VieText"),

        // Documents on disk, file watching; later the folder tree and fuzzy finder.
        .target(name: "VieWorkspace", dependencies: ["VieText"]),

        // Developer tools (test file and repository generators, workspace benchmark). Not shipped.
        .executableTarget(name: "vie-dev", dependencies: ["VieText", "VieWorkspace", "VieSyntax"]),

        .testTarget(name: "VieTextTests", dependencies: ["VieText"]),
        // Drives EditorView's commands without a window.
        .testTarget(name: "VieEditorTests", dependencies: ["VieEditor", "VieText", "VieVim", "VieSyntax"]),
        .testTarget(name: "VieWorkspaceTests", dependencies: ["VieWorkspace", "VieText"]),
        // Grammars and queries load; highlights for real snippets, edits and injected languages.
        .testTarget(name: "VieSyntaxTests", dependencies: ["VieSyntax", "VieText"]),
        // The app's window controllers: tabs, buffer commands, session restore.
        .testTarget(name: "VieAppTests", dependencies: ["Vie", "VieEditor", "VieVim", "VieWorkspace", "VieText", "VieSyntax"]),
        // Vim behavior specs (Specs/*.vimspec, checked against real Vim by scripts/vim-oracle.py).
        .testTarget(name: "VieVimTests", dependencies: ["VieVim", "VieText"], exclude: ["Specs"]),
    ]
)
