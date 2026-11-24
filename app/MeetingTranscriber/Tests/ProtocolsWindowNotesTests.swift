@testable import MeetingTranscriber
import XCTest

/// Generating notes from a row of the Protocols window.
@MainActor
final class ProtocolsWindowNotesTests: XCTestCase {
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var dir: URL!

    override func setUp() async throws {
        try await super.setUp()
        dir = try makeTempDirectory(prefix: "protocols_notes")
    }

    override func tearDown() async throws {
        if let dir { try? FileManager.default.removeItem(at: dir) }
        try await super.tearDown()
    }

    /// The job that failed still knows the meeting, its participants and its
    /// idempotency key, so its retry is used instead of a job of its own.
    func testAJobThatStillHoldsTheTranscriptIsRetried() async throws {
        let (controller, queue) = try makeController()
        let transcript = try writeTranscript("20261030_0900_sprint")
        var job = PipelineJob(meetingTitle: "Sprint", appName: "Teams", mixPath: nil, appPath: nil, micPath: nil, micDelay: 0)
        job.state = .done
        job.namingSlug = "20261030_0900_sprint"
        job.transcriptPath = transcript
        job.notesFailure = .claudeBlocked
        queue.insertJobForTesting(job)

        controller.makeNotes(forTranscript: transcript)
        await queue.awaitProcessing()

        XCTAssertEqual(queue.jobs.map(\.id), [job.id], "a second job was queued for the same transcript")
        XCTAssertNotNil(queue.job(withID: job.id)?.protocolPath)
    }

    func testATranscriptWithoutAJobGetsOne() async throws {
        let (controller, queue) = try makeController()
        let transcript = try writeTranscript("20261030_0900_sprint")

        controller.makeNotes(forTranscript: transcript)
        await queue.awaitProcessing()

        XCTAssertEqual(queue.jobs.count, 1)
        XCTAssertEqual(queue.jobs.first?.protocolPath?.lastPathComponent, "20261030_0900_sprint.md")
    }

    // MARK: - Busy rows

    /// A row whose notes are being made is locked, also when the job was
    /// queued for a transcript and so has no naming slug.
    func testBusyStemsCoverEveryUnfinishedJob() {
        var recording = PipelineJob(meetingTitle: "A", appName: "Teams", mixPath: nil, appPath: nil, micPath: nil, micDelay: 0)
        recording.namingSlug = "20261030_0900_a"
        recording.state = .speakerNamingPending
        var notes = PipelineJob(meetingTitle: "B", appName: "Transcript", mixPath: nil, appPath: nil, micPath: nil, micDelay: 0)
        notes.notesBasename = "20261030_1000_b"
        notes.state = .generatingProtocol
        var finished = PipelineJob(meetingTitle: "C", appName: "Teams", mixPath: nil, appPath: nil, micPath: nil, micDelay: 0)
        finished.namingSlug = "20261030_1100_c"
        finished.state = .done

        XCTAssertEqual(
            ProtocolLibrary.busyStems(of: [recording, notes, finished], merging: ["20261030_1200_d"]),
            ["20261030_0900_a", "20261030_1000_b", "20261030_1200_d"],
        )
    }

    // MARK: - Fixtures

    private func writeTranscript(_ stem: String) throws -> URL {
        let url = dir.appendingPathComponent("\(stem).txt")
        try "[Me] Hello".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func makeController() throws -> (PipelineController, PipelineQueue) {
        let queue = PipelineQueue(
            engine: MockEngine(), diarizationFactory: { MockDiarization() },
            protocolGeneratorFactory: { MockProtocolGen() }, outputDir: dir, logDir: dir,
        )
        let suite = "ProtocolsWindowNotesTests-\(UUID().uuidString)"
        addTeardownBlock { DefaultsSuite.remove(suite) }
        let controller = try PipelineController(
            settings: AppSettings(defaults: XCTUnwrap(DefaultsSuite.open(suite))),
            notifier: SilentNotifier(),
            queueEnvironment: IsolatedQueueEnvironment.make(logDir: dir, initialQueue: queue),
        )
        return (controller, queue)
    }
}
