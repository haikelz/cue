import CueCore
import Foundation
import Observation

/// Keeps `sessions` in step with the session files: loads them every second, deletes the ones whose
/// session ended, and repairs Claude rows that no hook event will fix. When the popover opens, it also
/// checks that the agents are wired to Cue and that Codex runs Cue's hooks.
@MainActor @Observable
final class SessionMonitor {
    private(set) var sessions: [Session] = []
    private(set) var hooksInstalled = false
    private(set) var codexWarning: String?
    @ObservationIgnored private let worker: Worker
    /// The Codex check takes a second or two, so it gets its own queue and never delays a send.
    @ObservationIgnored private let codexWorker = Worker("cue.codex", qos: .utility)
    @ObservationIgnored private var probing: Set<String> = []
    @ObservationIgnored private var codexStamp: [Double]?
    @ObservationIgnored private var checkingCodex = false

    init(worker: Worker) {
        self.worker = worker
        reload()
    }

    func reload() {
        var live: [Session] = []
        for var s in Store.all() {
            if s.isExpired {
                // Claude exited without SessionEnd (tab closed, crash), or a session went quiet for good.
                // Re-check under the lock, so a resumed session that just rewrote this file keeps it.
                _ = try? Store.locked { if let fresh = Store.read(s.sessionId), fresh.isExpired { Store.delete(s.sessionId) } }
                continue
            }
            if !s.isAlive { continue }  // hidden, not deleted: an Amp window that stopped beating may resume
            if s.agent == .claude, s.status != .idle, s.interrupted { s = setIdle(s) { $0.status != .idle && $0.interrupted } }
            live.append(s)
        }
        if live != sessions { sessions = live }
    }

    /// Runs when the popover opens.
    func refresh() {
        hooksInstalled = Self.hooksPresent()
        checkCodexHooks()
        recheckStale()
    }

    /// A Claude row quiet at working for 15 s gets one look at its screen. Catches Esc pressed before
    /// Claude wrote anything, which leaves no hook event and no transcript marker.
    private func recheckStale() {
        let now = Date().timeIntervalSince1970
        for s in sessions where s.agent == .claude && s.deliverable && s.status == .working && !probing.contains(s.sessionId)
            && now - max(s.updatedAt, s.transcriptModified ?? 0) > 15 {
            probing.insert(s.sessionId)
            Task {
                let idle = await worker.run { Delivery.looksIdle(s) }
                probing.remove(s.sessionId)
                guard idle else { return }
                _ = setIdle(s) { $0.status == .working && $0.updatedAt == s.updatedAt }
                reload()
            }
        }
    }

    /// Esc or a denied permission leaves no Stop event, so the app sets idle itself when `stillTrue`
    /// holds for the file as it reads under the lock.
    private func setIdle(_ s: Session, if stillTrue: (Session) -> Bool) -> Session {
        (try? Store.locked { () -> Session in
            guard var fresh = Store.read(s.sessionId) else { return s }
            guard stillTrue(fresh) else { return fresh }
            fresh.status = .idle
            fresh.updatedAt = Date().timeIntervalSince1970
            try Store.write(fresh)
            return fresh
        }) ?? s
    }

    /// Asks Codex whether it trusts Cue's hooks, when hooks.json or config.toml changed since the last answer.
    private func checkCodexHooks() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let stamp = [".codex/hooks.json", ".codex/config.toml"].map {
            ((try? FileManager.default.attributesOfItem(atPath: home.appendingPathComponent($0).path))?[.modificationDate] as? Date)?
                .timeIntervalSince1970 ?? 0
        }
        guard stamp != codexStamp, !checkingCodex, let exe = Bundle.main.executablePath else { return }
        checkingCodex = true
        Task {
            let hooks = await codexWorker.run { Codex.listHooks() }
            checkingCodex = false
            guard let hooks else { return }  // no answer: stay quiet, ask again next time
            codexStamp = stamp
            codexWarning = Codex.warning(hooks, command: Codex.command(exe: exe))
        }
    }

    /// True when any agent is wired to this app: Claude Code or Codex hooks, or the Amp plugin.
    static func hooksPresent() -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        guard let exe = Bundle.main.executablePath else { return false }
        let wired = [".claude/settings.json", ".codex/hooks.json"].contains {
            (try? String(contentsOf: home.appendingPathComponent($0), encoding: .utf8))?.contains(exe) == true
        }
        return wired || FileManager.default.fileExists(atPath: home.appendingPathComponent(".config/amp/plugins/cue.ts").path)
    }
}
