// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "VieSpike",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "VieSpike", path: "Sources/VieSpike"),
    ]
)
