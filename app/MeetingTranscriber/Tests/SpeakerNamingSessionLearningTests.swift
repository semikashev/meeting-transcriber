@testable import MeetingTranscriber
import XCTest

/// What a confirmed naming teaches the speaker database: the fork's write rules
/// driven through the real confirm path (`reapplySpeakerNames`), which the
/// dialog and the automation API share. Split from `SpeakerNamingSessionTests`
/// to keep that suite under the length cap; same fixture.
@MainActor
final class SpeakerNamingSessionLearningTests: XCTestCase {
    /// The cross-track rule rides the same confirm path as the quarantine, and
    /// needs no echo verdict: the name alone says the two clusters are one person.
    func testConfirmWithOneNameOnBothTracksLearnsOnlyTheLongerTrack() async throws {
        let tmp = try makeTempDirectory(prefix: "SpeakerNamingSessionTests")
        let transcriptPath = tmp.appendingPathComponent("transcript.txt")
        try "] R_SPEAKER_0: hello".write(to: transcriptPath, atomically: true, encoding: .utf8)

        let session = NamingSessionFixture.session(outputDir: tmp)
        let mock = NamingSessionMockDelegate()
        session.delegate = mock

        let job = NamingSessionFixture.pendingJob(
            namingSlug: "standup_abcd1234", transcriptPath: transcriptPath,
            echo: EchoDetectionDTO(NamingSessionFixture.echoResult(correlations: [0.2, 0.2, 0.2, 0.2])),
        )
        mock.jobs[job.id] = job
        session.speakerNamingDataByJob[job.id] = NamingSessionFixture.dualTrackNamingData(
            jobID: job.id, appSeconds: 240, micSeconds: 15,
        )

        let local = SpeakerKey(track: .mic, id: "SPEAKER_0").encoded
        let remote = SpeakerKey(track: .app, id: "SPEAKER_0").encoded
        session.completeSpeakerNaming(
            jobID: job.id,
            result: .confirmed([remote: "Speaker A", local: "Speaker A"]),
            source: .dialog,
        )

        await waitFor(mock.jobs[job.id]?.state == .done, timeout: .seconds(2))
        let written = try XCTUnwrap(mock.updateSpeakerDBEmbeddings.first)
        XCTAssertNil(written[local], "The microphone copy of a remote voice is bleed and must not be learned")
        XCTAssertEqual(written[remote], [1, 0, 0])
        XCTAssertEqual(
            mock.updateSpeakerDBProvenance.first,
            SampleProvenance(origin: .meeting, jobID: job.id, meetingTitle: "Standup"),
            "Each learned sample must say which recording taught it, or it cannot be undone",
        )
    }

    /// Wiring only; the outcomes are pinned in `NamingConfirmationTests`. The
    /// confirm path, which the dialog and the automation API share, must teach
    /// nothing for a cleared suggestion and take it off the transcript.
    func testConfirmWithAClearedSuggestionNeitherLearnsNorKeepsIt() async throws {
        let tmp = try makeTempDirectory(prefix: "SpeakerNamingSessionTests")
        let transcriptPath = tmp.appendingPathComponent("transcript.txt")
        try "[00:01] Alice: hi\n[00:02] Bob: hello\n".write(to: transcriptPath, atomically: true, encoding: .utf8)
        let session = NamingSessionFixture.session(outputDir: tmp)
        let mock = NamingSessionMockDelegate()
        session.delegate = mock
        let job = NamingSessionFixture.pendingJob(namingSlug: "standup_abcd1234", transcriptPath: transcriptPath)
        mock.jobs[job.id] = job
        session.speakerNamingDataByJob[job.id] = PipelineQueue.SpeakerNamingData(
            jobID: job.id, meetingTitle: "Standup",
            mapping: ["SPEAKER_0": "Alice", "SPEAKER_1": "Bob"],
            speakingTimes: ["SPEAKER_0": 30, "SPEAKER_1": 30],
            embeddings: ["SPEAKER_0": [1, 0, 0], "SPEAKER_1": [0, 1, 0]],
            audioPath: nil, segments: [], participants: [], isDualSource: false,
        )

        session.completeSpeakerNaming(
            jobID: job.id, result: .confirmed(["SPEAKER_0": "", "SPEAKER_1": "Bob"]), source: .dialog,
        )

        await waitFor(mock.jobs[job.id]?.state == .done, timeout: .seconds(2))
        let taught = try XCTUnwrap(mock.updateSpeakerDBMappings.first)
        XCTAssertEqual(taught["SPEAKER_0"], "SPEAKER_0", "the cleared label goes back to unnamed")
        XCTAssertEqual(taught["SPEAKER_1"], "Bob")
        XCTAssertEqual(
            try String(contentsOf: transcriptPath, encoding: .utf8),
            "[00:01] SPEAKER_0: hi\n[00:02] Bob: hello\n",
        )
    }

    /// A merged recording is the same call its parts were named in. Confirming
    /// its names must replace what the parts taught instead of adding a second
    /// copy of every voice next to the first.
    func testConfirmingAMergedRecordingUndoesWhatItsPartsTaught() async throws {
        let tmp = try makeTempDirectory(prefix: "SpeakerNamingSessionTests")
        let transcriptPath = tmp.appendingPathComponent("transcript.txt")
        try "[00:01] SPEAKER_0: hi\n".write(to: transcriptPath, atomically: true, encoding: .utf8)
        let dbPath = tmp.appendingPathComponent("speakers.json")
        let part = try XCTUnwrap(UUID(uuidString: "AAAAAAAA-1111-2222-3333-444444444444"))
        let unrelated = UUID()
        let seed = SpeakerMatcher(dbPath: dbPath)
        seed.updateDB(
            mapping: ["SPEAKER_0": "Alice"], embeddings: ["SPEAKER_0": [1, 0, 0]], speakingTimes: ["SPEAKER_0": 30],
            provenance: SampleProvenance(jobID: part),
        )
        seed.updateDB(
            mapping: ["SPEAKER_0": "Bob"], embeddings: ["SPEAKER_0": [0, 1, 0]], speakingTimes: ["SPEAKER_0": 30],
            provenance: SampleProvenance(jobID: unrelated),
        )
        let session = SpeakerNamingSession(
            namingStore: SpeakerNamingStore(outputDir: nil),
            speakerMatcherFactory: { SpeakerMatcher(dbPath: dbPath) },
            outputDir: tmp,
        )
        let mock = NamingSessionMockDelegate()
        session.delegate = mock
        var job = NamingSessionFixture.pendingJob(namingSlug: "standup_abcd1234", transcriptPath: transcriptPath)
        job.mergedFromJobs = ["aaaaaaaa", "cccccccc"]
        mock.jobs[job.id] = job
        session.speakerNamingDataByJob[job.id] = NamingSessionFixture.namingData(jobID: job.id)

        session.completeSpeakerNaming(jobID: job.id, result: .confirmed(["SPEAKER_0": "Alice"]), source: .dialog)

        await waitFor(mock.jobs[job.id]?.state == .done, timeout: .seconds(2))
        let db = SpeakerMatcher(dbPath: dbPath).loadDB()
        XCTAssertEqual(db.first { $0.name == "Alice" }?.samples.count, 0, "the part's sample is undone before the merge teaches")
        XCTAssertEqual(db.first { $0.name == "Bob" }?.samples.map(\.jobID), [unrelated])
        XCTAssertEqual(mock.updateSpeakerDBCallCount, 1, "the merged recording itself is still learned")
    }
}
