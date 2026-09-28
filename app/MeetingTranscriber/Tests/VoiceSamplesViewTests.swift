@testable import MeetingTranscriber
import ViewInspector
import XCTest

@MainActor
final class VoiceSamplesViewTests: XCTestCase { // swiftlint:disable:this balanced_xctest_lifecycle
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var dbPath: URL!

    override func setUp() async throws {
        try await super.setUp()
        dbPath = try makeTempDirectory(prefix: "VoiceSamplesViewTests").appendingPathComponent("speakers.json")
    }

    /// Two meetings taught A; the second also taught B.
    private func twoMeetings() -> (SpeakerMatcher, first: UUID, second: UUID) {
        let matcher = SpeakerMatcher(dbPath: dbPath)
        let first = UUID()
        let second = UUID()
        matcher.updateDB(
            mapping: ["R_S1": "A"], embeddings: ["R_S1": [1, 0, 0]], speakingTimes: ["R_S1": 60],
            provenance: SampleProvenance(jobID: first, meetingTitle: "Weekly"),
        )
        matcher.updateDB(
            mapping: ["R_S1": "A", "R_S2": "B"],
            embeddings: ["R_S1": [0.9, 0.2, 0], "R_S2": [0, 0, 1]],
            speakingTimes: ["R_S1": 60, "R_S2": 60],
            provenance: SampleProvenance(jobID: second, meetingTitle: "Review"),
        )
        return (matcher, first, second)
    }

    func testRendersWithSamples() throws {
        let (matcher, _, _) = twoMeetings()
        let body = try VoiceSamplesView(matcher: matcher, name: "A").inspect()
        XCTAssertNoThrow(try body.find(text: "Voice samples: A"))
        XCTAssertNoThrow(try body.find(text: "2 samples"))
        XCTAssertTrue(try body.find(button: "Remove Sample").isDisabled(), "Nothing is selected yet")
    }

    func testRemoveRecomputesTheVoiceAndReportsTheChange() throws {
        let (matcher, _, _) = twoMeetings()
        let stray = try XCTUnwrap(matcher.loadDB().first { $0.name == "A" }?.samples.last?.id)
        var changes = 0
        let view = VoiceSamplesView(matcher: matcher, name: "A") { changes += 1 }

        view.performRemove([stray])

        XCTAssertEqual(matcher.loadDB().first { $0.name == "A" }?.centroid, [1, 0, 0])
        XCTAssertEqual(changes, 1)
    }

    func testPinningWritesTheReferenceFlag() throws {
        let (matcher, _, _) = twoMeetings()
        let sample = try XCTUnwrap(matcher.loadDB().first { $0.name == "A" }?.samples.first?.id)
        let view = VoiceSamplesView(matcher: matcher, name: "A")

        view.performSetPinned(true, sample: sample)

        XCTAssertEqual(matcher.loadDB().first { $0.name == "A" }?.samples.first?.pinned, true)
    }

    func testUndoMeetingRemovesItsSamplesFromEveryVoice() {
        let (matcher, first, second) = twoMeetings()
        let view = VoiceSamplesView(matcher: matcher, name: "A")

        view.performUndoMeeting(second)

        let db = matcher.loadDB()
        XCTAssertEqual(db.first { $0.name == "A" }?.samples.map(\.jobID), [first])
        XCTAssertEqual(db.first { $0.name == "B" }?.samples.count, 0)
    }

    // MARK: - Formatting

    func testRowFormatting() {
        let migrated = VoiceSample(embedding: [1], origin: .migratedCentroid, centroidWeight: 12)
        XCTAssertEqual(VoiceSampleFormatting.source(migrated), "Earlier average of 12")
        XCTAssertEqual(VoiceSampleFormatting.added(migrated), "Before history")
        XCTAssertEqual(VoiceSampleFormatting.track(migrated), "—")
        XCTAssertEqual(VoiceSampleFormatting.speech(migrated), "—")

        let enrolled = VoiceSample(
            embedding: [1], origin: .enrollment, centroidWeight: 1, duration: 42.4, track: .single,
            meetingTitle: "voice.m4a", pinned: true,
        )
        XCTAssertEqual(VoiceSampleFormatting.source(enrolled), "Enrolled: voice.m4a")
        XCTAssertEqual(VoiceSampleFormatting.speech(enrolled), "42 s")
        XCTAssertEqual(
            VoiceSampleFormatting.flag(enrolled, issues: [.sharedSample(enrolled.id, with: "B")]),
            "Reference, Also matches B",
        )
    }
}
