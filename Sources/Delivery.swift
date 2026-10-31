import AppKit

enum Outcome {
    case sent(at: Double)  // the turn should start; `last_prompt_at` confirms it
    case accepted(String)  // the agent took the prompt itself; the note says "Sent" or "Queued"
    case inbox(String)     // Amp: dropped in the inbox under this id; a receipt confirms it
    case refused(String)   // a check failed before anything was sent
    case failed(String)    // sending may have started; treat the prompt as at risk
}

enum Delivery {
    /// Sends `raw` to a session through its agent's channel.
    static func send(sessionId: String, text raw: String) -> Outcome {
        let text = sanitize(raw)
        guard !text.isEmpty else { return .refused("Prompt is empty") }
        guard let s = Store.read(sessionId) else { return .refused("Session is gone") }
        switch s.agent {
        case "codex": return queueToCodex(s, text)
        case "amp": return Inbox.drop(s, text)
        default: return typeIntoClaude(s, text)
        }
    }

    /// `codex queue` hands the prompt to Codex's daemon, which runs it now or after the current turn.
    /// The `=` forms keep a prompt that starts with "-" from parsing as a flag.
    static func queueToCodex(_ s: Session, _ text: String) -> Outcome {
        let config = Config.load()
        guard let codex = config.codex, FileManager.default.isExecutableFile(atPath: codex) else {
            return .refused("Cue doesn't know where codex is; run install.sh again")
        }
        guard s.sessionId.range(of: #"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"#, options: .regularExpression) != nil else {
            return .refused("Not a Codex session id")
        }
        var env = ProcessInfo.processInfo.environment
        if let path = config.path { env["PATH"] = path }
        switch run(codex, ["queue", "--thread=\(s.sessionId)", "--message=\(text)"], env: env, timeout: 30) {
        // Exit 0 means Codex accepted the prompt. Waiting for UserPromptSubmit on top of that could only
        // turn a slow start into "Not confirmed" and invite a second, duplicate send.
        case .success: return .accepted(s.status == "idle" ? "Sent" : "Queued")
        case .failure(let e): return .failed("codex queue: \(e.message)")
        }
    }

    /// Types the prompt into the session's iTerm2 tab or tmux pane, then presses Return, each step behind the full set of checks.
    static func typeIntoClaude(_ s: Session, _ text: String) -> Outcome {
        guard s.deliverable, let tty = s.tty else { return .refused("Not in iTerm2 or tmux") }

        let screen: Screen
        switch check(s) {
        case .failure(let why): return .refused(why.message)
        case .success(let found): screen = found
        }

        // A draft or a grayed-out suggestion sits in the box: Ctrl+U clears it, once per box line.
        // A real draft stays recoverable with Ctrl+Y in that tab.
        let clears = screen.box.first.map { $0 == "❯" || $0.hasPrefix("❯ Try \"") } == true ? 0 : screen.box.count
        let at = Date().timeIntervalSince1970
        let typed: Result<String, ScriptError>
        if let pane = Tmux(s) {
            let bytes = items(text).map { $0 == "\u{1}" ? [0x1B, 0x0D] : Array($0.utf8) }
            typed = pane.type(tty: tty, Array(repeating: [0x15], count: clears) + bytes)
        } else {
            typed = osascript(typeScript, [s.itermSessionId ?? "", tty, String(clears)] + items(text))
        }
        switch typed {
        case .failure(let e): return .failed(e.message)
        case .success("ok"): break
        case .success("missing"): return .failed(closed(s))
        case .success("tty-changed"): return .refused(moved(s))
        case .success(let other): return .failed("iTerm2 replied: \(other)")
        }

        // Typing a long prompt takes seconds. Before Return, check everything again, and check the box
        // ends with this prompt (a long draft scrolls inside the box, so its start may be out of view).
        switch check(s) {
        case .failure(let why):
            return .failed("Typed but not sent: \(why.message). The text is in Claude's input box")
        case .success(let after):
            guard box(after.box, endsWith: text) else {
                return .failed("Typed but not sent: the input box doesn't end with this prompt")
            }
        }
        switch Tmux(s).map({ $0.type(tty: tty, [[0x0D]]) }) ?? osascript(returnScript, [s.itermSessionId ?? "", tty]) {
        case .success("ok"): return .sent(at: at)
        case .success(let other): return .failed("Typed but not sent: \(other)")
        case .failure(let e): return .failed("Typed but not sent: \(e.message)")
        }
    }

