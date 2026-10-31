// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Cue",
    platforms: [.macOS(.v14)],
    targets: [
        // Sessions, the store, hooks and delivery: everything but the UI and the command line.
        .target(name: "CueCore"),
        .executableTarget(name: "cue", dependencies: ["CueCore"]),
        // Beside the shell tests in tests/; macOS folds Tests/ and tests/ into one folder anyway.
        .testTarget(name: "CueCoreTests", dependencies: ["CueCore"], path: "tests/CueCoreTests"),
    ]
)
