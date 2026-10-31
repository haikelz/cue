import Foundation

/// One agent session, as its hook or plugin last saw it. Stored as one JSON file per session.
struct Session: Codable, Equatable {
    var sessionId: String
    var agent: String  // "claude" | "codex" | "amp"
    var cwd: String
    var status: String  // "working" | "idle" | "needs_you"
    var lastMessage: String?
    var lastPromptAt: Double?
    var updatedAt: Double
    var pid: Int32?
    var pidStart: Double?
    var tty: String?
    var itermSessionId: String?
    var tmuxSocket: String?  // Claude inside tmux: the server's socket and the session's pane, typed into instead of iTerm2
    var tmuxPane: String?
    var transcriptPath: String?
    var turnId: String?     // Codex: the turn UserPromptSubmit started
    var heartbeat: Double?  // Amp: the plugin rewrites this every 5 s

    var isClaude: Bool { agent == "claude" }

    var agentName: String { ["claude": "Claude", "codex": "Codex", "amp": "Amp"][agent] ?? agent }

    /// Claude rows follow the iTerm2 tab or tmux pane, so a draft survives /clear starting a new session.
    /// Codex and Amp rows follow the session: several of their threads can share one tab.
    var rowKey: String { isClaude ? (itermSessionId ?? tmuxPane.map { (tmuxSocket ?? "") + $0 } ?? sessionId) : sessionId }

    /// Claude prompts are typed into an iTerm2 tab or a tmux pane; Codex and Amp take them through their own channels.
    var deliverable: Bool { !isClaude || tty != nil && (itermSessionId != nil || tmuxPane != nil) }

    var project: String { URL(fileURLWithPath: cwd).lastPathComponent }

    var transcriptModified: Double? {
        guard let path = transcriptPath else { return nil }
        return ((try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date)?.timeIntervalSince1970
    }

    /// Stop never fires after Esc or a denied permission; the transcript's last message is then
    /// Claude Code's "[Request interrupted by user…]" marker. Metadata entries may follow it.
    var interrupted: Bool {
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

enum Store {
    static let root: URL = ProcessInfo.processInfo.environment["CUE_DIR"].map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cue")
    static let sessions = root.appendingPathComponent("sessions")

    /// Session ids become file names, so accept the UUID alphabet and nothing else.
    static func validID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    static func file(_ id: String) -> URL { sessions.appendingPathComponent(id + ".json") }

    static func read(_ id: String) -> Session? {
        guard validID(id), let data = try? Data(contentsOf: file(id)) else { return nil }
        return try? decoder.decode(Session.self, from: data)
    }

    static func all() -> [Session] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: sessions.path)) ?? []
        return names.filter { $0.hasSuffix(".json") }.compactMap { read(String($0.dropLast(5))) }
    }

    /// Temp file plus rename, so a reader never sees half a file.
    static func write(_ s: Session) throws {
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let tmp = sessions.appendingPathComponent(".\(s.sessionId).\(getpid()).tmp")
        guard FileManager.default.createFile(atPath: tmp.path, contents: try encoder.encode(s),
                                             attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard rename(tmp.path, file(s.sessionId).path) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    }

    static func delete(_ id: String) {
        guard validID(id) else { return }
        try? FileManager.default.removeItem(at: file(id))
    }

    /// One lock for every session.
    /// ponytail: global lock; hook runs take ~1 ms, so contention stays invisible below hundreds of sessions.
    static func locked<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let fd = open(root.appendingPathComponent(".lock").path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        // Give up after ~0.5 s instead of hanging a hook or the app behind a stuck holder.
        for attempt in 0... {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 { break }
            guard attempt < 50 else { throw POSIXError(.EWOULDBLOCK) }
            usleep(10_000)
        }
        return try body()
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()
}

/// Written by install.sh: the absolute `codex` and `tmux` paths and the PATH of the shell that ran the install.
/// `codex queue` may start Codex's daemon, which inherits this PATH, so your hooks keep finding `node`.
struct Config: Codable {
    var codex: String?
    var tmux: String?
    var path: String?

    static func load() -> Config {
        guard let data = try? Data(contentsOf: Store.root.appendingPathComponent("config.json")),
              let c = try? JSONDecoder().decode(Config.self, from: data) else { return Config() }
        return c
    }
}

/// Process facts from the kernel, read with sysctl.
struct Proc {
    let pid: pid_t, ppid: pid_t, pgid: pid_t, tpgid: pid_t
    let stopped: Bool
    let start: Double
    let tty: String?
    let name: String

    init?(_ pid: pid_t) {
        var kp = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard pid > 0, sysctl(&mib, 4, &kp, &size, nil, 0) == 0, size > 0 else { return nil }
        self.pid = pid
        ppid = kp.kp_eproc.e_ppid
        pgid = kp.kp_eproc.e_pgid
        tpgid = kp.kp_eproc.e_tpgid
        stopped = kp.kp_proc.p_stat == CChar(SSTOP)
        start = Double(kp.kp_proc.p_starttime.tv_sec) + Double(kp.kp_proc.p_starttime.tv_usec) / 1e6
        let dev = kp.kp_eproc.e_tdev
        tty = dev == -1 ? nil : devname(dev, S_IFCHR).map { "/dev/" + String(cString: $0) }
        name = withUnsafeBytes(of: kp.kp_proc.p_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    /// The Claude Code process above this hook. Hooks run as claude -> hook, or claude -> sh -> hook.
    static func claude() -> Proc? {
        var pid = getppid()
        for _ in 0..<6 {
            guard let p = Proc(pid) else { return nil }
            if p.name == "claude" { return p }
            pid = p.ppid
        }
        return nil
    }
}
