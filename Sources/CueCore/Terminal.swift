import Foundation

/// What typing into Claude Code needs from a terminal: its screen, its keys, and a way to bring it
/// forward. An iTerm2 tab answers through AppleScript; a tmux pane, in any terminal, through the tmux CLI;
/// a WezTerm pane and a kitty window through their own CLIs.
protocol Terminal: Sendable {
    /// The visible text, once the tab or pane is known to still hold `tty`.
    func screen(tty: String, timeout: Double) throws(DeliveryError) -> String
    /// Sends each chunk 150 ms apart, once the tab or pane still holds `tty`.
    func send(_ chunks: [[UInt8]], tty: String) throws(DeliveryError)
    /// Brings the session forward itself and returns nothing, or lists the apps that may show it,
    /// nearest first, for the app to activate: CueCore doesn't link AppKit.
    func open() throws(DeliveryError) -> [AppRef]
}

/// An app to bring forward: a process that may be a GUI app, or a bundle id.
package enum AppRef: Sendable {
    case pid(pid_t)
    case bundle(String)
}

/// The bytes Claude delivery sends besides text: 60 Ctrl+K and 60 Ctrl+U clear up to 30 lines after and
/// before the cursor (one write each: Claude Code honors a burst of one key, and dropped a mixed one), ESC CR
/// (Option+Return) breaks a line, CR submits.
enum Key {
    static let clearAfter = [UInt8](repeating: 0x0B, count: 60)
    static let clearBefore = [UInt8](repeating: 0x15, count: 60)
    static let lineBreak: [UInt8] = [0x1B, 0x0D]
    static let submit: [UInt8] = [0x0D]
}

extension Session {
    /// Where Claude prompts go: the tmux pane when Claude runs inside tmux, else the WezTerm pane, the
    /// kitty window (with remote control on) or the iTerm2 tab.
    var terminal: (any Terminal)? {
        if let tmuxSocket, let tmuxPane { return TmuxPane(socket: tmuxSocket, pane: tmuxPane) }
        if let weztermSocket, let weztermPane { return WezTermPane(socket: weztermSocket, pane: weztermPane) }
        if let kittySocket, let kittyWindow { return KittyWindow(socket: kittySocket, window: kittyWindow) }
        return itermSessionId.map(ITermTab.init(id:))
    }
}

extension Session {
    /// Records the terminal a shell's environment names. A terminal started from another's shell
    /// inherits that one's variables (ITERM_SESSION_ID in a WezTerm opened from iTerm2, say), so the
    /// checks run from the innermost terminal out.
    mutating func setTerminal(from env: [String: String]) {
        let number = { (v: String?) in v.flatMap { !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } ? $0 : nil } }
        (tmuxSocket, tmuxPane, weztermSocket, weztermPane, kittySocket, kittyWindow, itermSessionId) = (nil, nil, nil, nil, nil, nil, nil)
        if let tmux = env["TMUX"] {
            // $TMUX is "<socket>,<server pid>,<session>". The pane is the only target.
            let socket = tmux.split(separator: ",", omittingEmptySubsequences: false).dropLast(2).joined(separator: ",")
            let pane = env["TMUX_PANE"] ?? ""
            if socket.hasPrefix("/"), pane.range(of: #"^%[0-9]+$"#, options: .regularExpression) != nil {
                (tmuxSocket, tmuxPane) = (socket, pane)
            }
        } else if let window = number(env["KITTY_WINDOW_ID"]), env["TERM"] == "xterm-kitty" {
            // kitty sets TERM but no TERM_PROGRAM, so a kitty started from a WezTerm shell keeps WezTerm's.
            (kittyWindow, kittySocket) = (window, kittyListen(env))
        } else if env["TERM_PROGRAM"] == "WezTerm" {
            if let socket = env["WEZTERM_UNIX_SOCKET"], socket.hasPrefix("/"), let pane = number(env["WEZTERM_PANE"]) {
                (weztermSocket, weztermPane) = (socket, pane)
            }
        } else if let window = number(env["KITTY_WINDOW_ID"]) {  // kitty with its TERM set in kitty.conf
            (kittyWindow, kittySocket) = (window, kittyListen(env))
        } else {
            itermSessionId = env["ITERM_SESSION_ID"]?.split(separator: ":").last.map(String.init)
        }
    }

    /// kitty's socket, which exists only with listen_on in kitty.conf; a TCP address would reach past this Mac.
    private func kittyListen(_ env: [String: String]) -> String? {
        env["KITTY_LISTEN_ON"].flatMap { $0.hasPrefix("unix:/") ? $0 : nil }
    }

    /// Whether Open has somewhere to go: the terminal, else the app above the session's process (Ghostty,
    /// Terminal.app). Codex records neither; Open looks for it when clicked.
    package var openable: Bool {
        switch agent {
        case .claude, .amp: terminal != nil || pid != nil
        case .codex: true
        }
    }
}

