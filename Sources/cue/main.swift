import CueCore
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
case "codex-health":
    // The footer's Codex check from the command line: "ok", the warning, or "no answer".
    let exe = CommandLine.arguments.dropFirst(2).first ?? Bundle.main.executablePath ?? ""
    print(Codex.listHooks().map { Codex.warning($0, command: Codex.command(exe: exe)) ?? "ok" } ?? "no answer")
    exit(0)
default:
    signal(SIGPIPE, SIG_IGN)
    CueApp.main()
}
