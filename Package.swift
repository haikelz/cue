// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Cue",
    platforms: [.macOS(.v14)],
    targets: [.executableTarget(name: "cue", path: "Sources")]
)
