import Foundation

/// What typing into Claude Code needs from a terminal: its screen, its keys, and a way to bring it
/// forward. An iTerm2 tab answers through AppleScript; a tmux pane, in any terminal, through the tmux CLI.
package protocol Terminal: Sendable {
    /// The visible text, once the tab or pane is known to still hold `tty`.
    func screen(tty: String, timeout: Double) throws(DeliveryError) -> String
    /// Sends each chunk 150 ms apart, once the tab or pane still holds `tty`.
    func send(_ chunks: [[UInt8]], tty: String) throws(DeliveryError)
    /// Brings the session forward itself and returns nothing, or lists the apps that may show it,
    /// nearest first, for the app to activate: CueCore doesn't link AppKit.
    func open() throws(DeliveryError) -> [AppRef]
}

/// An app to bring forward: a process that may be a GUI app, or a bundle id.
package enum AppRef: Equatable, Sendable {
    case pid(pid_t)
    case bundle(String)
}

/// The bytes Claude delivery sends besides text: Ctrl+U clears to line start, ESC CR (Option+Return)
/// breaks a line, CR submits.
package enum Key {
    package static let clearLine: [UInt8] = [0x15]
    package static let lineBreak: [UInt8] = [0x1B, 0x0D]
    package static let submit: [UInt8] = [0x0D]
}

extension Session {
    /// Where Claude prompts go: the tmux pane when Claude runs inside tmux, else the iTerm2 tab.
    package var terminal: (any Terminal)? {
        if let tmuxSocket, let tmuxPane { return TmuxPane(socket: tmuxSocket, pane: tmuxPane) }
        return itermSessionId.map(ITermTab.init(id:))
    }
}

/// An iTerm2 tab, found by its session id and driven through AppleScript.
package struct ITermTab: Terminal {
    package let id: String

    package func screen(tty: String, timeout: Double) throws(DeliveryError) -> String {
        let out = try osascript(Self.probeScript, [id], timeout: timeout)
        let parts = out.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard String(parts[0]) == tty else { throw .moved("Tab no longer runs this session") }
        return parts.count > 1 ? String(parts[1]) : ""
    }

    package func send(_ chunks: [[UInt8]], tty: String) throws(DeliveryError) {
        switch try osascript(Self.typeScript, [id, tty] + chunks.map { String(decoding: $0, as: UTF8.self) }) {
        case "ok": return
        case "tty-changed": throw .moved("Tab no longer runs this session")
        case let other: throw .failed("iTerm2 replied: \(other)")
        }
    }

    package func open() throws(DeliveryError) -> [AppRef] {
        _ = try osascript(Self.openScript, [id], timeout: 10)
        return []  // the script brought iTerm2 forward
    }

    /// Runs AppleScript with arguments in argv, so prompt text never becomes script source. The long
    /// default timeout leaves room for the first-run Automation consent dialog. "missing" means the tab is gone.
    private func osascript(_ script: String, _ args: [String], timeout: Double = 60) throws(DeliveryError) -> String {
        let out: String
        do {
            out = try Command.run("/usr/bin/osascript", ["-"] + args, input: script, timeout: timeout)
        } catch let e where e.timedOut {
            throw .failed("iTerm2 didn't answer in \(Int(timeout)) s")
        } catch let e where e.message.contains("-1743") || e.message.contains("Not authorized") {
            throw .failed("Allow Cue to control iTerm2 in System Settings > Privacy & Security > Automation")
        } catch {
            throw .failed(error.message)
        }
        guard out != "missing" else { throw .closed("iTerm2 tab is closed") }
        return out
    }

    private static let findSession = """
        tell application "iTerm2"
          repeat with w in windows
            repeat with t in tabs of w
              repeat with s in sessions of t
                if id of s is sid then
        %@
                end if
              end repeat
            end repeat
          end repeat
        end tell
        return "missing"
        """

    private static func script(_ head: String, _ body: String) -> String {
        "on run argv\n\(head)\n" + findSession.replacingOccurrences(of: "%@", with: body) + "\nend run"
    }

    private static let probeScript = script("set sid to item 1 of argv", """
        return (tty of s) & linefeed & (contents of s)
        """)

    /// argv: session id, tty, then the chunks, each written as is and followed by a 150 ms pause.
    private static let typeScript = script("""
        set sid to item 1 of argv
        set wantTty to item 2 of argv
        """, """
        if tty of s is not wantTty then return "tty-changed"
        repeat with i from 3 to count of argv
          tell s to write text (item i of argv) newline no
          delay 0.15
        end repeat
        return "ok"
        """)

    private static let openScript = script("set sid to item 1 of argv", """
        tell w to select
        tell t to select
        tell s to select
        activate
        return "ok"
        """)
}

