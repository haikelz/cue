@testable import CueCore
import Testing

/// What a prompt becomes before it reaches a terminal.
@Suite struct TextTests {
    @Test func sanitizeStripsControlsAndEscapes() {
        #expect(Delivery.sanitize("a\u{1B}[31mb\u{7}c\r") == "a[31mbc")
    }

    @Test func sanitizeTurnsTabsIntoSpaces() {
        #expect(Delivery.sanitize("a\tb") == "a b")
    }

    @Test func sanitizeStripsInvisibleAndBidiCharacters() {
        #expect(Delivery.sanitize("a\u{200B}b\u{202E}c\u{2066}d\u{061C}e\u{E0041}f\u{E0100}g\u{2028}h") == "abcdefgh")
    }

    @Test func sanitizeKeepsLineBreaksAndEmoji() {
        #expect(Delivery.sanitize("one\ntwo 👍🏽") == "one\ntwo 👍🏽")
    }

    @Test func trailingBackslashGetsASpace() {
        #expect(Delivery.sanitize("path\\") == "path\\ ")
    }

    @Test func keysCutLinesIn200CharacterChunks() {
        #expect(Delivery.keys(String(repeating: "x", count: 450)).map(\.count) == [200, 200, 50])
    }

    @Test func keysCountCharactersNotBytes() {
        #expect(Delivery.keys(String(repeating: "é", count: 201)).map(\.count) == [400, 2])
    }

    @Test func keysPutOptionReturnBetweenLines() {
        #expect(Delivery.keys("a\nb") == [[0x61], Key.lineBreak, [0x62]])
    }

    @Test func slashAndShellCommandsSkipConfirmation() {
        #expect(Delivery.skipsConfirmation(" /clear"))
        #expect(Delivery.skipsConfirmation("!ls"))
        #expect(!Delivery.skipsConfirmation("fix the bug"))
    }
}
