@testable import MeetingTranscriber
import XCTest

/// A person named on both tracks of one recording was heard twice: once on the
/// channel they actually spoke into and once as bleed on the other. The filter
/// must drop the bleed copy and nothing else, so these tests pin what survives
/// as carefully as what is removed.
final class CrossTrackEmbeddingFilterTests: XCTestCase {
    private let appA = SpeakerKey(track: .app, id: "SPEAKER_0").encoded
    private let appB = SpeakerKey(track: .app, id: "SPEAKER_1").encoded
    private let micA = SpeakerKey(track: .mic, id: "SPEAKER_0").encoded
    private let micB = SpeakerKey(track: .mic, id: "SPEAKER_1").encoded

    private func embeddings(_ labels: String...) -> [String: [Float]] {
        Dictionary(uniqueKeysWithValues: labels.enumerated().map { index, label in
            (label, [Float(index + 1), 0, 0])
        })
    }

    func testRemoteNameOnBothTracksKeepsOnlyTheTrackItSpokeLongerOn() {
        let out = CrossTrackEmbeddingFilter.admissible(
            embeddings(appA, micA),
            mapping: [appA: "Remote", micA: "Remote"],
            speakingTimes: [appA: 300, micA: 12],
        )
        XCTAssertEqual(Array(out.keys), [appA], "The microphone copy of a remote voice is bleed")
    }

    func testLocalNameOnBothTracksKeepsTheMicrophone() {
        let out = CrossTrackEmbeddingFilter.admissible(
            embeddings(appA, micA),
            mapping: [appA: "Local", micA: "Local"],
            speakingTimes: [appA: 9, micA: 400],
        )
        XCTAssertEqual(Array(out.keys), [micA], "The rule keys on speaking time, not on which track is the owner's")
    }

    func testNamesOnOneTrackOnlyAreUntouched() {
        let input = embeddings(appA, appB, micA)
        let out = CrossTrackEmbeddingFilter.admissible(
            input,
            mapping: [appA: "Remote", appB: "Other", micA: "Local"],
            speakingTimes: [appA: 100, appB: 50, micA: 200],
        )
        XCTAssertEqual(out.keys.sorted(), input.keys.sorted())
    }

    func testTwoClustersOfOnePersonOnTheSameTrackBothStay() {
        let out = CrossTrackEmbeddingFilter.admissible(
            embeddings(appA, appB, micA),
            mapping: [appA: "Remote", appB: "Remote", micA: "Remote"],
            speakingTimes: [appA: 100, appB: 80, micA: 30],
        )
        XCTAssertEqual(out.keys.sorted(), [appA, appB].sorted(), "Speaking time is summed per track")
    }

    func testUnnamedLabelsAreNotGroupedTogether() {
        let input = embeddings(appA, micA)
        // An unconfirmed label maps to itself; two raw labels are not one person.
        let out = CrossTrackEmbeddingFilter.admissible(
            input, mapping: [appA: appA, micA: micA], speakingTimes: [appA: 10, micA: 10],
        )
        XCTAssertEqual(out.keys.sorted(), input.keys.sorted())
    }

    func testEqualSpeakingTimeHoldsBothCopies() {
        let out = CrossTrackEmbeddingFilter.admissible(
            embeddings(appA, micA),
            mapping: [appA: "Remote", micA: "Remote"],
            speakingTimes: [appA: 40, micA: 40],
        )
        XCTAssertTrue(out.isEmpty, "With no way to tell which copy is the bleed, neither is learned")
    }

    func testSingleSourceLabelsAreUntouched() {
        let single = SpeakerKey(track: .single, id: "SPEAKER_0").encoded
        let other = SpeakerKey(track: .single, id: "SPEAKER_1").encoded
        let input = embeddings(single, other)
        let out = CrossTrackEmbeddingFilter.admissible(
            input, mapping: [single: "Same", other: "Same"], speakingTimes: [single: 5, other: 50],
        )
        XCTAssertEqual(out.keys.sorted(), input.keys.sorted())
    }

    func testOtherPeopleInTheSameRecordingAreUnaffected() {
        let out = CrossTrackEmbeddingFilter.admissible(
            embeddings(appA, appB, micA, micB),
            mapping: [appA: "Remote", appB: "Other", micA: "Local", micB: "Remote"],
            speakingTimes: [appA: 200, appB: 90, micA: 500, micB: 20],
        )
        XCTAssertEqual(out.keys.sorted(), [appA, appB, micA].sorted())
    }
}
