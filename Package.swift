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
        .executableTarget(name: "Vie", dependencies: ["VieEditor", "VieWorkspace", "VieText"]),

        // The text view: Core Text rendering, layout cache, input, scrolling.
        .target(name: "VieEditor", dependencies: ["VieText", "VieVim", "VieSyntax"]),

        // Pure Swift, no AppKit.
        .target(name: "VieVim", dependencies: ["VieText"]),
        .target(name: "VieSyntax", dependencies: ["VieText"]),
        .target(name: "VieText"),

        // Folder tree, file watching, fuzzy finder.
        .target(name: "VieWorkspace"),

        // Developer tools (test file generator). Not shipped.
        .executableTarget(name: "vie-dev", dependencies: ["VieText"]),

        .testTarget(name: "VieTextTests", dependencies: ["VieText"]),
    ]
)
