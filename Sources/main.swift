import Foundation

// Pick the mode before AppKit loads, so a hook run stays a few milliseconds.
switch CommandLine.arguments.dropFirst().first {
case "hook":
    Hook.run()
default:
    FileHandle.standardError.write(Data("usage: ClaudeRelay hook\n".utf8))
    exit(1)
}