    struct Screen { let box: [String] }
    struct Refusal: Error { let message: String }

    /// Every check that guards typing: process facts first, then what the tab shows.
    static func check(_ s: Session) -> Result<Screen, Refusal> {
        if let why = gate(Store.read(s.sessionId) ?? s) { return .failure(Refusal(message: why)) }
        switch probe(s) {
        case .failure(let e): return .failure(Refusal(message: e.message))
        case .success(let out):
            guard out != "missing" else { return .failure(Refusal(message: closed(s))) }
            let parts = out.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.first.map(String.init) == s.tty else { return .failure(Refusal(message: moved(s))) }
            let text = parts.count > 1 ? String(parts[1]) : ""
            if let why = screenProblem(text) { return .failure(Refusal(message: why)) }
            return .success(Screen(box: box(text)?.lines ?? []))
        }
    }

    /// The tty line, then the visible screen; "missing" when the tab or pane is gone.
    static func probe(_ s: Session, timeout: Double = 60) -> Result<String, ScriptError> {
        if let pane = Tmux(s) { return pane.probe() }
        guard let sid = s.itermSessionId else { return .failure(ScriptError(message: "Not in iTerm2 or tmux")) }
        return osascript(probeScript, [sid], timeout: timeout)
    }

    static func closed(_ s: Session) -> String { s.tmuxPane == nil ? "iTerm2 tab is closed" : "tmux pane is closed" }
    static func moved(_ s: Session) -> String { s.tmuxPane == nil ? "Tab no longer runs this session" : "Pane no longer runs this session" }

    /// Process checks, cheapest first. Returns why typing must not happen, or nil.
    static func gate(_ s: Session) -> String? {
        guard s.status == "idle" else { return s.status == "working" ? "Claude is working" : "Claude needs you in the terminal" }
        guard let pid = s.pid, let p = Proc(pid), let start = s.pidStart, abs(p.start - start) < 0.01 else {
            return "Claude process is gone"
        }
        guard !p.stopped, p.tpgid == p.pgid else { return "Claude isn't in the foreground (suspended?)" }
        guard p.tty == s.tty else { return "Claude's terminal changed" }
        return nil
    }

    /// Why the screen is unsafe to type into, or nil. The box check catches what process checks
    /// can't: a permission dialog, a picker, the Ctrl+G editor. Only lines next to the box count,
    /// so Claude's own output can't trip the spinner or vim checks.
    static func screenProblem(_ screen: String) -> String? {
        guard let b = box(screen) else { return "Claude's input box isn't on screen (dialog, editor or menu open)" }
        if b.above.contains(where: isSpinner) { return "Claude is working" }
        if (b.lines + b.below).contains(where: { $0.contains("-- NORMAL --") }) {
            return "Claude's vim mode is in NORMAL; press i in the terminal"
        }
        return nil
    }

    struct Box { let lines: [String], above: [String], below: [String] }

    /// Claude Code's input box: a rule line, a line starting with "❯" (or "!" in bash mode),
    /// more input lines, a rule line. The last such box on screen, with its neighbours.
    /// The prompt marker sits in column 0; dialog options (" ❯ 1. Yes") are indented.
    static func box(_ screen: String) -> Box? {
        let raw = screen.split(separator: "\n").map(String.init).filter { !$0.allSatisfy(\.isWhitespace) }
        let tail = Array(raw.suffix(30))
        let trim: (String) -> String = { $0.trimmingCharacters(in: .whitespaces) }
        let isRule: (String) -> Bool = { let t = trim($0); return t.count >= 20 && t.allSatisfy { $0 == "─" } }
        for i in tail.indices.reversed() where i > 0 && (tail[i].hasPrefix("❯") || tail[i].hasPrefix("!")) && isRule(tail[i - 1]) {
            guard let end = tail[(i + 1)...].prefix(25).firstIndex(where: isRule) else { continue }
            return Box(lines: tail[i..<end].map(trim), above: tail[max(0, i - 7)..<(i - 1)].map(trim), below: tail[(end + 1)...].map(trim))
        }
        return nil
    }

