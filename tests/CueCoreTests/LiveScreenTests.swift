@testable import CueCore
import Foundation
import Testing

/// Checks a captured screen against the input-box parser, for example the one Cue kept when it refused:
///     CUE_SCREEN_FILE=~/.cue/unreadable-screen.txt swift test --filter LiveScreen
/// Skipped unless CUE_SCREEN_FILE is set.
@Suite struct LiveScreen {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CUE_SCREEN_FILE"] != nil))
    func capturedScreenHasAnInputBox() throws {
        let screen = try String(contentsOfFile: ProcessInfo.processInfo.environment["CUE_SCREEN_FILE"]!, encoding: .utf8)
        print("box: \(String(describing: Delivery.box(screen)?.lines))")
        print("problem: \(Delivery.screenProblem(screen) ?? "none")")
        #expect(Delivery.screenProblem(screen) != "Claude's input box isn't on screen (dialog, editor or menu open)")
    }
}
