import Foundation

/// Codex specifics: which sessions are interactive, sending through `codex queue`, and whether Codex
/// runs Cue's hooks.
package enum Codex {
    /// `codex queue` hands the prompt to Codex's daemon, which runs it now or after the current turn.
    /// The `=` forms keep a prompt that starts with "-" from parsing as a flag.
    static func queue(_ s: Session, _ text: String) -> Outcome {
        let config = Config.load()
        guard let codex = config.codex, FileManager.default.isExecutableFile(atPath: codex) else {
            return .refused("Cue doesn't know where codex is; run install.sh again")
        }
        guard s.sessionId.range(of: #"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"#, options: .regularExpression) != nil else {
            return .refused("Not a Codex session id")
        }
        var env = ProcessInfo.processInfo.environment
        if let path = config.path { env["PATH"] = path }
        do {
            _ = try Command.run(codex, ["queue", "--thread=\(s.sessionId)", "--message=\(text)"], env: env, timeout: 30)
        } catch {
            return .failed("codex queue: \(error.message)")
        }
        // Exit 0 means Codex accepted the prompt. Waiting for UserPromptSubmit on top of that could only
        // turn a slow start into "Not confirmed" and invite a second, duplicate send.
        return .accepted(s.status == .idle ? "Sent" : "Queued")
    }

    /// Cue's hook command as install.sh writes it into ~/.codex/hooks.json.
    package static func command(exe: String) -> String {
        "'" + exe.replacingOccurrences(of: "'", with: "'\\''") + "' hook codex"
    }

    package struct ListedHook: Decodable, Sendable { let command: String?; let enabled: Bool?; let trustStatus: String? }

    /// A JSON-RPC message from `codex app-server`; the `hooks/list` answer carries hooks grouped by folder.
    private struct Reply: Decodable {
        let id: Int?
        let result: Listing?
        struct Listing: Decodable { let data: [Group] }
        struct Group: Decodable { let hooks: [ListedHook] }
    }

    /// The footer's warning about Cue's Codex hooks, or nil. Pure, so the tests can call it.
    package static func warning(_ hooks: [ListedHook], command: String) -> String? {
        let mine = hooks.filter { $0.command == command }
        if mine.count < 7 { return "Cue's Codex hooks are missing: run ./install.sh" }
        if mine.contains(where: { $0.trustStatus != "trusted" || $0.enabled == false }) {
            return "Codex hooks need review: run /hooks in Codex"
        }
        return nil
    }

    /// Asks Codex which hooks it will run: `codex app-server` answers `hooks/list` with each hook's
    /// trust status (Codex keys trust by list position, so another tool reordering hooks.json can
    /// untrust Cue's). Nil when Codex isn't set up, answers with an error, or says nothing within 10 s;
    /// the API is experimental.
    package static func listHooks() -> [ListedHook]? {
        let config = Config.load()
        guard let codex = config.codex, FileManager.default.isExecutableFile(atPath: codex) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: codex)
        p.arguments = ["app-server"]
        var env = ProcessInfo.processInfo.environment
        if let path = config.path { env["PATH"] = path }
        p.environment = env
        p.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        let input = Pipe(), output = Pipe()
        p.standardInput = input
        p.standardOutput = output
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        defer { if p.isRunning { p.terminate() } }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let requests: [[String: Any]] = [
            ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["clientInfo": ["name": "cue", "version": version]]],
            ["jsonrpc": "2.0", "method": "initialized"],
            ["jsonrpc": "2.0", "id": 2, "method": "hooks/list", "params": [String: Any]()],
        ]
        let lines = requests.compactMap { try? JSONSerialization.data(withJSONObject: $0) }.map { $0 + Data("\n".utf8) }
        try? input.fileHandleForWriting.write(contentsOf: lines.reduce(Data(), +))
        // poll() with a deadline, not a blocking read: a wrapper script that doesn't pass SIGTERM on would
        // leave the real app-server holding stdout open, and a blocking read would wait forever.
        let fd = output.fileHandleForReading.fileDescriptor
        let deadline = Date().addingTimeInterval(10)
        var buffer = Data(), chunk = [UInt8](repeating: 0, count: 65_536)
        while true {
            var ready = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let left = Int32(deadline.timeIntervalSinceNow * 1000)
            guard left > 0, poll(&ready, 1, left) > 0 else { return nil }
            let n = read(fd, &chunk, chunk.count)
            guard n > 0 else { return nil }  // Codex exited
            buffer.append(contentsOf: chunk[..<n])
            while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = Data(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
                guard let reply = try? JSONDecoder().decode(Reply.self, from: line), reply.id == 2 else { continue }
                return reply.result?.data.flatMap(\.hooks)  // an error reply has no result: stay quiet
            }
        }
    }

    /// Codex also fires hooks for `codex exec`, other clients, and its own background sessions (memory
    /// upkeep, for one), which have no rollout at all. A rollout's first line names its originator; rows
    /// are for the interactive TUI. A rollout path whose file isn't written yet counts as interactive.
    static func interactive(_ rollout: String?) -> Bool {
        guard let rollout else { return false }
        guard let h = FileHandle(forReadingAtPath: rollout) else { return true }
        defer { try? h.close() }
        guard let line = h.readData(ofLength: 65_536).split(separator: UInt8(ascii: "\n")).first,
              let entry = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
              let originator = (entry["payload"] as? [String: Any])?["originator"] as? String
        else { return true }
        return originator == "codex-tui"
    }
}

extension Codex {
    /// Codex runs every thread in its shared daemon and records no terminal for one, so Open looks for
    /// the Codex showing this session: one started with its id (`codex resume <id>`), else the one in
    /// its folder. That process's environment names its tmux pane, WezTerm pane or kitty window, read
    /// the way the Claude hook reads its own; an iTerm2 tab is found by tty, which an inherited
    /// ITERM_SESSION_ID can't fool. Two Codex sessions in one folder can't be told apart, so Open
    /// refuses there. A thread resumed in another folder's Codex can bring that one forward.
    static func open(_ s: Session) throws(DeliveryError) -> [AppRef] {
        // The daemons have no tty. The kernel names a process after its binary, cut to 16 characters.
        let tuis = Proc.all().filter { $0.name.hasPrefix("codex") && $0.tty != nil && $0.tpgid == $0.pgid }
        let named = tuis.filter { $0.launch.args.contains(s.sessionId) }
        let folder = resolved(s.cwd)
        let here = named.isEmpty ? tuis.filter { $0.cwd.map(resolved) == folder } : named
        let ttys = Set(here.compactMap(\.tty))
        guard ttys.count == 1, let tui = here.first, let tty = tui.tty else {
            throw .refused(ttys.isEmpty ? "No Codex is running in \(s.project)" : "\(ttys.count) Codex sessions run in \(s.project); Open can't tell them apart")
        }
        var found = s
        found.setTerminal(from: tui.launch.env)
        if found.itermSessionId == nil, let terminal = found.terminal { return try terminal.open() }
        guard let apps = apps(above: tui.pid, tty: tty) else { throw .closed("Codex has quit") }
        return apps
    }

    private static func resolved(_ path: String) -> String {
        guard let real = realpath(path, nil) else { return path }
        defer { free(real) }
        return String(cString: real)
    }
}
