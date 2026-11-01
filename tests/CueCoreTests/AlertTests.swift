@testable import CueCore
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

    @Test func longRepliesAreCut() {
        #expect(ended(String(repeating: "x", count: 500)).alert(since: working)?.body.count == 300)
    }
}
