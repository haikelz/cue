import Foundation

// Pick the mode before AppKit loads, so a hook run stays a few milliseconds.
switch CommandLine.arguments.dropFirst().first {
case "hook":
    Hook.run(CommandLine.arguments.dropFirst(2).first ?? "claude")
case "send":
    signal(SIGPIPE, SIG_IGN)  // osascript dying before it reads its script must not kill us
    exit(SendCommand.run(Array(CommandLine.arguments.dropFirst(2))))
case "selftest":
    exit(SelfTest.run())
default:
    signal(SIGPIPE, SIG_IGN)
    CueApp.main()
}
