@testable import MeetingTranscriber
import XCTest

/// Failed notes the app makes again on its own: the bookkeeping on the job,
/// the run itself, and what the user hears of it.
@MainActor
final class MeetingNotesAutoRetryTests: XCTestCase {
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var dir: URL!
    private let generator = MockProtocolGen()

    override func setUp() async throws {
        try await super.setUp()
        dir = try makeTempDirectory(prefix: "notes_auto_retry")
    }

    override func tearDown() async throws {
        if let dir { try? FileManager.default.removeItem(at: dir) }
        try await super.tearDown()
    }

    // MARK: - Bookkeeping

    func testTheFirstFailureIsStampedAndLaterOnesKeepIt() throws {
        let queue = makeQueue()
        let id = try insertFailedJob(into: queue, failure: nil)
        let first = Date(timeIntervalSince1970: 1_800_000_000)
        queue.recordNotesFailure(id: id, .claudeBlocked, now: first)
        queue.recordNotesFailure(id: id, .timedOut, now: first.addingTimeInterval(900))

        let job = try XCTUnwrap(queue.job(withID: id))
        XCTAssertEqual(job.notesFailedAt, first)
        XCTAssertEqual(job.notesRetryNotBefore, first.addingTimeInterval(900 + 3600), "a costly failure waits an hour")
    }

    func testSavedNotesClearTheBookkeeping() async throws {
        let queue = makeQueue()
        let id = try insertFailedJob(into: queue)
        XCTAssertTrue(queue.retryMeetingNotes(id: id, automatic: true))
        await queue.awaitProcessing()

        let job = try XCTUnwrap(queue.job(withID: id))
        XCTAssertNotNil(job.protocolPath)
        XCTAssertNil(job.notesFailedAt)
        XCTAssertNil(job.notesRetryNotBefore)
        XCTAssertNil(job.notesAutoRetries)
    }

    func testAnAutomaticRetryCountsAndAManualOneDoesNot() async throws {
        generator.shouldThrow = true
        generator.errorToThrow = ProtocolError.emptyProtocol
        let queue = makeQueue()
        let id = try insertFailedJob(into: queue)
        XCTAssertTrue(queue.retryMeetingNotes(id: id, automatic: true))
        await queue.awaitProcessing()
        XCTAssertEqual(queue.job(withID: id)?.notesAutoRetries, 1)
        XCTAssertTrue(queue.retryMeetingNotes(id: id))
        await queue.awaitProcessing()
        XCTAssertEqual(queue.job(withID: id)?.notesAutoRetries, 1)
    }

    func testTheBookkeepingSurvivesARelaunch() throws {
        let queue = makeQueue()
        let id = try insertFailedJob(into: queue, failure: nil)
        let first = Date(timeIntervalSince1970: 1_800_000_000)
        queue.recordNotesFailure(id: id, .timedOut, now: first)
        queue.saveSnapshot()

        let restored = makeQueue()
        restored.loadSnapshot()
        XCTAssertEqual(restored.job(withID: id)?.notesFailedAt, first)
        XCTAssertEqual(restored.job(withID: id)?.notesRetryNotBefore, first.addingTimeInterval(3600))
    }

    // MARK: - The run

    func testARetryMakesTheNotes() async throws {
        let queue = makeQueue()
        let id = try insertFailedJob(into: queue)
        let retry = try makeRetry(queue)

        retry.retryNext()
        await queue.awaitProcessing()

        XCTAssertNotNil(queue.job(withID: id)?.protocolPath)
    }

    func testNothingRunsWhileOffline() throws {
        let queue = makeQueue()
        let id = try insertFailedJob(into: queue)
        let retry = try makeRetry(queue, online: false)
        retry.retryNext()
        XCTAssertEqual(queue.job(withID: id)?.state, .done)
        XCTAssertFalse(generator.generateCalled)
    }

    /// One success means the way is open: the rest follow without waiting for
    /// the next turn.
    func testASuccessLeadsToTheNextMeeting() async throws {
        let queue = makeQueue()
        let first = try insertFailedJob(into: queue, stem: "20261030_0900_sprint")
        let second = try insertFailedJob(into: queue, stem: "20261031_1000_review")
        let retry = try makeRetry(queue)

        retry.retryNext()
        await queue.awaitProcessing()
        await waitFor(queue.job(withID: second)?.protocolPath != nil, timeout: .seconds(3))

        XCTAssertNotNil(queue.job(withID: first)?.protocolPath)
        XCTAssertNotNil(queue.job(withID: second)?.protocolPath)
    }

    /// A failure does not: the next one would fail the same way.
    func testAFailureEndsTheTurn() async throws {
        generator.shouldThrow = true
        generator.errorToThrow = ProtocolError.connectionFailed("down")
        let queue = makeQueue()
        try insertFailedJob(into: queue, stem: "20261030_0900_sprint")
        let second = try insertFailedJob(into: queue, stem: "20261031_1000_review")
        let retry = try makeRetry(queue)

        retry.retryNext()
        await queue.awaitProcessing()
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertNil(queue.job(withID: second)?.notesAutoRetries)
    }

    // MARK: - When it runs

    func testItRunsAfterTheLaunchDelay() async throws {
        let queue = makeQueue()
        let id = try insertFailedJob(into: queue)
        let retry = try makeRetry(queue)

        retry.start(initialDelay: .milliseconds(20), interval: .seconds(3600))
        await waitFor(queue.job(withID: id)?.protocolPath != nil, timeout: .seconds(3))

        XCTAssertNotNil(queue.job(withID: id)?.protocolPath)
    }

