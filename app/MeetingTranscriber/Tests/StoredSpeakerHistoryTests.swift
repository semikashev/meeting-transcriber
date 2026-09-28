@testable import MeetingTranscriber
import XCTest

/// The sample history is what makes a learned voice reversible. These tests pin
/// the three things that promise rests on: an untouched legacy entry survives
/// unchanged, the derived anchors always follow the history, and an edit to the
/// history (remove, undo a meeting, pin) recomputes them exactly.
final class StoredSpeakerHistoryTests: XCTestCase { // swiftlint:disable:this balanced_xctest_lifecycle
    private static let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    // swiftlint:disable:next implicitly_unwrapped_optional
    private var dbPath: URL!

    override func setUpWithError() throws {
        dbPath = try makeTempDirectory(prefix: "StoredSpeakerHistoryTests").appendingPathComponent("speakers.json")
    }

    // MARK: - Migration

    func testLegacyDatabaseRoundTripsByteIdentically() throws {
        let legacy = Data("""
        [{"name":"Speaker A","embeddings":[[1,0],[0.5,0.5]],"centroid":[0.75,0.25],"centroidSampleCount":7,\
        "lastUsed":700000000,"useCount":9}]
        """.utf8)
        let decoded = try JSONDecoder().decode([StoredSpeaker].self, from: legacy)
        let reencoded = try JSONEncoder().encode(decoded)
        func canonical(_ data: Data) throws -> Data {
            try JSONSerialization.data(
                withJSONObject: JSONSerialization.jsonObject(with: data), options: .sortedKeys,
            )
        }
        XCTAssertEqual(
            try canonical(reencoded), try canonical(legacy),
            "Loading and saving an untouched entry must not rewrite it",
        )
        XCTAssertEqual(decoded[0].samples.map(\.origin), [.migratedCentroid, .migratedSample, .migratedSample])
        XCTAssertEqual(decoded[0].centroid, [0.75, 0.25])
        XCTAssertEqual(decoded[0].centroidSampleCount, 7)
    }

    func testMigratedSamplesKeepTheirIdentityAcrossLoads() throws {
        // The plan that names a sample and the edit that removes it load the
        // database separately; a sample that changed id in between was never removed.
        let matcher = SpeakerMatcher(dbPath: dbPath)
        matcher.saveDB([StoredSpeaker(name: "A", embeddings: [[1, 0], [0, 1]], centroid: [1, 0], centroidSampleCount: 4)])
        let first = try XCTUnwrap(matcher.loadDB().first).samples.map(\.id)
        let second = try XCTUnwrap(matcher.loadDB().first).samples.map(\.id)
        XCTAssertEqual(first, second)
        XCTAssertEqual(Set(first).count, 3)

        XCTAssertEqual(matcher.removeSamples([first[2]], from: "A"), 1)
        XCTAssertEqual(matcher.loadDB().first?.embeddings, [[1, 0]])
    }

    func testFirstRealSampleIsAveragedWithTheMigratedCentroidByItsWeight() {
        let legacy = StoredSpeaker(name: "A", embeddings: [[1, 0]], centroid: [1, 0], centroidSampleCount: 3)
        let next = SpeakerMatcher.applyConfirmation(to: legacy, embedding: [0, 1], duration: 10, now: Self.epoch)
        XCTAssertEqual(next.centroid?[0] ?? 0, 0.75, accuracy: 1e-6)
        XCTAssertEqual(next.centroid?[1] ?? 0, 0.25, accuracy: 1e-6)
        XCTAssertEqual(next.centroidSampleCount, 4)
        XCTAssertEqual(next.embeddings, [[1, 0], [0, 1]])
    }

    func testHistoryIsWrittenOnceItHoldsARealSample() throws {
        let legacy = StoredSpeaker(name: "A", embeddings: [[1, 0]], centroid: [1, 0], centroidSampleCount: 1)
        let next = SpeakerMatcher.applyConfirmation(
            to: legacy, embedding: [0, 1], duration: 10, now: Self.epoch,
            provenance: SampleProvenance(jobID: UUID(), meetingTitle: "Weekly", track: .app),
        )
        let decoded = try JSONDecoder().decode(StoredSpeaker.self, from: JSONEncoder().encode(next))
        XCTAssertEqual(decoded.samples, next.samples)
        XCTAssertEqual(decoded.centroid, next.centroid)
        XCTAssertEqual(decoded.embeddings, next.embeddings)
        XCTAssertEqual(decoded.samples.last?.meetingTitle, "Weekly")
        XCTAssertEqual(decoded.samples.last?.track, .app)
        XCTAssertEqual(decoded.samples.last?.duration, 10)
    }

    // MARK: - Bounds

    func testHistoryKeepsTheNewestUnpinnedSamplesAndEveryPinnedOne() {
        var speaker = SpeakerMatcher.newSpeaker(name: "A", embedding: [1, 0], duration: 10, now: Self.epoch)
        let pinnedID = speaker.samples[0].id
        speaker = speaker.withSamples([speaker.samples[0].pinned(true)])
        for i in 1 ... StoredSpeaker.maxHistory + 5 {
            speaker = SpeakerMatcher.applyConfirmation(
                to: speaker, embedding: [Float(i), 1], duration: 10, now: Self.epoch,
            )
        }
        XCTAssertEqual(speaker.samples.count { !$0.pinned }, StoredSpeaker.maxHistory)
        XCTAssertEqual(speaker.samples.first?.id, pinnedID, "A reference sample is never evicted")
        XCTAssertEqual(speaker.samples.last?.embedding, [Float(StoredSpeaker.maxHistory + 5), 1])
    }