/// The apps that may show the terminal of process `pid`, nearest first, for the app to activate; nil
/// when the process is gone. iTerm2 runs shells under its iTermServer helper, whose parent is launchd
/// rather than iTerm2: its AppleScript selects the tab by `tty` instead (an empty list: done), and
/// failing that, iTerm2 comes forward.
func apps(above pid: pid_t, tty: String) -> [AppRef]? {
    var pid = pid
    var apps: [AppRef] = []
    for _ in 0..<12 {
        guard let p = Proc(pid) else { break }
        if p.name.hasPrefix("iTermServer") { return ITermTab.select(tty: tty) ? [] : apps + [.bundle("com.googlecode.iterm2")] }
        apps.append(.pid(pid))
        pid = p.ppid
    }
    return apps.isEmpty ? nil : apps
}

/// The first of `paths` that runs: an app's own copy before Homebrew's.
func executable(_ paths: [String?]) -> String? {
    paths.compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0) }
}

/// The command inside an app in /Applications or ~/Applications, then on Homebrew's paths.
func executable(app: String, command: String) -> String? {
    executable(["/Applications", NSHomeDirectory() + "/Applications"].map { "\($0)/\(app).app/Contents/MacOS/\(command)" }
               + ["/opt/homebrew/bin/\(command)", "/usr/local/bin/\(command)"])
}

/// An iTerm2 tab, found by its session id and driven through AppleScript.
struct ITermTab: Terminal {
    let id: String

    func screen(tty: String, timeout: Double) throws(DeliveryError) -> String {
        let out = try Self.osascript(Self.probeScript, [id], timeout: timeout)
        let parts = out.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard String(parts[0]) == tty else { throw .moved("Tab no longer runs this session") }
        return parts.count > 1 ? String(parts[1]) : ""
    }

    func send(_ chunks: [[UInt8]], tty: String) throws(DeliveryError) {
        switch try Self.osascript(Self.typeScript, [id, tty] + chunks.map { String(decoding: $0, as: UTF8.self) }) {
        case "ok": return
        case "tty-changed": throw .moved("Tab no longer runs this session")
        case let other: throw .failed("iTerm2 replied: \(other)")
        }
    }

    func open() throws(DeliveryError) -> [AppRef] {
        _ = try Self.osascript(Self.openScript, [id], timeout: 10)
        return []  // the script brought iTerm2 forward
    }

    /// Selects the iTerm2 tab whose session runs on `tty` and brings iTerm2 forward: for a tmux client
    /// in iTerm2, whose session id the hooks can't see. False when no tab runs on that tty.
    static func select(tty: String) -> Bool {
        (try? osascript(selectByTTYScript, [tty], timeout: 10)) == "ok"
    }

