import Foundation

/// `cue hook claude` and `cue hook codex`: turn one hook event (JSON on stdin) into a session file update.
/// Never fails the hook: any error goes to hook.log. Codex expects JSON on stdout, so it always gets some.
package enum Hook {
    package static func run(_ agent: String) -> Never {
        var out: Data?
        do {
            out = try handle(FileHandle.standardInput.readDataToEndOfFile(), agent: agent)
        } catch {
            log("\(agent): \(error)")
        }
        if let out { FileHandle.standardOutput.write(out) } else if agent == "codex" { FileHandle.standardOutput.write(Data("{}".utf8)) }
        exit(0)
    }

    /// Returns the bytes to print on stdout, if any.
    package static func handle(_ data: Data, agent: String) throws -> Data? {
        guard agent == "claude" || agent == "codex" else { throw HookError.unknownAgent }
        guard let input = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = input["hook_event_name"] as? String,
              let id = input["session_id"] as? String, Store.validID(id)
        else { throw HookError.badInput }
        if input["agent_id"] != nil { return nil }  // Claude subagent events don't change the main session

        let wrote: Session? = try Store.locked {
            if event == "SessionEnd" {
                Store.delete(id)
                return nil
            }
            let old = Store.read(id)
            var s = old ?? Session(sessionId: id, agent: agent, cwd: "", status: "working", updatedAt: 0)
            let now = Date().timeIntervalSince1970
            let turn = input["turn_id"] as? String
            // Codex subagents report under the parent's session id. Once idle, events from another turn are theirs.
            let foreignTurn = agent == "codex" && s.status == "idle" && turn != nil && turn != s.turnId
            switch event {
            case "SessionStart":
                // Compaction can run mid-turn; any other start (startup, resume, clear, fork) waits for input.
                if input["source"] as? String != "compact" { s.status = "idle" } else if old == nil { s.status = "working" }

            case "UserPromptSubmit":
                s.status = "working"
                s.lastPromptAt = now
                s.turnId = turn
            case "PostToolUse", "PostToolUseFailure", "ElicitationResult":
                if old?.status == "working" || foreignTurn { return nil }  // hot path: no write while working
                s.status = "working"
            case "PermissionRequest", "Elicitation":
                if foreignTurn { return nil }
                s.status = "needs_you"
            case "Stop":
                s.status = "idle"
                s.lastMessage = (input["last_assistant_message"] as? String).map { String($0.prefix(4000)) }
            case "StopFailure":
                s.status = "idle"
                s.lastMessage = "API error: \(input["error"] as? String ?? "unknown")"
            case "Interrupt":
                if let turn, let current = s.turnId, turn != current { return nil }  // a late Esc for an earlier turn
                s.status = "idle"
            case "Notification":
                guard input["notification_type"] as? String == "idle_prompt", s.status == "working" else { return nil }
                s.status = "idle"
            default:
                return nil
            }
            s.cwd = input["cwd"] as? String ?? s.cwd
            s.transcriptPath = input["transcript_path"] as? String ?? s.transcriptPath
            if agent == "claude" {
                // Codex hooks run in its shared daemon, whose environment and process tree say nothing
                // about the session's tab. Claude hooks run under the session's own claude process.
                let env = ProcessInfo.processInfo.environment
                if let tmux = env["TMUX"] {
                    // $TMUX is "<socket>,<server pid>,<session>". ITERM_SESSION_ID in here is a stale copy from
                    // whichever tab started the tmux server, so the pane is the only target.
                    let socket = tmux.split(separator: ",", omittingEmptySubsequences: false).dropLast(2).joined(separator: ",")
                    let pane = env["TMUX_PANE"] ?? ""
                    let ok = socket.hasPrefix("/") && pane.range(of: #"^%[0-9]+$"#, options: .regularExpression) != nil
                    s.tmuxSocket = ok ? socket : nil
                    s.tmuxPane = ok ? pane : nil
                    s.itermSessionId = nil
                } else {
                    s.itermSessionId = env["ITERM_SESSION_ID"]?.split(separator: ":").last.map(String.init)
                    s.tmuxSocket = nil
                    s.tmuxPane = nil
                }
                if let p = Proc.claude() {
                    s.pid = p.pid
                    s.pidStart = p.start
                    s.tty = p.tty
                }
            }
            // Codex writes the rollout lazily, so the originator may show up only on a later write.
            if agent == "codex", !Codex.interactive(s.transcriptPath) {
                Store.delete(id)
                return nil
            }
            if agent == "codex", old == nil, event == "SessionStart" {
                // /clear, /new and /resume start a new Codex session in the same TUI. Without this, the old
                // thread's row stays sendable for 30 minutes and a prompt would run in a thread nobody sees.
                for o in Store.all() where o.agent == "codex" && o.sessionId != id && o.cwd == s.cwd && o.status == "idle" {
                    Store.delete(o.sessionId)
                }
            }
            s.updatedAt = now
            try Store.write(s)
            return s
        }

        guard agent == "claude", let s = wrote, event == "Stop" || event == "StopFailure" else { return nil }
        let detail = s.lastMessage?.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let verb = event == "Stop" ? "finished" : "stopped"
        return try notification("\(s.project) \(verb): \(detail)")
    }

    /// Claude Code writes `terminalSequence` to the terminal for us; iTerm2 turns OSC 9 into a notification.
    package static func notification(_ text: String) throws -> Data {
        let clean = String(String.UnicodeScalarView(text.unicodeScalars.filter { $0.value >= 0x20 && !(0x7F...0x9F).contains($0.value) }))
        let seq = "\u{1B}]9;\(clean.prefix(180))\u{07}"
        return try JSONSerialization.data(withJSONObject: ["terminalSequence": seq])
    }

    package static func log(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        let url = Store.root.appendingPathComponent("hook.log")
        try? FileManager.default.createDirectory(at: Store.root, withIntermediateDirectories: true)
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(Data(line.utf8))
            try? h.close()
        } else {
            FileManager.default.createFile(atPath: url.path, contents: Data(line.utf8), attributes: [.posixPermissions: 0o600])
        }
    }
}

package enum HookError: Error { case badInput, unknownAgent }

package enum Codex {
    /// Cue's hook command as install.sh writes it into ~/.codex/hooks.json.
    package static func command(exe: String) -> String {
        "'" + exe.replacingOccurrences(of: "'", with: "'\\''") + "' hook codex"
    }

    package struct ListedHook: Decodable { let command: String?; let enabled: Bool?; let trustStatus: String? }

    /// A JSON-RPC message from `codex app-server`; the `hooks/list` answer carries hooks grouped by folder.
    private struct Reply: Decodable {
        let id: Int?
        let result: Listing?
        struct Listing: Decodable { let data: [Group] }
        struct Group: Decodable { let hooks: [ListedHook] }
    }

    /// The footer's warning about Cue's Codex hooks, or nil. Pure, for the selftest.
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
        let requests = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"cue","version":"0.3.0"}}}"#,
            #"{"jsonrpc":"2.0","method":"initialized"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"hooks/list","params":{}}"#,
        ]
        try? input.fileHandleForWriting.write(contentsOf: Data((requests.joined(separator: "\n") + "\n").utf8))
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
    package static func interactive(_ rollout: String?) -> Bool {
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
