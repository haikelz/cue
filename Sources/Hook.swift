import Foundation

/// `ClaudeRelay hook`: turns one Claude Code hook event (JSON on stdin) into a session file update.
/// Never fails the hook: any error goes to hook.log and the exit code stays 0.
enum Hook {
    static func run() -> Never {
        do {
            if let out = try handle(FileHandle.standardInput.readDataToEndOfFile()) {
                FileHandle.standardOutput.write(out)
            }
        } catch {
            log("\(error)")
        }
        exit(0)
    }

    /// Returns the bytes to print on stdout, if any.
    static func handle(_ data: Data) throws -> Data? {
        guard let input = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = input["hook_event_name"] as? String,
              let id = input["session_id"] as? String, Store.validID(id)
        else { throw HookError.badInput }
        if input["agent_id"] != nil { return nil }  // subagent events don't change the main session

        let wrote: Session? = try Store.locked {
            if event == "SessionEnd" {
                Store.delete(id)
                return nil
            }
            let old = Store.read(id)
            var s = old ?? Session(sessionId: id, cwd: "", status: "working", updatedAt: 0)
            let now = Date().timeIntervalSince1970
            switch event {
            case "SessionStart":
                // Compaction can run mid-turn; any other start (startup, resume, clear, fork) waits for input.
                if input["source"] as? String != "compact" { s.status = "idle" } else if old == nil { s.status = "working" }
            case "UserPromptSubmit":
                s.status = "working"
                s.lastPromptAt = now
            case "PostToolUse", "PostToolUseFailure", "ElicitationResult":
                if old?.status == "working" { return nil }  // hot path: no write while working
                s.status = "working"
            case "PermissionRequest", "Elicitation":
                s.status = "needs_you"
            case "Stop":
                s.status = "idle"
                s.lastMessage = (input["last_assistant_message"] as? String).map { String($0.prefix(500)) }
            case "StopFailure":
                s.status = "idle"
                s.lastMessage = "API error: \(input["error"] as? String ?? "unknown")"
            case "Notification":
                guard input["notification_type"] as? String == "idle_prompt", s.status == "working" else { return nil }
                s.status = "idle"
            default:
                return nil
            }
            s.cwd = input["cwd"] as? String ?? s.cwd
            s.transcriptPath = input["transcript_path"] as? String ?? s.transcriptPath
            let env = ProcessInfo.processInfo.environment
            // Inside tmux, ITERM_SESSION_ID is a stale copy from the tmux server, so drop it.
            s.itermSessionId = env["TMUX"] == nil ? env["ITERM_SESSION_ID"]?.split(separator: ":").last.map(String.init) : nil
            if let p = Proc.claude() {
                s.claudePid = p.pid
                s.claudeStart = p.start
                s.tty = p.tty
            }
            s.updatedAt = now
            try Store.write(s)
            return s
        }

        guard let s = wrote, event == "Stop" || event == "StopFailure" else { return nil }
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

enum HookError: Error { case badInput }
