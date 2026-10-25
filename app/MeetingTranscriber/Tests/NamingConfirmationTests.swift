@testable import MeetingTranscriber
import XCTest

/// What a confirmed naming dialog settles on, for every kind of entry. The
/// confirm path itself is wired through in `SpeakerNamingSessionTests`.
final class NamingConfirmationTests: XCTestCase {
    private let suggested = ["SPEAKER_0": "Alice", "SPEAKER_1": "Bob", "SPEAKER_2": "SPEAKER_2"]

    // MARK: - resolvedNames

    func testAClearedSuggestionLeavesTheLabelUnnamed() {
        let names = NamingConfirmation.resolvedNames(suggested: suggested, confirmed: ["SPEAKER_0": ""])
        XCTAssertEqual(names["SPEAKER_0"], "SPEAKER_0")
    }

    /// The automation API relies on this: only an explicit empty name rejects.
    func testALabelLeftOutKeepsItsSuggestion() {
        let names = NamingConfirmation.resolvedNames(suggested: suggested, confirmed: ["SPEAKER_1": "Carol"])
        XCTAssertEqual(names, ["SPEAKER_0": "Alice", "SPEAKER_1": "Carol", "SPEAKER_2": "SPEAKER_2"])
    }

    func testATypedNameReplacesTheSuggestion() {
        let names = NamingConfirmation.resolvedNames(suggested: suggested, confirmed: ["SPEAKER_2": "Dana"])
        XCTAssertEqual(names["SPEAKER_2"], "Dana")
    }

    // MARK: - revertClearedSuggestions

    func testAClearedSuggestionComesOffItsLines() {
        let transcript = NamingConfirmation.revertClearedSuggestions(
            in: "[00:01] Alice: hi\n[00:02] Bob: Alice: are you there?\n",
            suggested: suggested, confirmed: ["SPEAKER_0": "", "SPEAKER_1": "Bob"],
        )
        XCTAssertEqual(
            transcript,
            "[00:01] SPEAKER_0: hi\n[00:02] Bob: Alice: are you there?\n",
            "only the speaker slot changes, never the spoken text",
        )
    }

    /// The matcher can give one name to two labels of a track, and a written
    /// line no longer says which label spoke it.
    func testASharedSuggestionStaysOnEveryLine() {
        let transcript = "[00:01] Alice: hi\n[00:05] Alice: hello again\n"
        let reverted = NamingConfirmation.revertClearedSuggestions(
            in: transcript,
            suggested: ["SPEAKER_0": "Alice", "SPEAKER_1": "Alice"],
            confirmed: ["SPEAKER_0": "", "SPEAKER_1": "Alice"],
        )
        XCTAssertEqual(reverted, transcript)
    }

    /// An empty field on an unsuggested label has nothing to take back.
    func testAnEmptyNameWithoutASuggestionChangesNothing() {
        let transcript = "[00:01] SPEAKER_2: hi\n"
        let reverted = NamingConfirmation.revertClearedSuggestions(
            in: transcript, suggested: suggested, confirmed: ["SPEAKER_2": ""],
        )
        XCTAssertEqual(reverted, transcript)
    }
}