    /// True when the box's last line is the end of the prompt's last line (wrapping keeps that a suffix).
    static func box(_ lines: [String], endsWith text: String) -> Bool {
        let tail = String(text.split(separator: "\n", omittingEmptySubsequences: false).last ?? "").trimmingCharacters(in: .whitespaces)
        var last = lines.last ?? ""
        if lines.count == 1 { last = String(last.dropFirst()) }  // the "❯" or "!" marker
        last = last.trimmingCharacters(in: .whitespaces)
        return !last.isEmpty && tail.hasSuffix(last)
    }

    /// The working spinner line: "✻ Propagating… (4s · ↓ 263 tokens)". A finished turn reads "✻ Cooked for 2s".
    static func isSpinner(_ line: String) -> Bool {
        line.range(of: #"^\S\s+[^\s…]+…\s*\("#, options: .regularExpression) != nil
    }

    /// For a row stuck at working: true when the tab shows an idle input box. Catches Esc pressed
    /// before Claude wrote anything, which leaves no hook event and no transcript marker.
    static func looksIdle(_ s: Session) -> Bool {
        guard case .success(let out) = probe(s, timeout: 10) else { return false }
        let parts = out.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        return parts.count == 2 && String(parts[0]) == s.tty && screenProblem(String(parts[1])) == nil
    }

    /// Drops what a terminal would read as keys or what hides text: C0/C1 controls (line breaks stay),
    /// invisible, bidi, tag and variation-selector characters. Tabs become spaces, since Tab completes.
    static func sanitize(_ s: String) -> String {
        let kept = s.unicodeScalars.compactMap { u -> Unicode.Scalar? in
            switch u.value {
            case 0x0A: return u
            case 0x09: return " "
            case 0x00...0x1F, 0x7F...0x9F, 0x061C, 0x115F, 0x1160, 0x180E, 0x200B...0x200F, 0x2028...0x202E,
                 0x2060...0x2069, 0x3164, 0xFEFF, 0xFFA0, 0xE0000...0xE007F, 0xE0100...0xE01EF:
                return nil
            default: return u
            }
        }
        var out = String(String.UnicodeScalarView(kept)).trimmingCharacters(in: .whitespacesAndNewlines)
        if out.hasSuffix("\\") { out += " " }  // "\" then Return inserts a line break instead of submitting
        return out
    }

    /// Lines cut into 200-character chunks; "\u{1}" marks a line break (sent as Option+Return).
    /// Claude Code reads input that arrives in one burst as a paste and treats it as data, not as
    /// your instruction; the type script waits 150 ms between chunks to stay under that detector.
    static func items(_ text: String) -> [String] {
        var out: [String] = []
        for (n, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if n > 0 { out.append("\u{1}") }
            var rest = Substring(line)
            while !rest.isEmpty {
                out.append(String(rest.prefix(200)))
                rest = rest.dropFirst(200)
            }
        }
        return out
    }

    static func open(_ s: Session) -> String? {
        if let pane = Tmux(s) { return pane.open() }
        guard let sid = s.itermSessionId else { return "Not in iTerm2 or tmux" }
        switch osascript(openScript, [sid], timeout: 10) {
        case .success("ok"): return nil
        case .success: return "iTerm2 tab is closed"
        case .failure(let e): return e.message
        }
    }

    struct ScriptError: Error { let message: String }

    /// Runs AppleScript with arguments in argv, so prompt text never becomes script source.
    /// The long default timeout leaves room for the first-run Automation consent dialog.
    static func osascript(_ script: String, _ args: [String], timeout: Double = 60) -> Result<String, ScriptError> {
        switch run("/usr/bin/osascript", ["-"] + args, input: script, timeout: timeout) {
        case .success(let out): return .success(out)
        case .failure(let e) where e.message.hasPrefix("no answer"): return .failure(ScriptError(message: "iTerm2 didn't answer in \(Int(timeout)) s"))
        case .failure(let e) where e.message.contains("-1743") || e.message.contains("Not authorized"):
            return .failure(ScriptError(message: "Allow Cue to control iTerm2 in System Settings > Privacy & Security > Automation"))
        case .failure(let e): return .failure(e)
        }
    }

    /// Runs a program, feeding `input` on stdin, and kills it after `timeout` seconds.
    static func run(_ exe: String, _ args: [String], input: String? = nil, env: [String: String]? = nil,
                    timeout: Double) -> Result<String, ScriptError> {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        if let env { p.environment = env }
        let stdin = Pipe(), output = Pipe(), errors = Pipe()
        p.standardInput = stdin
        p.standardOutput = output
        p.standardError = errors
        do { try p.run() } catch { return .failure(ScriptError(message: "\(exe): \(error.localizedDescription)")) }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if p.isRunning { p.terminate() } }
        // The throwing write: a child that exits before reading must not raise an exception here.
        if let input { try? stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8)) }
        try? stdin.fileHandleForWriting.close()
        let out = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let err = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            if p.terminationReason == .uncaughtSignal { return .failure(ScriptError(message: "no answer in \(Int(timeout)) s")) }
            let first = err.split(whereSeparator: \.isNewline).first.map(String.init) ?? "exit \(p.terminationStatus)"
            return .failure(ScriptError(message: first))
        }
        return .success(out.trimmingCharacters(in: .newlines))
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

    static let probeScript = script("set sid to item 1 of argv", """
        return (tty of s) & linefeed & (contents of s)
        """)

    /// argv: session id, tty, Ctrl+U count, then text chunks and "\u{1}" line breaks. No Return.
    static let typeScript = script("""
        set sid to item 1 of argv
        set wantTty to item 2 of argv
        set clears to (item 3 of argv) as integer
        """, """
        if tty of s is not wantTty then return "tty-changed"
        repeat clears times
          tell s to write text (ASCII character 21) newline no
          delay 0.15
        end repeat
        repeat with i from 4 to count of argv
          set c to item i of argv
          if c is (ASCII character 1) then
            tell s to write text ((ASCII character 27) & (ASCII character 13)) newline no
          else
            tell s to write text c newline no
          end if
          delay 0.15
        end repeat
        return "ok"
        """)

    static let returnScript = script("""
        set sid to item 1 of argv
        set wantTty to item 2 of argv
        """, """
        if tty of s is not wantTty then return "tty-changed"
        tell s to write text (ASCII character 13) newline no
        return "ok"
        """)

    static let openScript = script("set sid to item 1 of argv", """
        tell w to select
        tell t to select
        tell s to select
        activate
        return "ok"
        """)
}

