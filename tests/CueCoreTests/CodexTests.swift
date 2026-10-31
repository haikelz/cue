@testable import CueCore
import Foundation
import Testing

/// Which Codex sessions get rows, and the footer's hook check.
/// A class, so deinit can remove the folder: swift-testing makes one instance per test.
@Suite final class CodexTests {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cue-tests-\(UUID().uuidString)")

    deinit { try? FileManager.default.removeItem(at: dir) }

    func rollout(_ originator: String) -> String {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(UUID().uuidString + ".jsonl")
        try? #"{"type":"session_meta","payload":{"originator":"\#(originator)"}}"#.appending("\n").write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    @Test func onlyTheTUIIsInteractive() {
        #expect(Codex.interactive(rollout("codex-tui")))
        #expect(!Codex.interactive(rollout("codex_exec")))
        #expect(!Codex.interactive(nil))  // background sessions have no rollout
        #expect(Codex.interactive(dir.appendingPathComponent("later.jsonl").path))  // not written yet
    }

    @Test func hookCommandQuotesThePath() {
        #expect(Codex.command(exe: "/o'k/cue") == "'/o'\\''k/cue' hook codex")
    }

    @Test func hookWarning() {
        let cue = Codex.command(exe: "/Apps/Cue.app/Contents/MacOS/cue")
        let trusted = Array(repeating: Codex.ListedHook(command: cue, enabled: true, trustStatus: "trusted"), count: 7)
        #expect(Codex.warning(trusted, command: cue) == nil)
        let changed = Array(trusted.dropLast()) + [Codex.ListedHook(command: cue, enabled: true, trustStatus: "modified")]
        #expect(Codex.warning(changed, command: cue)?.contains("/hooks") == true)
        let off = Array(trusted.dropLast()) + [Codex.ListedHook(command: cue, enabled: false, trustStatus: "trusted")]
        #expect(Codex.warning(off, command: cue)?.contains("/hooks") == true)
        #expect(Codex.warning(Array(trusted.prefix(5)), command: cue)?.contains("missing") == true)
    }
}
