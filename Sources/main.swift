import Foundation

// Pick the mode before AppKit loads, so a hook run stays a few milliseconds.
switch CommandLine.arguments.dropFirst().first {
case "hook":
    Hook.run()
case "send":
    signal(SIGPIPE, SIG_IGN)  // osascript dying before it reads its script must not kill us
    exit(SendCommand.run(Array(CommandLine.arguments.dropFirst(2))))
default:
    FileHandle.standardError.write(Data("usage: ClaudeRelay hook | send <session-id> <text>\n".utf8))
    exit(1)
}