/// A Claude session's tmux pane, driven through the tmux CLI, which needs no macOS permission.
/// Keys go as raw bytes (`send-keys -H`), the same bytes the iTerm2 script writes; tmux would parse a
/// text argument ending in ";" as a command separator.
struct Tmux {
    let socket: String, pane: String

    init?(_ s: Session) {
        guard let socket = s.tmuxSocket, let pane = s.tmuxPane else { return nil }
        (self.socket, self.pane) = (socket, pane)
    }

    /// Replies "missing" when the pane or its server is gone.
    func run(_ args: [String]) -> Result<String, Delivery.ScriptError> {
        let exe = [Config.load().tmux, "/opt/homebrew/bin/tmux", "/usr/local/bin/tmux"].compactMap { $0 }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let exe else { return .failure(.init(message: "Cue doesn't know where tmux is; run install.sh again")) }
        switch Delivery.run(exe, ["-S", socket] + args, timeout: 10) {
        case .failure(let e) where ["can't find", "no server", "error connecting"].contains(where: e.message.contains):
            return .success("missing")
        case .failure(let e) where e.message.hasPrefix("no answer"): return .failure(.init(message: "tmux didn't answer in 10 s"))
        case let other: return other
        }
    }

    /// The pane's tty, or "missing". Refuses copy mode, where tmux reads keys as its own commands (and
    /// capture-pane still shows Claude's screen), and synchronized panes, where tmux copies keys to
    /// every pane in the window.
    func target() -> Result<String, Delivery.ScriptError> {
        run(["display-message", "-p", "-t", pane, "#{pane_in_mode}#{pane_synchronized} #{pane_tty}"]).flatMap { out in
            let f = out.split(separator: " ", maxSplits: 1)
            guard f.count == 2 else { return .success("missing") }  // a gone pane prints nothing
            if f[0].hasPrefix("1") { return .failure(.init(message: "tmux pane is in copy mode; press q in it")) }
            if f[0].hasSuffix("1") { return .failure(.init(message: "tmux panes are synchronized; turn synchronize-panes off")) }
            return .success(String(f[1]))
        }
    }

    func probe() -> Result<String, Delivery.ScriptError> {
        target().flatMap { tty in
            tty == "missing" ? .success(tty) : run(["capture-pane", "-p", "-t", pane]).map { $0 == "missing" ? $0 : tty + "\n" + $0 }
        }
    }

