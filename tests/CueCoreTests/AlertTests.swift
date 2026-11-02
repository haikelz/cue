@testable import CueCore
import Foundation
import Testing

/// Which session changes post a notification, and what it says.
@Suite struct AlertTests {
    let working = Session(sessionId: "s", agent: .claude, cwd: "/Users/me/api", status: .working, updatedAt: 0)

    func ended(_ reply: String?, at time: Double = 100) -> Session {
        var s = working
        s.status = .idle
        s.lastMessage = reply
        s.finishedAt = time
        return s
    }

    @Test func aFinishedTurnNotifiesWithTheReplysFirstLine() {
        let alert = ended("All 48 tests pass.\nNext I'd add a test.").alert(since: working)
        #expect(alert == .finished(reply: "All 48 tests pass."))
        #expect(alert?.title("Claude · api") == "Claude · api finished")
        #expect(alert?.body == "All 48 tests pass.")
    }

    @Test func aTurnWithNoReplyStillNotifies() {
        #expect(ended(nil).alert(since: working)?.body == "The turn ended.")
    }

    @Test func errorsNotifyAsStopped() {
        #expect(ended("API error: rate_limit").alert(since: working) == .stopped(reason: "API error: rate_limit"))
        #expect(ended("Error").alert(since: working)?.title("Amp · docs") == "Amp · docs stopped")
    }

    @Test func escAndInterruptsStayQuiet() {
        var interrupted = working
        interrupted.status = .idle  // no finished_at: Esc, a denied permission, a Codex Interrupt
        #expect(interrupted.alert(since: working) == nil)
    }

    @Test func eachTurnNotifiesOnce() {
        let first = ended("Done.")
        #expect(first.alert(since: first) == nil)
        #expect(ended("Done.", at: 200).alert(since: first) == .finished(reply: "Done."))  // the same reply, a new turn
    }

    @Test func waitingOnYouNotifiesOnTheWayIn() {
        var asking = working
        asking.status = .needsYou
        #expect(asking.alert(since: working) == .needsYou)
        #expect(asking.alert(since: asking) == nil)
        #expect(Alert.needsYou.title("Codex · billing") == "Codex · billing needs you")
    }

    @Test func waitingOnYouBeatsAFinishedTurnInOnePoll() {
        var next = ended("Done.")
        next.status = .needsYou  // the queued turn stopped at a prompt before the next poll
        #expect(next.alert(since: working) == .needsYou)
    }

    @Test func theTrackerStartsQuietAndForgetsGoneSessions() {
        var tracker = AlertTracker()
        #expect(tracker.changes(in: [ended("Old turn.")]).isEmpty)  // launch: baseline only
        #expect(tracker.changes(in: [ended("New turn.", at: 200)]).map(\.alert) == [.finished(reply: "New turn.")])
        #expect(tracker.changes(in: []).isEmpty)  // the session went away
        #expect(tracker.changes(in: [ended("Back again.", at: 300)]).isEmpty)  // it came back: baseline again
    }

    @Test func claudeAndCodexGetAmpsSoundsAndAmpKeepsItsOwn() {
        var asking = working
        asking.status = .needsYou
        var codex = ended("Done.")
        codex.agent = .codex
        var amp = codex
        amp.agent = .amp
        #expect(Alert.sound(for: [(codex, .finished(reply: "Done."))]) == "Submarine")
        #expect(Alert.sound(for: [(ended("Error"), .stopped(reason: "Error"))]) == "Submarine")
        #expect(Alert.sound(for: [(codex, .finished(reply: "Done.")), (asking, .needsYou)]) == "Ping")  // one sound, waiting first
        #expect(Alert.sound(for: [(amp, .needsYou)]) == nil)
        #expect(Alert.sound(for: []) == nil)
        for name in ["Submarine", "Ping"] { #expect(FileManager.default.fileExists(atPath: "/System/Library/Sounds/\(name).aiff")) }
    }

    @Test func longRepliesAreCut() {
        #expect(ended(String(repeating: "x", count: 500)).alert(since: working)?.body.count == 300)
    }
}
