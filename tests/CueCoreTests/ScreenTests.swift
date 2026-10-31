@testable import CueCore
import Testing

/// The checks that guard typing into Claude Code. Screens are real captures from Claude Code 2.1.285.
@Suite struct ScreenTests {
    let rule = String(repeating: "─", count: 60)
    let status = "  ⏵⏵ auto mode on (shift+tab to cycle) · ← for agents"

    @Test func idleScreenIsSafe() {
        let idle = ["⏺ PONG", "✻ Crunched for 2s · done 12:08 AM", rule, "❯ ", rule, status].joined(separator: "\n")
        #expect(Delivery.screenProblem(idle) == nil)
    }

    @Test func workingScreenIsRefused() {
        let working = ["✻ Propagating… (4s · ↓ 263 tokens · thought for 2s)", "  ⎿  Tip: use /color", rule, "❯ ", rule, status].joined(separator: "\n")
        #expect(Delivery.screenProblem(working) == "Claude is working")
    }

    @Test func permissionDialogHasNoInputBox() {
        let dialog = [rule, " Bash command", "   touch x.txt", " Do you want to proceed?", " ❯ 1. Yes", "   2. No", " Esc to cancel · Tab to amend"]
        #expect(Delivery.box(dialog.joined(separator: "\n")) == nil)
    }

    @Test func editorHasNoInputBox() {
        #expect(Delivery.box(["~", "~", "  NORMAL  claude-prompt-36c2.md"].joined(separator: "\n")) == nil)
    }

    @Test func indentedDialogOptionIsNotTheBox() {
        #expect(Delivery.box([rule, " ❯ 1. Yes", "   2. No", rule].joined(separator: "\n")) == nil)
    }

    @Test func oldSpinnerFarAboveTheBoxIsIgnored() {
        let screen = ["✻ Thinking… (2s)"] + Array(repeating: "output line", count: 8) + [rule, "❯ ", rule]
        #expect(Delivery.screenProblem(screen.joined(separator: "\n")) == nil)
    }

    @Test func spinnerTextInsideThePromptIsIgnored() {
        #expect(Delivery.screenProblem([rule, "❯ wait… (later)", rule].joined(separator: "\n")) == nil)
    }

    @Test func vimNormalModeIsRefused() {
        #expect(Delivery.screenProblem([rule, "❯ ", rule, "  -- NORMAL --"].joined(separator: "\n"))?.contains("NORMAL") == true)
    }

    @Test func draftShowsInTheBox() {
        #expect(Delivery.box([rule, "❯ delete the old branch", rule].joined(separator: "\n"))?.lines == ["❯ delete the old branch"])
    }

    @Test func scrolledBoxEndsWithThePrompt() {
        let box = ["❯ padding words padding words", "padding words", "Line four.", "Line five: reply with the number of lines."]
        #expect(Delivery.box(box, endsWith: "Line one.\nLine two: padding words padding words padding words\nLine four.\nLine five: reply with the number of lines."))
    }

    @Test func oneLineBoxEndsWithThePrompt() {
        #expect(Delivery.box(["❯ Reply with PONG"], endsWith: "Reply with PONG"))
    }

    @Test func boxHoldingOtherTextIsRejected() {
        #expect(!Delivery.box(["❯ half typed draft"], endsWith: "Reply with PONG"))
        #expect(!Delivery.box(["❯"], endsWith: "Reply with PONG"))
    }

    @Test func spinnerLines() {
        #expect(!Delivery.isSpinner("✻ Cooked for 2s · done 12:09 AM"))
        #expect(Delivery.isSpinner("✶ Thinking… (esc to interrupt)"))
    }
}
