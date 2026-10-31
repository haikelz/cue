// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Cue",
    platforms: [.macOS(.v14)],
    targets: [
        // Sessions, the store, hooks and delivery: everything but the UI and the command line.
        .target(name: "CueCore"),
        .executableTarget(name: "cue", dependencies: ["CueCore"]),
    ]
)