/// A tmux pane, driven through the tmux CLI, which needs no macOS permission. Keys go as raw bytes
/// (`send-keys -H`), the same bytes the iTerm2 script writes: tmux would parse a text argument ending
/// in ";" as a command separator.
package struct TmuxPane: Terminal {
    package let socket: String, pane: String

    package func screen(tty: String, timeout: Double) throws(DeliveryError) -> String {
        guard try paneTTY() == tty else { throw .moved("Pane no longer runs this session") }
        return try tmux(["capture-pane", "-p", "-t", pane])
    }

    package func send(_ chunks: [[UInt8]], tty: String) throws(DeliveryError) {
        guard try paneTTY() == tty else { throw .moved("Pane no longer runs this session") }
        for bytes in chunks {
            _ = try tmux(["send-keys", "-t", pane, "-H"] + bytes.map { String(format: "%02x", $0) })
            usleep(150_000)
        }
    }

    /// Selects the pane in its window, then lists the processes above the tmux client you used last:
    /// one of them is the terminal app showing it.
    package func open() throws(DeliveryError) -> [AppRef] {
        _ = try tmux(["select-window", "-t", pane, ";", "select-pane", "-t", pane])
        let clients = (try? tmux(["list-clients", "-t", pane, "-F", "#{client_activity} #{client_pid}"])) ?? ""
        let latest = clients.split(separator: "\n").compactMap { line -> (Int, pid_t)? in
            let f = line.split(separator: " ")
            guard f.count == 2, let at = Int(f[0]), let pid = pid_t(f[1]) else { return nil }
            return (at, pid)
        }.max { $0.0 < $1.0 }
        guard var pid = latest?.1 else { throw .failed("No terminal shows this tmux session; run tmux attach") }
        var apps: [AppRef] = []
        for _ in 0..<12 {
            guard let p = Proc(pid) else { break }
            // iTerm2 runs shells under its iTermServer helper, whose parent is launchd rather than iTerm2.
            if p.name.hasPrefix("iTermServer") { return apps + [.bundle("com.googlecode.iterm2")] }
            apps.append(.pid(pid))
            pid = p.ppid
        }
        // The client just exited (its window closed), so no process is left to bring forward.
        guard !apps.isEmpty else { throw .failed("Couldn't find the terminal app showing this tmux session") }
        return apps
    }

    /// The pane's tty. Refuses copy mode, where tmux reads keys as its own commands (and capture-pane
    /// still shows Claude's screen), and synchronized panes, where tmux copies keys to every pane in the window.
    private func paneTTY() throws(DeliveryError) -> String {
        let out = try tmux(["display-message", "-p", "-t", pane, "#{pane_in_mode}#{pane_synchronized} #{pane_tty}"])
        let f = out.split(separator: " ", maxSplits: 1)
        guard f.count == 2 else { throw .closed("tmux pane is closed") }  // a gone pane prints nothing
        if f[0].hasPrefix("1") { throw .refused("tmux pane is in copy mode; press q in it") }
        if f[0].hasSuffix("1") { throw .refused("tmux panes are synchronized; turn synchronize-panes off") }
        return String(f[1])
    }

    private func tmux(_ args: [String]) throws(DeliveryError) -> String {
        let exe = [Config.load().tmux, "/opt/homebrew/bin/tmux", "/usr/local/bin/tmux"].compactMap { $0 }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let exe else { throw .failed("Cue doesn't know where tmux is; run install.sh again") }
        do {
            return try Command.run(exe, ["-S", socket] + args, timeout: 10)
        } catch let e where ["can't find", "no server", "error connecting"].contains(where: e.message.contains) {
            throw .closed("tmux pane is closed")
        } catch let e where e.timedOut {
            throw .failed("tmux didn't answer in 10 s")
        } catch {
            throw .failed(error.message)
        }
    }
}