    func testPinnedSampleOutsideTheRecentOnesStillAnchorsMatching() {
        var speaker = SpeakerMatcher.newSpeaker(name: "A", embedding: [1, 0, 0], duration: 10, now: Self.epoch)
        speaker = speaker.withSamples([speaker.samples[0].pinned(true)])
        for _ in 0 ..< 5 {
            speaker = SpeakerMatcher.applyConfirmation(
                to: speaker, embedding: [0, 1, 0], duration: 10, now: Self.epoch,
            )
        }
        XCTAssertFalse(speaker.embeddings.contains([1, 0, 0]), "no longer among the recent samples")
        XCTAssertTrue(speaker.anchorEmbeddings.contains([1, 0, 0]))
        XCTAssertEqual(SpeakerMatcher.distance(query: [1, 0, 0], speaker: speaker), 0, accuracy: 1e-6)
    }

    // MARK: - Edits

    func testRemovingASampleRecomputesTheCentroidExactly() throws {
        let matcher = SpeakerMatcher(dbPath: dbPath)
        matcher.updateDB(mapping: ["S0": "A"], embeddings: ["S0": [1, 0]], speakingTimes: ["S0": 10])
        matcher.updateDB(mapping: ["S0": "A"], embeddings: ["S0": [0.8, 0.6]], speakingTimes: ["S0": 10])
        let stray = try XCTUnwrap(matcher.loadDB().first?.samples.last)

        XCTAssertEqual(matcher.removeSamples([stray.id], from: "A"), 1)
        let after = try XCTUnwrap(matcher.loadDB().first)
        XCTAssertEqual(after.centroid, [1, 0])
        XCTAssertEqual(after.centroidSampleCount, 1)
        XCTAssertEqual(after.embeddings, [[1, 0]])
    }

    func testUndoingAMeetingRemovesWhatItTaughtEverySpeakerAndNothingElse() throws {
        let matcher = SpeakerMatcher(dbPath: dbPath)
        let earlier = UUID()
        let wrong = UUID()
        matcher.updateDB(
            mapping: ["R_S0": "A", "M_S0": "B"],
            embeddings: ["R_S0": [1, 0, 0], "M_S0": [0, 1, 0]],
            speakingTimes: ["R_S0": 30, "M_S0": 30],
            provenance: SampleProvenance(jobID: earlier),
        )
        matcher.updateDB(
            mapping: ["R_S0": "A", "M_S0": "C"],
            embeddings: ["R_S0": [0.9, 0.1, 0.3], "M_S0": [0, 0, 1]],
            speakingTimes: ["R_S0": 30, "M_S0": 30],
            provenance: SampleProvenance(jobID: wrong),
        )

        XCTAssertEqual(Set(matcher.removeContributions(ofJob: wrong)), ["A", "C"])
        let db = matcher.loadDB()
        XCTAssertEqual(db.first { $0.name == "A" }?.centroid, [1, 0, 0])
        XCTAssertEqual(db.first { $0.name == "B" }?.samples.count, 1, "untouched by the undone meeting")
        let emptied = try XCTUnwrap(db.first { $0.name == "C" })
        XCTAssertTrue(emptied.samples.isEmpty)
        XCTAssertNil(emptied.centroid)
        XCTAssertEqual(
            SpeakerMatcher(dbPath: dbPath).match(embeddings: ["X": [0, 0, 1]])["X"], "X",
            "A speaker without samples keeps its name but must not match anything",
        )
    }

    func testPinningIsPersisted() throws {
        let matcher = SpeakerMatcher(dbPath: dbPath)
        matcher.updateDB(mapping: ["S0": "A"], embeddings: ["S0": [1, 0]], speakingTimes: ["S0": 10])
        let sample = try XCTUnwrap(matcher.loadDB().first?.samples.first)
        XCTAssertTrue(matcher.setPinned(true, sample: sample.id, of: "A"))
        XCTAssertEqual(matcher.loadDB().first?.samples.first?.pinned, true)
        XCTAssertFalse(matcher.setPinned(true, sample: UUID(), of: "A"))
    }

    func testEnrollmentAsReferencePinsTheLearnedSamples() throws {
        let matcher = SpeakerMatcher(dbPath: dbPath)
        matcher.updateDB(
            mapping: ["S0": "A"], embeddings: ["S0": [1, 0]], speakingTimes: ["S0": 45],
            provenance: SampleProvenance(origin: .enrollment, meetingTitle: "voice.m4a", pinned: true),
        )
        let sample = try XCTUnwrap(matcher.loadDB().first?.samples.first)
        XCTAssertTrue(sample.pinned)
        XCTAssertEqual(sample.origin, .enrollment)
        XCTAssertEqual(sample.meetingTitle, "voice.m4a")
    }
}
