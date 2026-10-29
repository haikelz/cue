// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "ClaudeRelay",
    platforms: [.macOS(.v14)],
    targets: [.executableTarget(name: "ClaudeRelay", path: "Sources")]
)
