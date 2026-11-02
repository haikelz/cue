@testable import CueCore
import Foundation
import Testing

/// Sessions, agents and statuses: identity, liveness, and the rules that differ between agents.
@Suite struct SessionTests {
    let tab = "64017D0C-B0FE-457C-A404-FFB5514233B0"

    func session(_ agent: Agent, status: Status = .idle) -> Session {
        Session(sessionId: "s", agent: agent, cwd: "/Users/me/api", status: status, updatedAt: 0)
    }

    @Test func agentRules() {
        #expect(!Agent.claude.queuesWhileBusy && Agent.codex.queuesWhileBusy && Agent.amp.queuesWhileBusy)
        #expect(Agent.claude.canOpen && !Agent.codex.canOpen && Agent.amp.canOpen)
        #expect([Agent.claude, .codex, .amp].map(\.name) == ["Claude", "Codex", "Amp"])
    }

    @Test func theShellsEnvironmentNamesItsTerminal() {
        func place(_ env: [String: String]) -> [String?] {
            var s = session(.claude)
            s.itermSessionId = "old"  // a previous event's terminal is forgotten
            s.setTerminal(from: env)
            return [s.tmuxSocket, s.tmuxPane, s.weztermSocket, s.weztermPane, s.kittySocket, s.kittyWindow, s.itermSessionId]
        }
        let iterm = ["ITERM_SESSION_ID": "w0t1p0:ABC", "TERM_PROGRAM": "iTerm.app"]
        #expect(place(iterm) == [nil, nil, nil, nil, nil, nil, "ABC"])
        #expect(place(iterm.merging(["TMUX": "/tmp/tmux-501/default,42,0", "TMUX_PANE": "%3"]) { $1 })
                == ["/tmp/tmux-501/default", "%3", nil, nil, nil, nil, nil])
        // WezTerm or kitty started from an iTerm2 shell keeps its ITERM_SESSION_ID.
        #expect(place(iterm.merging(["TERM_PROGRAM": "WezTerm", "WEZTERM_PANE": "4", "WEZTERM_UNIX_SOCKET": "/u/gui-sock-9"]) { $1 })
                == [nil, nil, "/u/gui-sock-9", "4", nil, nil, nil])
        #expect(place(iterm.merging(["KITTY_WINDOW_ID": "2", "KITTY_LISTEN_ON": "unix:/tmp/kitty-77"]) { $1 })
                == [nil, nil, nil, nil, "unix:/tmp/kitty-77", "2", nil])
        // kitty started from a WezTerm shell keeps WezTerm's TERM_PROGRAM and pane; its TERM is its own.
        let wezterm = ["TERM_PROGRAM": "WezTerm", "WEZTERM_PANE": "4", "WEZTERM_UNIX_SOCKET": "/u/gui-sock-9", "TERM": "xterm-256color"]
        #expect(place(wezterm.merging(["KITTY_WINDOW_ID": "2", "KITTY_LISTEN_ON": "unix:/tmp/kitty-77", "TERM": "xterm-kitty"]) { $1 })
                == [nil, nil, nil, nil, "unix:/tmp/kitty-77", "2", nil])
        // kitty without listen_on, or listening on TCP: the window is known, typing isn't possible.
        #expect(place(["KITTY_WINDOW_ID": "2"]) == [nil, nil, nil, nil, nil, "2", nil])
        #expect(place(["KITTY_WINDOW_ID": "2", "KITTY_LISTEN_ON": "tcp:10.0.0.5:9000"]) == [nil, nil, nil, nil, nil, "2", nil])
        #expect(place(["TERM_PROGRAM": "WezTerm", "WEZTERM_PANE": "4;rm", "WEZTERM_UNIX_SOCKET": "/u/s"]) == [nil, nil, nil, nil, nil, nil, nil])
        #expect(place(["TMUX": "/tmp/tmux-501/default,42,0", "TMUX_PANE": "%3;kill"]) == [nil, nil, nil, nil, nil, nil, nil])
    }

    @Test func aKittyWindowWithoutRemoteControlIsReadOnly() {
        var s = session(.claude)
        s.tty = "/dev/ttys001"
        s.setTerminal(from: ["KITTY_WINDOW_ID": "2"])
        #expect(!s.deliverable)
        s.setTerminal(from: ["KITTY_WINDOW_ID": "2", "KITTY_LISTEN_ON": "unix:/tmp/kitty-77"])
        #expect(s.deliverable)
    }

    @Test func statusOrderPutsNeedsYouFirst() {
        #expect([Status.working, .idle, .needsYou].sorted { $0.rank < $1.rank } == [.needsYou, .idle, .working])
    }

    @Test func statusKeepsTheFileFormat() throws {
        #expect(Status.needsYou.rawValue == "needs_you")
        var s = session(.claude, status: .needsYou)
        s.itermSessionId = tab
        let decoded = try JSONDecoder().decode(Session.self, from: JSONEncoder().encode(s))
        #expect(decoded == s)
    }

    @Test func claudeRowsKeyByTabOrPane() {
        var s = session(.claude)
        s.itermSessionId = tab
        #expect(s.rowKey == tab)
        s.itermSessionId = nil
        s.tmuxSocket = "/tmp/tmux-501/default"
        s.tmuxPane = "%3"
        #expect(s.rowKey == "/tmp/tmux-501/default%3")
    }

    @Test func ampRowsKeyByThread() {
        var s = session(.amp)
        s.itermSessionId = tab
        #expect(s.rowKey == "s")
    }

    @Test func claudeNeedsATerminalToTakePrompts() {
        var s = session(.claude)
        s.tty = "/dev/ttys009"
        #expect(!s.deliverable && s.terminal == nil)
        s.tmuxSocket = "/tmp/tmux-501/default"
        s.tmuxPane = "%3"
        #expect(s.deliverable && s.terminal is TmuxPane)
        s.tmuxPane = nil
        s.itermSessionId = tab
        #expect(s.deliverable && s.terminal is ITermTab)
        #expect(session(.codex).deliverable)
    }

    @Test func ampLivesWhileItsPluginBeats() {
        var s = session(.amp)
        s.heartbeat = Date().timeIntervalSince1970 - 10
        #expect(s.isAlive && !s.isExpired)
        s.heartbeat = Date().timeIntervalSince1970 - 60
        #expect(!s.isAlive && !s.isExpired)  // hidden, kept for a window that resumes
        s.heartbeat = Date().timeIntervalSince1970 - 4000
        #expect(s.isExpired)
    }

    @Test func codexExpiresAfterADayWithoutChange() {
        var s = session(.codex)
        s.updatedAt = Date().timeIntervalSince1970 - 3600
        #expect(s.isAlive)
        s.updatedAt = Date().timeIntervalSince1970 - 90_000
        #expect(s.isExpired)
    }

    @Test func claudeLivesWithItsProcess() {
        var s = session(.claude)
        #expect(s.isAlive)  // PID unknown: kept until SessionEnd
        let me = Proc(getpid())!
        s.pid = me.pid
        s.pidStart = me.start
        #expect(s.isAlive)
        s.pidStart = me.start - 100  // the PID now belongs to another process
        #expect(!s.isAlive)
    }

    @Test func sessionIdsAreFileSafe() {
        #expect(Store.validID("0a1b2c3d-0000-4000-8000-000000000001"))
        #expect(!Store.validID("../etc/passwd"))
        #expect(Inbox.validThread("T-01a18a06-d728-70de-8d1e-8cc150b0f6fc"))
        #expect(!Inbox.validThread("T-../../etc"))
    }

    /// A class, so deinit can remove the folder: swift-testing makes one instance per test.
    @Suite final class Interrupts {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cue-tests-\(UUID().uuidString)")

        deinit { try? FileManager.default.removeItem(at: dir) }
        let marker = #"{"type":"user","message":{"content":[{"type":"text","text":"[Request interrupted by user for tool use]"}]}}"#
        let meta = #"{"type":"permission-mode","permissionMode":"default"}"#
        let reply = #"{"type":"assistant","message":{"content":[{"type":"text","text":"Done."}]}}"#

        func transcript(_ lines: [String]) -> Session {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(UUID().uuidString + ".jsonl")
            try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
            return Session(sessionId: "t", agent: .claude, cwd: "/tmp", status: .working,
                           updatedAt: Date().timeIntervalSince1970 - 10, transcriptPath: url.path)
        }

        @Test func markerFollowedByMetadata() {
            #expect(transcript([reply, marker, meta, meta]).interrupted)
        }

        @Test func assistantReplyIsNotAnInterrupt() {
            #expect(!transcript([marker, reply, meta]).interrupted)
        }

        @Test func markerOlderThanTheLastHookEventIsIgnored() {
            var old = transcript([reply, marker])
            old.updatedAt = Date().timeIntervalSince1970 + 10
            #expect(!old.interrupted)
        }
    }
}