    /// Sends each chunk 150 ms apart once the pane still holds `tty`. Replies like the iTerm2 scripts:
    /// ok, missing, tty-changed.
    func type(tty: String, _ chunks: [[UInt8]]) -> Result<String, Delivery.ScriptError> {
        switch target() {
        case .failure(let e): return .failure(e)
        case .success("missing"): return .success("missing")
        case .success(let t) where t != tty: return .success("tty-changed")
        default: break
        }
        for bytes in chunks {
            switch run(["send-keys", "-t", pane, "-H"] + bytes.map { String(format: "%02x", $0) }) {
            case .failure(let e): return .failure(e)
            case .success("missing"): return .success("missing")
            default: usleep(150_000)
            }
        }
        return .success("ok")
    }

    /// Selects the pane in its window, then brings up the terminal app of the client you used last.
    /// ponytail: the app comes forward with its own front window; with several windows, that may not be the one.
    func open() -> String? {
        switch run(["select-window", "-t", pane, ";", "select-pane", "-t", pane]) {
        case .failure(let e): return e.message
        case .success("missing"): return "tmux pane is closed"
        default: break
        }
        guard case .success(let out) = run(["list-clients", "-t", pane, "-F", "#{client_activity} #{client_pid}"]),
              let client = out.split(separator: "\n").compactMap({ line -> (Int, pid_t)? in
                  let f = line.split(separator: " ")
                  guard f.count == 2, let at = Int(f[0]), let pid = pid_t(f[1]) else { return nil }
                  return (at, pid)
              }).max(by: { $0.0 < $1.0 })
        else { return "No terminal shows this tmux session; run tmux attach" }
        var pid = client.1
        for _ in 0..<12 {
            guard let p = Proc(pid) else { break }
            // iTerm2 runs shells under its iTermServer helper, whose parent is launchd rather than iTerm2.
            let app = p.name.hasPrefix("iTermServer")
                ? NSRunningApplication.runningApplications(withBundleIdentifier: "com.googlecode.iterm2").first
                : NSRunningApplication(processIdentifier: pid)
            if let app, app.activationPolicy == .regular {
                app.activate()
                return nil
            }
            pid = p.ppid
        }
        return "Couldn't find the terminal app showing this tmux session"
    }
}

/// `cue send <session-id> <text>`: the app's delivery path, for tests and scripts.
/// Exit 0 = sent and confirmed, 1 = refused or failed, 2 = sent but not confirmed in 5 s.
enum SendCommand {
    /// Exit 0 = delivered (or queued behind a running turn), 1 = refused or failed, 2 = sent but not confirmed.
    static func run(_ args: [String]) -> Int32 {
        guard args.count == 2 else {
            FileHandle.standardError.write(Data("usage: cue send <session-id> <text>\n".utf8))
            return 1
        }
        let (id, text) = (args[0], args[1])
        switch Delivery.send(sessionId: id, text: text) {
        case .refused(let why), .failed(let why):
            FileHandle.standardError.write(Data("\(why)\n".utf8))
            return 1
        case .accepted(let note):
            print(note.lowercased())
            return 0
        case .sent(let at):
            if Delivery.skipsConfirmation(text) { print("sent"); return 0 }
            for _ in 0..<50 {
                if Delivery.confirmed(id, at: at) { print("confirmed"); return 0 }
                usleep(100_000)
            }
            print("not confirmed")
            return 2
        case .inbox(let msg):
            let start = Date().timeIntervalSince1970
            while true {
                switch Inbox.settle(thread: id, id: msg, waited: Date().timeIntervalSince1970 - start) {
                case .delivered:
                    print("delivered")
                    return 0
                case .failed(let why):
                    FileHandle.standardError.write(Data("\(why)\n".utf8))
                    return 1
                case .withdrawn:
                    FileHandle.standardError.write(Data("Amp didn't pick it up\n".utf8))
                    return 1
                case .unconfirmed:
                    print("not confirmed")
                    return 2
                case nil:
                    usleep(100_000)
                }
            }
        }
    }
}

extension Delivery {
    /// Slash and shell commands may skip UserPromptSubmit, so there is nothing to wait for.
    static func skipsConfirmation(_ text: String) -> Bool {
        let t = sanitize(text)
        return t.hasPrefix("/") || t.hasPrefix("!")
    }

    /// UserPromptSubmit stamped a prompt at or after the send started.
    static func confirmed(_ id: String, at: Double) -> Bool {
        (Store.read(id)?.lastPromptAt ?? 0) >= at
    }
}
