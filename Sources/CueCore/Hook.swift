import Foundation

/// `cue hook claude` and `cue hook codex`: turn one hook event (JSON on stdin) into a session file update.
/// Never fails the hook: any error goes to hook.log. Codex expects JSON on stdout, so it always gets some.
package enum Hook {
    package static func run(_ name: String) -> Never {
        var out: Data?
        do {
            guard let agent = Agent(rawValue: name), agent.usesHooks else { throw HookError.unknownAgent }
            out = try handle(FileHandle.standardInput.readDataToEndOfFile(), agent: agent)
        } catch {
            log("\(name): \(error)")
        }
        if let out { FileHandle.standardOutput.write(out) } else if name == "codex" { FileHandle.standardOutput.write(Data("{}".utf8)) }
        exit(0)
    }

    /// Returns the bytes to print on stdout, if any.
    static func handle(_ data: Data, agent: Agent) throws -> Data? {
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
            var s = old ?? Session(sessionId: id, agent: agent, cwd: "", status: .working, updatedAt: 0)
            let now = Date().timeIntervalSince1970
            let turn = input["turn_id"] as? String
            // Codex subagents report under the parent's session id. Once idle, events from another turn are theirs.
            let foreignTurn = agent == .codex && s.status == .idle && turn != nil && turn != s.turnId
            switch event {
            case "SessionStart":
                // Compaction can run mid-turn; any other start (startup, resume, clear, fork) waits for input.
                if input["source"] as? String != "compact" { s.status = .idle } else if old == nil { s.status = .working }

            case "UserPromptSubmit":
                s.status = .working
                s.lastPromptAt = now
                s.turnId = turn
            case "PostToolUse", "PostToolUseFailure", "ElicitationResult":
                if old?.status == .working || foreignTurn { return nil }  // hot path: no write while working
                s.status = .working
            case "PermissionRequest", "Elicitation":
                if foreignTurn { return nil }
                s.status = .needsYou
            case "Stop":
                s.status = .idle
                s.lastMessage = (input["last_assistant_message"] as? String).map { String($0.prefix(4000)) }
                s.finishedAt = now
            case "StopFailure":
                s.status = .idle
                s.lastMessage = "API error: \(input["error"] as? String ?? "unknown")"
                s.finishedAt = now
            case "Interrupt":
                if let turn, let current = s.turnId, turn != current { return nil }  // a late Esc for an earlier turn
                s.status = .idle
            case "Notification":
                guard input["notification_type"] as? String == "idle_prompt", s.status == .working else { return nil }
                s.status = .idle
            default:
                return nil
            }
            s.cwd = input["cwd"] as? String ?? s.cwd
            s.transcriptPath = input["transcript_path"] as? String ?? s.transcriptPath
            if agent == .claude {
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
            if agent == .codex, !Codex.interactive(s.transcriptPath) {
                Store.delete(id)
                return nil
            }
            if agent == .codex, old == nil, event == "SessionStart" {
                // /clear, /new and /resume start a new Codex session in the same TUI. Without this, the old
                // thread's row stays sendable for 30 minutes and a prompt would run in a thread nobody sees.
                for o in Store.all() where o.agent == .codex && o.sessionId != id && o.cwd == s.cwd && o.status == .idle {
                    Store.delete(o.sessionId)
                }
            }
            s.updatedAt = now
            try Store.write(s)
            return s
        }

        guard agent == .claude, let s = wrote, event == "Stop" || event == "StopFailure" else { return nil }
        let detail = s.lastMessage?.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let verb = event == "Stop" ? "finished" : "stopped"
        return try notification("\(s.project) \(verb): \(detail)")
    }

    /// Claude Code writes `terminalSequence` to the terminal for us; iTerm2 turns OSC 9 into a notification.
    static func notification(_ text: String) throws -> Data {
        let clean = String(String.UnicodeScalarView(text.unicodeScalars.filter { $0.value >= 0x20 && !(0x7F...0x9F).contains($0.value) }))
        let seq = "\u{1B}]9;\(clean.prefix(180))\u{07}"
        return try JSONSerialization.data(withJSONObject: ["terminalSequence": seq])
    }

    static func log(_ message: String) {
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
