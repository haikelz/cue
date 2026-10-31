@testable import CueCore
import Testing

/// Claude typing against a fake terminal: what goes out, in what order, and how each error becomes
/// the row's outcome. A failed outcome copies the prompt to the clipboard; a refused one doesn't.
@Suite struct TypingTests {
    static let rule = String(repeating: "─", count: 60)
    static func screen(_ box: String) -> String { [rule, box, rule].joined(separator: "\n") }

    /// Shows `screens` in turn (the last one stays) and fails sends as `sendErrors` says, in turn.
    final class FakeTerminal: Terminal, @unchecked Sendable {
        var screens: [String]
        var screenError: DeliveryError?
        var sendErrors: [DeliveryError?]
        var sent: [[[UInt8]]] = []

        init(_ screens: [String], screenError: DeliveryError? = nil, sendErrors: [DeliveryError?] = []) {
            (self.screens, self.screenError, self.sendErrors) = (screens, screenError, sendErrors)
        }

        func screen(tty: String, timeout: Double) throws(DeliveryError) -> String {
            if let screenError { throw screenError }
            return screens.count > 1 ? screens.removeFirst() : screens[0]
        }

        func send(_ chunks: [[UInt8]], tty: String) throws(DeliveryError) {
            sent.append(chunks)
            if !sendErrors.isEmpty, let error = sendErrors.removeFirst() { throw error }
        }

        func open() throws(DeliveryError) -> [AppRef] { [] }
    }

    let session = Session(sessionId: "s", agent: .claude, cwd: "/", status: .idle, updatedAt: 0, tty: "/dev/ttys001")

    func type(_ text: String, on terminal: FakeTerminal, gate: String? = nil) -> String {
        switch Delivery.typeIntoClaude(session, text, on: terminal, gate: { _ in gate }) {
        case .sent: "sent"
        case .accepted(let m): "accepted: \(m)"
        case .inbox: "inbox"
        case .refused(let m): "refused: \(m)"
        case .failed(let m): "failed: \(m)"
        }
    }

    @Test func clearsTheDraftTypesThenPressesReturn() {
        let t = FakeTerminal([Self.screen("❯ old draft"), Self.screen("❯ hello")])
        #expect(type("hello", on: t) == "sent")
        #expect(t.sent == [[Key.clearLine] + Delivery.keys("hello"), [Key.submit]])
    }

    @Test func anEmptyBoxOrASuggestionNeedsNoClearing() {
        for box in ["❯ ", "❯ Try \"fix the lint errors\""] {
            let t = FakeTerminal([Self.screen(box), Self.screen("❯ hello")])
            #expect(type("hello", on: t) == "sent")
            #expect(t.sent.first == Delivery.keys("hello"))
        }
    }

    @Test func aGateRefusalSendsNothing() {
        let t = FakeTerminal([Self.screen("❯ ")])
        #expect(type("hello", on: t, gate: "Claude is working") == "refused: Claude is working")
        #expect(t.sent.isEmpty)
    }

    @Test func anUnreadableScreenRefusesBeforeTyping() {
        let t = FakeTerminal([""], screenError: .closed("tmux pane is closed"))
        #expect(type("hello", on: t) == "refused: tmux pane is closed")
        #expect(t.sent.isEmpty)
    }

    @Test(arguments: [
        (DeliveryError.moved("Pane no longer runs this session"), "refused: Pane no longer runs this session"),
        (.refused("tmux pane is in copy mode; press q in it"), "refused: tmux pane is in copy mode; press q in it"),
        (.closed("tmux pane is closed"), "failed: tmux pane is closed"),
        (.failed("tmux didn't answer in 10 s"), "failed: tmux didn't answer in 10 s"),
    ])
    func typingErrorsBecomeOutcomes(error: DeliveryError, outcome: String) {
        let t = FakeTerminal([Self.screen("❯ ")], sendErrors: [error])
        #expect(type("hello", on: t) == outcome)
        #expect(t.sent.count == 1)  // no Return
    }

    @Test func aFailedRecheckHoldsBackReturn() {
        let dialog = [Self.rule, " Do you want to proceed?", " ❯ 1. Yes", "   2. No"].joined(separator: "\n")
        let t = FakeTerminal([Self.screen("❯ "), dialog])
        #expect(type("hello", on: t) == "failed: Typed but not sent: Claude's input box isn't on screen (dialog, editor or menu open). The text is in Claude's input box")
        #expect(t.sent.count == 1)
    }

    @Test func aBoxNotEndingWithThePromptHoldsBackReturn() {
        let t = FakeTerminal([Self.screen("❯ "), Self.screen("❯ something else")])
        #expect(type("hello", on: t) == "failed: Typed but not sent: the input box doesn't end with this prompt")
        #expect(t.sent.count == 1)
    }

    @Test func aFailedReturnSaysTheTextIsTyped() {
        let t = FakeTerminal([Self.screen("❯ "), Self.screen("❯ hello")], sendErrors: [nil, .failed("tmux didn't answer in 10 s")])
        #expect(type("hello", on: t) == "failed: Typed but not sent: tmux didn't answer in 10 s")
    }

    @Test func aSessionWithoutATerminalIsRefused() {
        var s = session
        s.tty = nil
        let outcome = Delivery.typeIntoClaude(s, "hello", on: FakeTerminal([""]), gate: { _ in nil })
        guard case .refused(let why) = outcome else { Issue.record("expected a refusal"); return }
        #expect(why == "Not in iTerm2 or tmux")
    }
}