    func testItRunsAgainAfterTheInterval() async throws {
        generator.shouldThrow = true
        generator.errorToThrow = ProtocolError.connectionFailed("down")
        let queue = makeQueue()
        let id = try insertFailedJob(into: queue)
        let retry = try makeRetry(queue)

        retry.start(initialDelay: .milliseconds(10), interval: .milliseconds(30))
        await waitFor((queue.job(withID: id)?.notesAutoRetries ?? 0) >= 2, timeout: .seconds(3))

        XCTAssertGreaterThanOrEqual(queue.job(withID: id)?.notesAutoRetries ?? 0, 2)
    }

    func testItRunsWhenTheNetworkComesBack() async throws {
        let queue = makeQueue()
        let id = try insertFailedJob(into: queue)
        let retry = try makeRetry(queue)
        let (network, continuation) = AsyncStream<Void>.makeStream()

        retry.start(initialDelay: .seconds(3600), networkDelay: .milliseconds(10), networkReturned: network)
        continuation.yield()
        await waitFor(queue.job(withID: id)?.protocolPath != nil, timeout: .seconds(3))

        XCTAssertNotNil(queue.job(withID: id)?.protocolPath)
    }

    // MARK: - What the user hears

    func testTheFirstFailureSaysTheAppTriesAgain() {
        var job = PipelineJob(meetingTitle: "Sprint", appName: "Teams", mixPath: nil, appPath: nil, micPath: nil, micDelay: 0)
        job.state = .done
        job.transcriptPath = URL(fileURLWithPath: "/tmp/sprint.txt")
        job.notesFailure = .claudeBlocked
        let note = PipelineQueue.doneNotification(for: job, announceNotesFailure: true)
        XCTAssertEqual(
            note.body,
            "\"Sprint\": Claude refused the connection from this network (HTTP 403); check the VPN. "
                + "The transcript is saved. The app tries again on its own.",
        )
    }

    func testAFailureThatIsNotRetriedDoesNotPromiseIt() {
        var job = PipelineJob(meetingTitle: "Sprint", appName: "Teams", mixPath: nil, appPath: nil, micPath: nil, micDelay: 0)
        job.state = .done
        job.transcriptPath = URL(fileURLWithPath: "/tmp/sprint.txt")
        job.notesFailure = .truncated
        let note = PipelineQueue.doneNotification(for: job, announceNotesFailure: true)
        XCTAssertFalse(note.body.contains("tries again"))
    }

    func testAnAutomaticRetryThatFailsAgainIsSilentAndOneThatWorksIsNot() async throws {
        generator.shouldThrow = true
        generator.errorToThrow = ProtocolError.connectionFailed("down")
        let queue = makeQueue()
        let id = try insertFailedJob(into: queue)
        let notifier = RecordingNotifier()
        let retry = try makeRetry(queue, notifier: notifier)

        retry.retryNext()
        await queue.awaitProcessing()
        XCTAssertEqual(queue.job(withID: id)?.state, .done)
        XCTAssertTrue(notifier.calls.isEmpty, "a retry nobody asked for reported its failure")

        generator.shouldThrow = false
        retry.retryNext()
        await queue.awaitProcessing()
        XCTAssertEqual(notifier.calls.map(\.title), ["Meeting Notes Ready"])
    }

    func testAManualRetryThatFailsSaysSo() async throws {
        generator.shouldThrow = true
        generator.errorToThrow = ProtocolError.connectionFailed("down")
        let queue = makeQueue()
        let id = try insertFailedJob(into: queue)
        let notifier = RecordingNotifier()
        _ = try makeRetry(queue, notifier: notifier)

        XCTAssertTrue(queue.retryMeetingNotes(id: id))
        await queue.awaitProcessing()
        XCTAssertEqual(notifier.calls.map(\.title), ["Meeting Notes Failed"])
    }

    // MARK: - Fixtures

    private var controllers: [PipelineController] = []

    /// A retry over a controller that starts with `queue`, its callbacks wired.
    private func makeRetry(
        _ queue: PipelineQueue, online: Bool = true, notifier: any AppNotifying = SilentNotifier(),
    ) throws -> MeetingNotesAutoRetry {
        let suite = "MeetingNotesAutoRetryTests-\(UUID().uuidString)"
        addTeardownBlock { DefaultsSuite.remove(suite) }
        let controller = try PipelineController(
            settings: AppSettings(defaults: XCTUnwrap(DefaultsSuite.open(suite))),
            notifier: notifier,
            queueEnvironment: IsolatedQueueEnvironment.make(logDir: dir, initialQueue: queue),
        )
        controller.configureCallbacks()
        controllers.append(controller)
        return MeetingNotesAutoRetry(pipeline: controller) { online }
    }

    private func makeQueue() -> PipelineQueue {
        PipelineQueue(
            engine: MockEngine(), diarizationFactory: { MockDiarization() },
            protocolGeneratorFactory: { [generator] in generator },
            outputDir: dir, logDir: dir,
        )
    }

    @discardableResult
    private func insertFailedJob(
        into queue: PipelineQueue, stem: String = "20261030_0900_sprint", failure: MeetingNotesFailure? = .claudeBlocked,
    ) throws -> UUID {
        let transcript = dir.appendingPathComponent("\(stem).txt")
        try "[Me] Hello".write(to: transcript, atomically: true, encoding: .utf8)
        var job = PipelineJob(meetingTitle: "Sprint", appName: "Teams", mixPath: nil, appPath: nil, micPath: nil, micDelay: 0)
        job.state = .done
        job.namingSlug = stem
        job.transcriptPath = transcript
        job.notesFailure = failure
        queue.insertJobForTesting(job)
        return job.id
    }
}