    /// Runs AppleScript with arguments in argv, so prompt text never becomes script source. The long
    /// default timeout leaves room for the first-run Automation consent dialog. "missing" means the tab is gone.
    private static func osascript(_ script: String, _ args: [String], timeout: Double = 60) throws(DeliveryError) -> String {
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
                if %match then
        %@
                end if
              end repeat
            end repeat
          end repeat
        end tell
        return "missing"
        """

    private static func script(_ head: String, _ body: String, match: String = "id of s is sid") -> String {
        "on run argv\n\(head)\n" + findSession.replacingOccurrences(of: "%match", with: match).replacingOccurrences(of: "%@", with: body) + "\nend run"
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

    private static let openBody = """
        tell w to select
        tell t to select
        tell s to select
        activate
        return "ok"
        """

    private static let openScript = script("set sid to item 1 of argv", openBody)

    private static let selectByTTYScript = script("set wantTty to item 1 of argv", openBody, match: "tty of s is wantTty")
}

/// A tmux pane, driven through the tmux CLI, which needs no macOS permission. Keys go as raw bytes
/// (`send-keys -H`), the same bytes the iTerm2 script writes: tmux would parse a text argument ending
/// in ";" as a command separator.
struct TmuxPane: Terminal {
    let socket: String, pane: String

    func screen(tty: String, timeout: Double) throws(DeliveryError) -> String {
        guard try paneTTY() == tty else { throw .moved("Pane no longer runs this session") }
        return try tmux(["capture-pane", "-p", "-t", pane])
    }

    func send(_ chunks: [[UInt8]], tty: String) throws(DeliveryError) {
        guard try paneTTY() == tty else { throw .moved("Pane no longer runs this session") }
        for bytes in chunks {
            _ = try tmux(["send-keys", "-t", pane, "-H"] + bytes.map { String(format: "%02x", $0) })
            usleep(150_000)
        }
    }

    /// Selects the pane in its window, then lists the processes above the tmux client you used last:
    /// one of them is the terminal app showing it.
    func open() throws(DeliveryError) -> [AppRef] {
        _ = try tmux(["select-window", "-t", pane, ";", "select-pane", "-t", pane])
        let clients = (try? tmux(["list-clients", "-t", pane, "-F", "#{client_activity} #{client_pid} #{client_tty}"])) ?? ""
        let latest = clients.split(separator: "\n").compactMap { line -> (at: Int, pid: pid_t, tty: String)? in
            let f = line.split(separator: " ")
            guard f.count == 3, let at = Int(f[0]), let pid = pid_t(f[1]) else { return nil }
            return (at, pid, String(f[2]))
        }.max { $0.at < $1.at }
        guard let latest else { throw .failed("No terminal shows this tmux session; run tmux attach") }
        // The client just exited (its window closed) when no process is left to bring forward.
        guard let apps = apps(above: latest.pid, tty: latest.tty) else { throw .failed("Couldn't find the terminal app showing this tmux session") }
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
        guard let exe = executable([Config.load().tmux, "/opt/homebrew/bin/tmux", "/usr/local/bin/tmux"]) else {
            throw .failed("Cue doesn't know where tmux is; run install.sh again")
        }
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

/// A WezTerm pane, driven through `wezterm cli` on the socket of the WezTerm that shows it. Keys go with
/// --no-paste: as a bracketed paste, Claude Code would take the prompt as pasted data.
struct WezTermPane: Terminal {
    let socket: String, pane: String

    func screen(tty: String, timeout: Double) throws(DeliveryError) -> String {
        guard try paneTTY() == tty else { throw .moved("Pane no longer runs this session") }
        return try cli(["get-text", "--pane-id", pane], timeout: timeout)
    }

    func send(_ chunks: [[UInt8]], tty: String) throws(DeliveryError) {
        guard try paneTTY() == tty else { throw .moved("Pane no longer runs this session") }
        for bytes in chunks {
            _ = try cli(["send-text", "--no-paste", "--pane-id", pane], input: String(decoding: bytes, as: UTF8.self))
            usleep(150_000)
        }
    }

    func open() throws(DeliveryError) -> [AppRef] {
        _ = try cli(["activate-pane", "--pane-id", pane])
        return [.bundle("com.github.wez.wezterm")]
    }

    private func paneTTY() throws(DeliveryError) -> String {
        struct Pane: Decodable { let paneId: Int, ttyName: String? }
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        let panes = try? d.decode([Pane].self, from: Data(try cli(["list", "--format", "json"]).utf8))
        guard let tty = panes?.first(where: { String($0.paneId) == pane })?.ttyName else { throw .closed("WezTerm pane is closed") }
        return tty
    }

    private func cli(_ args: [String], input: String? = nil, timeout: Double = 10) throws(DeliveryError) -> String {
        guard let exe = executable(app: "WezTerm", command: "wezterm") else { throw .failed("Cue can't find WezTerm's wezterm command") }
        var env = ProcessInfo.processInfo.environment
        env["WEZTERM_UNIX_SOCKET"] = socket
        do {
            return try Command.run(exe, ["cli", "--no-auto-start"] + args, input: input, env: env, timeout: timeout)
        } catch let e where e.message.contains("no such pane") || e.message.contains("failed to connect") {
            throw .closed("WezTerm pane is closed")
        } catch let e where e.timedOut {
            throw .failed("WezTerm didn't answer in \(Int(timeout)) s")
        } catch {
            throw .failed(error.message)
        }
    }
}

/// A kitty window, driven through `kitten @` on kitty's listen_on socket; kitty.conf needs
/// allow_remote_control and listen_on. Keys go on stdin, which kitty sends as is: it would read
/// escapes such as \\r in an argument.
struct KittyWindow: Terminal {
    let socket: String, window: String

    func screen(tty: String, timeout: Double) throws(DeliveryError) -> String {
        guard try windowTTY() == tty else { throw .moved("Window no longer runs this session") }
        return try kitten(["get-text", "--match", "id:\(window)"], timeout: timeout)
    }

    func send(_ chunks: [[UInt8]], tty: String) throws(DeliveryError) {
        guard try windowTTY() == tty else { throw .moved("Window no longer runs this session") }
        for bytes in chunks {
            _ = try kitten(["send-text", "--match", "id:\(window)", "--stdin"], input: String(decoding: bytes, as: UTF8.self))
            usleep(150_000)
        }
    }

    func open() throws(DeliveryError) -> [AppRef] {
        _ = try kitten(["focus-window", "--match", "id:\(window)"])
        return [.bundle("net.kovidgoyal.kitty")]
    }

    /// The tty of the window's shell: kitty lists a window's processes, not its tty.
    private func windowTTY() throws(DeliveryError) -> String {
        struct OSWindow: Decodable { let tabs: [Tab] }
        struct Tab: Decodable { let windows: [Window] }
        struct Window: Decodable { let id: Int, pid: Int32 }
        let list = try? JSONDecoder().decode([OSWindow].self, from: Data(try kitten(["ls", "--match", "id:\(window)"]).utf8))
        let shell = list?.flatMap(\.tabs).flatMap(\.windows).first { String($0.id) == window }
        guard let shell, let tty = Proc(shell.pid)?.tty else { throw .closed("kitty window is closed") }
        return tty
    }

    private func kitten(_ args: [String], input: String? = nil, timeout: Double = 10) throws(DeliveryError) -> String {
        guard let exe = executable(app: "kitty", command: "kitten") else { throw .failed("Cue can't find kitty's kitten command") }
        do {
            return try Command.run(exe, ["@", "--to", socket] + args, input: input, timeout: timeout)
        } catch let e where e.message.contains("No matching windows") || e.message.contains("Failed to connect") {
            throw .closed("kitty window is closed")
        } catch let e where e.timedOut {
            throw .failed("kitty didn't answer in \(Int(timeout)) s")
        } catch {
            throw .failed(error.message)
        }
    }
}
