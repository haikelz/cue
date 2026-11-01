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
    /// What changed since `before` that deserves a notification: a turn that ended (finished_at moved),
    /// else a session that just started waiting on you. Esc and interrupts end a turn without
    /// finished_at, so they stay quiet.
    package func alert(since before: Session) -> Alert? {
        if let finishedAt, finishedAt != before.finishedAt {
            let first = lastMessage?.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            let failed = lastMessage == "Error" || lastMessage?.hasPrefix("API error") == true
            return failed ? .stopped(reason: first) : .finished(reply: first)
        }
        if status == .needsYou, before.status != .needsYou { return .needsYou }
        return nil
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
