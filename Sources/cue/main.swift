import CueCore
import Foundation

// Pick the mode before AppKit loads, so a hook run stays a few milliseconds.
switch CommandLine.arguments.dropFirst().first {
case "hook":
    Hook.run(CommandLine.arguments.dropFirst(2).first ?? "claude")
case "send":
    signal(SIGPIPE, SIG_IGN)  // osascript dying before it reads its script must not kill us
    exit(SendCommand.run(Array(CommandLine.arguments.dropFirst(2))))
case "open":
    // Open from the command line, for tests and scripts: prints "opened", or the apps the app would
    // bring forward, or why it couldn't.
    guard let id = CommandLine.arguments.dropFirst(2).first, let s = Store.read(id) else {
        FileHandle.standardError.write(Data("usage: cue open <session-id>\n".utf8))
        exit(1)
    }
    do {
        let apps = try Delivery.open(s)
        print(apps.isEmpty ? "opened" : "bring forward: \(apps)")
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("\(error.message)\n".utf8))
        exit(1)
    }
case "login-item":
    // For uninstall.sh: takes Cue out of your login items before the app goes. `on` puts it back.
    switch CommandLine.arguments.dropFirst(2).first {
    case "off": LoginItem.unregister()
    case "on": LoginItem.register()
    default:
        FileHandle.standardError.write(Data("usage: cue login-item on|off\n".utf8))
        exit(1)
    }
    exit(0)
case "codex-health":
    // The footer's Codex check from the command line: "ok", the warning, or "no answer".
    let exe = CommandLine.arguments.dropFirst(2).first ?? Bundle.main.executablePath ?? ""
    print(Codex.listHooks().map { Codex.warning($0, command: Codex.command(exe: exe)) ?? "ok" } ?? "no answer")
    exit(0)
case let word? where !word.hasPrefix("-"):
    // An unknown word must not start a second copy of the app. (`open` and AppKit defaults pass flags.)
    FileHandle.standardError.write(Data("usage: cue [hook claude|codex | send <session-id> <text> | open <session-id> | login-item on|off | codex-health [cue path]]\n".utf8))
    exit(64)
default:
    signal(SIGPIPE, SIG_IGN)
    CueApp.main()
}
