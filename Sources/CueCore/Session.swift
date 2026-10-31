import Foundation

/// The coding agents Cue knows, and the rules that differ between them. Adding an agent starts here:
/// the compiler then points at every switch that needs a case for it.
package enum Agent: String, Codable, Sendable {
    case claude, codex, amp

    package var name: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .amp: "Amp"
        }
    }

    /// Codex and Amp hold a prompt until the running turn ends; typing into Claude's terminal needs it idle.
    package var queuesWhileBusy: Bool { self != .claude }

    /// Codex hooks run in its shared daemon, so a Codex session's terminal is unknown.
    package var canOpen: Bool { self != .codex }

    /// How much of the session id tells two rows of one agent in one folder apart.
    package var idPrefix: Int { self == .amp ? 6 : 4 }
}

/// A session's state as its hooks or plugin report it. The raw values are the session file's.
package enum Status: String, Codable, Sendable {
    case working, idle
    case needsYou = "needs_you"

    /// The popover's order: sessions that need you, then idle ones, then working ones.
    package var rank: Int {
        switch self {
        case .needsYou: 0
        case .idle: 1
        case .working: 2
        }
    }
}

/// One agent session, as its hook or plugin last saw it. Stored as one JSON file per session.
package struct Session: Codable, Equatable, Sendable {
    package var sessionId: String
    package var agent: Agent
    package var cwd: String
    package var status: Status
    package var lastMessage: String?
    package var lastPromptAt: Double?
    package var updatedAt: Double
    package var pid: Int32?
    package var pidStart: Double?
    package var tty: String?
    package var itermSessionId: String?
    package var tmuxSocket: String?  // Claude inside tmux: the server's socket and the session's pane, typed into instead of iTerm2
    package var tmuxPane: String?
    package var transcriptPath: String?
    package var turnId: String?     // Codex: the turn UserPromptSubmit started
    package var heartbeat: Double?  // Amp: the plugin rewrites this every 5 s

    /// Claude rows follow the iTerm2 tab or tmux pane, so a draft survives /clear starting a new session.
    /// Codex and Amp rows follow the session: several of their threads can share one tab.
    package var rowKey: String { agent == .claude ? (itermSessionId ?? tmuxPane.map { (tmuxSocket ?? "") + $0 } ?? sessionId) : sessionId }

    /// Claude prompts are typed into an iTerm2 tab or a tmux pane; Codex and Amp take them through their own channels.
    package var deliverable: Bool { agent != .claude || tty != nil && (itermSessionId != nil || tmuxPane != nil) }

    /// Whether the session still runs. A Claude session lives as long as its process; Codex sends
    /// SessionEnd once a thread sits unopened for 30 minutes, and a day without any change covers one
    /// lost to a crash or reboot; an Amp thread lives while its plugin beats (Amp quit or switched threads).
    package var isAlive: Bool {
        let now = Date().timeIntervalSince1970
        switch agent {
        case .claude:
            guard let pid, let pidStart else { return true }  // PID unknown: keep until SessionEnd
            return Proc(pid).map { abs($0.start - pidStart) < 0.01 } ?? false
        case .codex:
            return now - max(updatedAt, transcriptModified ?? 0) < 86_400
        case .amp:
            return now - (heartbeat ?? 0) < 30
        }
    }

    /// Whether the session file can go. Amp files outlive a stopped heartbeat by an hour, so the app
    /// never races a plugin that resumes; a hidden Amp row comes back when its window beats again.
    package var isExpired: Bool {
        agent == .amp ? Date().timeIntervalSince1970 - (heartbeat ?? 0) > 3600 : !isAlive
    }

    package var project: String { URL(fileURLWithPath: cwd).lastPathComponent }

    package var transcriptModified: Double? {
        guard let path = transcriptPath else { return nil }
        return ((try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date)?.timeIntervalSince1970
    }

    /// Stop never fires after Esc or a denied permission; the transcript's last message is then
    /// Claude Code's "[Request interrupted by user…]" marker. Metadata entries may follow it.
    package var interrupted: Bool {
        // The marker counts only if written after our last hook event. Otherwise a new prompt's
        // UserPromptSubmit, which lands before the transcript catches up, would read as idle.
        guard let path = transcriptPath, let modified = transcriptModified, modified > updatedAt,
              let h = FileHandle(forReadingAtPath: path)
        else { return false }
        defer { try? h.close() }
        let end = h.seekToEndOfFile()
        h.seek(toFileOffset: end > 65_536 ? end - 65_536 : 0)
        for line in h.readDataToEndOfFile().split(separator: UInt8(ascii: "\n")).reversed() {
            guard let entry = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let type = entry["type"] as? String, type == "user" || type == "assistant"
            else { continue }
            let content = (entry["message"] as? [String: Any])?["content"]
            let text = (content as? String) ?? ((content as? [[String: Any]])?.first?["text"] as? String) ?? ""
            return type == "user" && text.hasPrefix("[Request interrupted by user")
        }
        return false
    }
}
