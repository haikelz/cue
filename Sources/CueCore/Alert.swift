import Foundation

/// What a notification tells you about a session: its turn ended, or it started waiting on you.
package enum Alert: Equatable, Sendable {
    case finished(reply: String)   // the reply's first line
    case stopped(reason: String)   // the turn ended on an error
    case needsYou

    package func title(_ name: String) -> String {
        switch self {
        case .finished: "\(name) finished"
        case .stopped: "\(name) stopped"
        case .needsYou: "\(name) needs you"
        }
    }

    package var body: String {
        switch self {
        case .finished(let reply): reply.isEmpty ? "The turn ended." : String(reply.prefix(300))
        case .stopped(let reason): String(reason.prefix(300))
        case .needsYou: "A permission prompt or a question is waiting in the terminal."
        }
    }
}

extension Session {
    /// What changed since `before` that deserves a notification: a session that just started waiting on
    /// you, else a turn that ended (finished_at moved). Waiting comes first: when a turn ends and the
    /// next one stops at a prompt within one poll, you're needed. Esc and interrupts end a turn without
    /// finished_at, so they stay quiet.
    package func alert(since before: Session) -> Alert? {
        if status == .needsYou, before.status != .needsYou { return .needsYou }
        if let finishedAt, finishedAt != before.finishedAt {
            let first = lastMessage?.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            let failed = lastMessage == "Error" || lastMessage?.hasPrefix("API error") == true
            return failed ? .stopped(reason: first) : .finished(reply: first)
        }
        return nil
    }
}

/// Remembers how the last poll saw each session and reports what changed since. A session seen for the
/// first time, at launch or when it reappears, only sets the baseline, so Cue never replays old turns.
package struct AlertTracker {
    private var last: [String: Session] = [:]

    package init() {}

    package mutating func changes(in sessions: [Session]) -> [(session: Session, alert: Alert)] {
        var out: [(session: Session, alert: Alert)] = []
        for s in sessions {
            if let before = last[s.sessionId], let alert = s.alert(since: before) { out.append((s, alert)) }
            last[s.sessionId] = s
        }
        let ids = Set(sessions.map(\.sessionId))
        last = last.filter { ids.contains($0.key) }
        return out
    }
}

/// While the Cue app may post notifications, it keeps its process id in ~/.cue/notifier.pid. The hooks
/// and the Amp plugin then leave the "finished" banner to the app instead of writing OSC 9 to the
/// terminal, so a finished turn shows once.
package enum NotifierFile {
    static let url = Store.root.appendingPathComponent("notifier.pid")

    /// True while the process the file names runs and is Cue. A file left by a crash, or a process id
    /// reused since, falls back to the terminal banner.
    package static var isActive: Bool {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return false }
        return Proc(pid)?.name == "cue"
    }

    package static func claim() {
        try? FileManager.default.createDirectory(at: Store.root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        FileManager.default.createFile(atPath: url.path, contents: Data("\(getpid())\n".utf8), attributes: [.posixPermissions: 0o600])
    }

    /// Removes the file if it still names this process.
    package static func release() {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              text.trimmingCharacters(in: .whitespacesAndNewlines) == "\(getpid())" else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
