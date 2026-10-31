import Foundation

/// The session files in ~/.cue/sessions (or $CUE_DIR), and the one lock around changing them.
package enum Store {
    package static let root: URL = ProcessInfo.processInfo.environment["CUE_DIR"].map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cue")
    package static let sessions = root.appendingPathComponent("sessions")

    /// Session ids become file names, so accept the UUID alphabet and nothing else.
    package static func validID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    package static func file(_ id: String) -> URL { sessions.appendingPathComponent(id + ".json") }

    package static func read(_ id: String) -> Session? {
        guard validID(id), let data = try? Data(contentsOf: file(id)) else { return nil }
        return try? decoder.decode(Session.self, from: data)
    }

    package static func all() -> [Session] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: sessions.path)) ?? []
        return names.filter { $0.hasSuffix(".json") }.compactMap { read(String($0.dropLast(5))) }
    }

    /// Temp file plus rename, so a reader never sees half a file.
    package static func write(_ s: Session) throws {
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let tmp = sessions.appendingPathComponent(".\(s.sessionId).\(getpid()).tmp")
        guard FileManager.default.createFile(atPath: tmp.path, contents: try encoder.encode(s),
                                             attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard rename(tmp.path, file(s.sessionId).path) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    }

    package static func delete(_ id: String) {
        guard validID(id) else { return }
        try? FileManager.default.removeItem(at: file(id))
    }

    /// One lock for every session.
    /// ponytail: global lock; hook runs take ~1 ms, so contention stays invisible below hundreds of sessions.
    package static func locked<T>(_ body: () throws -> T) throws -> T {
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
package struct Config: Codable {
    package var codex: String?
    package var tmux: String?
    package var path: String?

    package static func load() -> Config {
        guard let data = try? Data(contentsOf: Store.root.appendingPathComponent("config.json")),
              let c = try? JSONDecoder().decode(Config.self, from: data) else { return Config() }
        return c
    }
}
