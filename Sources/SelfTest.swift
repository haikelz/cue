import Foundation

/// `ClaudeRelay selftest`: asserts the pure functions that guard typing. Screens are real captures
/// from Claude Code 2.1.285 in iTerm2. Run by tests/check.sh.
enum SelfTest {
    static func run() -> Int32 {
        var fails = 0
        func check(_ name: String, _ ok: Bool) {
            print(ok ? "ok    \(name)" : "FAIL  \(name)")
            if !ok { fails += 1 }
        }
        let rule = String(repeating: "─", count: 60)
        let status = "  ⏵⏵ auto mode on (shift+tab to cycle) · ← for agents"
        let idle = ["⏺ PONG", "✻ Crunched for 2s · done 12:08 AM", rule, "❯ ", rule, status].joined(separator: "\n")
        let working = ["✻ Propagating… (4s · ↓ 263 tokens · thought for 2s)", "  ⎿  Tip: use /color", rule, "❯ ", rule, status].joined(separator: "\n")
        let dialog = [rule, " Bash command", "   touch x.txt", " Do you want to proceed?", " ❯ 1. Yes", "   2. No", " Esc to cancel · Tab to amend"].joined(separator: "\n")
        let editor = ["~", "~", "  NORMAL  claude-prompt-36c2.md"].joined(separator: "\n")
        let oldSpinner = ["✻ Thinking… (2s)"] + Array(repeating: "output line", count: 8) + [rule, "❯ ", rule]
        let draft = [rule, "❯ delete the old branch", rule].joined(separator: "\n")
        let vim = [rule, "❯ ", rule, "  -- NORMAL --"].joined(separator: "\n")
        let spinnerInPrompt = [rule, "❯ wait… (later)", rule].joined(separator: "\n")

        check("idle screen is safe", Delivery.screenProblem(idle) == nil)
        check("working screen is refused", Delivery.screenProblem(working) == "Claude is working")
        check("permission dialog has no input box", Delivery.box(dialog) == nil)
        check("Ctrl+G editor has no input box", Delivery.box(editor) == nil)
        check("indented dialog option under a rule is not the box",
              Delivery.box([rule, " ❯ 1. Yes", "   2. No", rule].joined(separator: "\n")) == nil)
        check("old spinner far above the box is ignored", Delivery.screenProblem(oldSpinner.joined(separator: "\n")) == nil)
        check("spinner text inside the prompt is ignored", Delivery.screenProblem(spinnerInPrompt) == nil)
        check("vim NORMAL mode is refused", Delivery.screenProblem(vim)?.contains("NORMAL") == true)
        check("draft shows in the box", Delivery.box(draft)?.lines == ["❯ delete the old branch"])
        let scrolled = ["❯ padding words padding words", "padding words", "Line four.", "Line five: reply with the number of lines."]
        check("scrolled box ends with the prompt",
              Delivery.box(scrolled, endsWith: "Line one.\nLine two: padding words padding words padding words\nLine four.\nLine five: reply with the number of lines."))
        check("one-line box ends with the prompt", Delivery.box(["❯ Reply with PONG"], endsWith: "Reply with PONG"))
        check("box holding other text is rejected", !Delivery.box(["❯ half typed draft"], endsWith: "Reply with PONG"))
        check("empty box is rejected", !Delivery.box(["❯"], endsWith: "Reply with PONG"))
        check("finished line is not a spinner", !Delivery.isSpinner("✻ Cooked for 2s · done 12:09 AM"))
        check("esc-to-interrupt spinner matches", Delivery.isSpinner("✶ Thinking… (esc to interrupt)"))

        check("sanitize strips controls and escapes", Delivery.sanitize("a\u{1B}[31mb\u{7}c\r") == "a[31mbc")
        check("sanitize turns tabs into spaces", Delivery.sanitize("a\tb") == "a b")
        check("sanitize strips invisible and bidi characters",
              Delivery.sanitize("a\u{200B}b\u{202E}c\u{2066}d\u{061C}e\u{E0041}f\u{E0100}g\u{2028}h") == "abcdefgh")
        check("sanitize keeps line breaks and emoji", Delivery.sanitize("one\ntwo 👍🏽") == "one\ntwo 👍🏽")
        check("trailing backslash gets a space", Delivery.sanitize("path\\") == "path\\ ")
        check("items: 450 characters make 3 chunks", Delivery.items(String(repeating: "x", count: 450)).map(\.count) == [200, 200, 50])
        check("items: line break marker between lines", Delivery.items("a\nb") == ["a", "\u{1}", "b"])

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("relay-selftest-\(getpid())")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func transcript(_ lines: [String]) -> Session {
            let url = dir.appendingPathComponent(UUID().uuidString + ".jsonl")
            try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
            return Session(sessionId: "t", cwd: "/tmp", status: "working", updatedAt: Date().timeIntervalSince1970 - 10,
                           transcriptPath: url.path)
        }
        let marker = #"{"type":"user","message":{"content":[{"type":"text","text":"[Request interrupted by user for tool use]"}]}}"#
        let meta = #"{"type":"permission-mode","permissionMode":"default"}"#
        let reply = #"{"type":"assistant","message":{"content":[{"type":"text","text":"Done."}]}}"#
        check("interrupt marker followed by metadata", transcript([reply, marker, meta, meta]).interrupted)
        check("assistant reply is not an interrupt", !transcript([marker, reply, meta]).interrupted)
        var old = transcript([reply, marker])
        old.updatedAt = Date().timeIntervalSince1970 + 10
        check("marker older than the last hook event is ignored", !old.interrupted)

        print(fails == 0 ? "selftest passed" : "\(fails) selftest check(s) failed")
        return fails == 0 ? 0 : 1
    }
}
