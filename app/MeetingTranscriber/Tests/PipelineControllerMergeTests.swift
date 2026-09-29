@testable import MeetingTranscriber
import XCTest

/// What `PipelineController.mergeSessions` does around the audio join: the
/// enqueued job, the guards, and the rule that originals are only trashed
/// after a finished protocol and only when asked.
@MainActor
final class PipelineControllerMergeTests: XCTestCase {
    private final class RemoverSpy: FileRemoving {
        private(set) var removed: [String] = []
        var failOn: String?

        func remove(_ url: URL) throws {
            if let failOn, url.lastPathComponent.contains(failOn) { throw CocoaError(.fileWriteNoPermission) }
            removed.append(url.lastPathComponent)
        }
    }

    private struct FixedCalendar: CalendarMeetingLookup {
        let meetings: [Date: CalendarMeeting]
        func meeting(startingAt start: Date, appName _: String) -> CalendarMeeting? {
            meetings[start]
        }
    }

    // swiftlint:disable:next implicitly_unwrapped_optional
    private var dir: URL!
    private var outputDir: URL {
        dir.appendingPathComponent("output")
    }

    private var recordingsDir: URL {
        outputDir.appendingPathComponent("recordings")
    }

    private var stagingDir: URL {
        dir.appendingPathComponent("staging")
    }

    private let notifier = RecordingNotifier()

    override func setUp() async throws {
        try await super.setUp()
        dir = try makeTempDirectory(prefix: "PipelineControllerMergeTests")
        try FileManager.default.createDirectory(at: recordingsDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let dir { try? FileManager.default.removeItem(at: dir) }
        try await super.tearDown()
    }

    private func makeController() -> PipelineController {
        let pc = PipelineController(settings: AppSettings(), notifier: notifier)
        pc.queue = PipelineQueue(
            engine: MockEngine(),
            diarizationFactory: { MockDiarization() },
            protocolGeneratorFactory: { MockProtocolGen() },
            outputDir: outputDir,
            logDir: dir.appendingPathComponent("logs"),
        )
        // The merged job is only enqueued here; running it is the pipeline's own business.
        pc.queue.isProcessing = true
        return pc
    }

    private func start(_ hour: Int) -> Date {
        var comps = DateComponents()
        comps.year = 2026
        comps.month = 9
        comps.day = 29
        comps.hour = hour
        return Calendar.current.date(from: comps) ?? Date()
    }

    private func session(_ stem: String, hour: Int, title: String, busy: Bool = false) throws -> ProtocolEntry {
        let mix = recordingsDir.appendingPathComponent("\(stem)_mix.wav")
        try AudioMixer.saveWAV(samples: [Float](repeating: 0.1, count: 1600), sampleRate: 16000, url: mix)
        let protocolURL = outputDir.appendingPathComponent("\(stem).md")
        try Data("# \(title)".utf8).write(to: protocolURL)
        return ProtocolEntry(
            stem: stem, recordedAt: start(hour), title: title, protocolURL: protocolURL, transcriptURL: nil,
            audioURLs: [mix], audioBytes: 1, isBusy: busy,
        )
    }

    private func twoSessions() throws -> [ProtocolEntry] {
        try [
            session("20260929_1100_Zoom_bbbbbbbb", hour: 11, title: "Zoom part"),
            session("20260929_1000_Telemost_aaaaaaaa", hour: 10, title: "Telemost part"),
        ]
    }

    // MARK: - Enqueue

    func testMergeEnqueuesOneJobOnTheJoinedAudioWithCalendarParticipants() async throws {
        let pc = makeController()
        let entries = try twoSessions()
        let calendar = FixedCalendar(meetings: [
            start(10): CalendarMeeting(title: "Call", attendees: ["Anna", "Boris"], attendeeEmails: ["a@example.com"]),
            start(11): CalendarMeeting(title: "Call", attendees: ["boris", "Carl"], attendeeEmails: ["c@example.com"]),
        ])

        let id = try await pc.mergeSessions(
            SessionMergeRequest(entries: entries, title: "  Whole call ", deleteOriginals: false),
            outputDir: outputDir, calendar: calendar, stagingDir: stagingDir,
        )

        XCTAssertEqual(pc.queue.jobs.map(\.id), [id])
        let job = try XCTUnwrap(pc.queue.jobs.first)
        XCTAssertEqual(job.meetingTitle, "Whole call")
        XCTAssertEqual(job.participants, ["Anna", "Boris", "Carl"])
        XCTAssertEqual(job.participantEmails, ["a@example.com", "c@example.com"])
        XCTAssertEqual(job.meetingStartTime, start(10))
        XCTAssertEqual(job.mixPath?.deletingLastPathComponent().standardizedFileURL, stagingDir.standardizedFileURL)
        XCTAssertTrue(try XCTUnwrap(job.mixPath).lastPathComponent.hasSuffix("_mix.wav"))
    }

    func testBlankTitleFallsBackToTheFirstSessionsTitle() async throws {
        let pc = makeController()
        try await pc.mergeSessions(
            SessionMergeRequest(entries: twoSessions(), title: "   ", deleteOriginals: false),
            outputDir: outputDir, stagingDir: stagingDir,
        )
        XCTAssertEqual(pc.queue.jobs.first?.meetingTitle, "Telemost part")
    }

    /// The originals must not be picked up again as orphans or reprocessed.
    func testOriginalsAreMarkedProcessedAndLeftInPlace() async throws {
        let pc = makeController()
        let entries = try twoSessions()

        try await pc.mergeSessions(
            SessionMergeRequest(entries: entries, title: "T", deleteOriginals: true),
            outputDir: outputDir, stagingDir: stagingDir,
        )

        let ledger = pc.queue.processedLedger.load()
        for entry in entries {
            XCTAssertTrue(ledger.contains(entry.audioURLs[0].standardizedFileURL.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: entry.audioURLs[0].path), "nothing is deleted at enqueue time")
            XCTAssertTrue(try FileManager.default.fileExists(atPath: XCTUnwrap(entry.protocolURL).path))
        }
    }

    // MARK: - Guards

    func testBusyRowFailsTheMergeBeforeAnythingIsWritten() async throws {
        let pc = makeController()
        let ok = try session("20260929_1000_A_aaaaaaaa", hour: 10, title: "A")
        let busy = try session("20260929_1100_B_bbbbbbbb", hour: 11, title: "B", busy: true)

        do {
            try await pc.mergeSessions(
                SessionMergeRequest(entries: [ok, busy], title: "T", deleteOriginals: false),
                outputDir: outputDir, stagingDir: stagingDir,
            )
            XCTFail("a busy row must refuse the merge")
        } catch {
            XCTAssertEqual(error as? SessionMergeError, .notMergeable(stem: busy.stem, reason: .busy))
        }
        XCTAssertTrue(pc.queue.jobs.isEmpty)
        XCTAssertTrue(pc.mergingStems.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingDir.path))
    }

    func testRecordingsBeingMergedCannotBeMergedAgainUntilTheJobFinishes() async throws {
        let pc = makeController()
        let entries = try twoSessions()
        let request = SessionMergeRequest(entries: entries, title: "T", deleteOriginals: false)
        let id = try await pc.mergeSessions(request, outputDir: outputDir, stagingDir: stagingDir)

        XCTAssertEqual(pc.mergingStems, Set(entries.map(\.stem)))
        do {
            try await pc.mergeSessions(request, outputDir: outputDir, stagingDir: stagingDir)
            XCTFail("second merge of the same rows must be refused")
        } catch {
            XCTAssertEqual(error as? SessionMergeError, .alreadyMerging)
        }
        XCTAssertEqual(pc.queue.jobs.count, 1)

        let job = try XCTUnwrap(pc.queue.jobs.first { $0.id == id })
        pc.finishMerge(job: job, succeeded: false)
        XCTAssertTrue(pc.mergingStems.isEmpty)
    }

    func testFailedRenderReleasesTheRows() async throws {
        let pc = makeController()
        let ok = try session("20260929_1000_A_aaaaaaaa", hour: 10, title: "A")
        let brokenMix = recordingsDir.appendingPathComponent("20260929_1100_B_bbbbbbbb_mix.wav")
        try Data("not audio".utf8).write(to: brokenMix)
        let broken = ProtocolEntry(
            stem: "20260929_1100_B_bbbbbbbb", recordedAt: start(11), title: "B", protocolURL: nil, transcriptURL: nil,
            audioURLs: [brokenMix], audioBytes: 1, isBusy: false,
        )

        do {
            try await pc.mergeSessions(
                SessionMergeRequest(entries: [ok, broken], title: "T", deleteOriginals: true),
                outputDir: outputDir, stagingDir: stagingDir,
            )
            XCTFail("unreadable audio must fail the merge")
        } catch {
            XCTAssertEqual(error as? SessionMergeError, .unreadableAudio(stem: broken.stem))
        }
        XCTAssertTrue(pc.mergingStems.isEmpty)
        XCTAssertTrue(pc.mergeCleanups.isEmpty)
        XCTAssertTrue(pc.queue.jobs.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: brokenMix.path))
    }

    // MARK: - Originals

    private func finishedJob(_ pc: PipelineController, protocolWritten: Bool) throws -> PipelineJob {
        var job = try XCTUnwrap(pc.queue.jobs.first)
        job.protocolPath = protocolWritten ? outputDir.appendingPathComponent("merged.md") : nil
        return job
    }

    func testOriginalsAreTrashedAfterASuccessfulProtocolWhenAsked() async throws {
        let pc = makeController()
        let spy = RemoverSpy()
        pc.originalsRemover = spy
        try await pc.mergeSessions(
            SessionMergeRequest(entries: twoSessions(), title: "T", deleteOriginals: true),
            outputDir: outputDir, stagingDir: stagingDir,
        )

        try pc.finishMerge(job: finishedJob(pc, protocolWritten: true), succeeded: true)

        XCTAssertEqual(
            Set(spy.removed),
            [
                "20260929_1000_Telemost_aaaaaaaa.md", "20260929_1000_Telemost_aaaaaaaa_mix.wav",
                "20260929_1100_Zoom_bbbbbbbb.md", "20260929_1100_Zoom_bbbbbbbb_mix.wav",
            ],
        )
        XCTAssertTrue(notifier.calls.isEmpty)
    }

    func testOriginalsSurviveWithoutTheCheckbox() async throws {
        let pc = makeController()
        let spy = RemoverSpy()
        pc.originalsRemover = spy
        try await pc.mergeSessions(
            SessionMergeRequest(entries: twoSessions(), title: "T", deleteOriginals: false),
            outputDir: outputDir, stagingDir: stagingDir,
        )

        try pc.finishMerge(job: finishedJob(pc, protocolWritten: true), succeeded: true)

        XCTAssertEqual(spy.removed, [])
    }

    func testOriginalsSurviveAFailedMerge() async throws {
        let pc = makeController()
        let spy = RemoverSpy()
        pc.originalsRemover = spy
        try await pc.mergeSessions(
            SessionMergeRequest(entries: twoSessions(), title: "T", deleteOriginals: true),
            outputDir: outputDir, stagingDir: stagingDir,
        )

        try pc.finishMerge(job: finishedJob(pc, protocolWritten: false), succeeded: false)

        XCTAssertEqual(spy.removed, [])
        XCTAssertTrue(pc.mergeCleanups.isEmpty, "the request is dropped, so a later run cannot fire it")
    }

    /// A transcript without a protocol (no generator, or it failed) is not yet
    /// a replacement for the originals.
    func testOriginalsSurviveWhenNoProtocolWasProduced() async throws {
        let pc = makeController()
        let spy = RemoverSpy()
        pc.originalsRemover = spy
        try await pc.mergeSessions(
            SessionMergeRequest(entries: twoSessions(), title: "T", deleteOriginals: true),
            outputDir: outputDir, stagingDir: stagingDir,
        )

        try pc.finishMerge(job: finishedJob(pc, protocolWritten: false), succeeded: true)

        XCTAssertEqual(spy.removed, [])
    }

    func testFailureToTrashOneOriginalIsReported() async throws {
        let pc = makeController()
        let spy = RemoverSpy()
        spy.failOn = "Zoom"
        pc.originalsRemover = spy
        try await pc.mergeSessions(
            SessionMergeRequest(entries: twoSessions(), title: "T", deleteOriginals: true),
            outputDir: outputDir, stagingDir: stagingDir,
        )

        try pc.finishMerge(job: finishedJob(pc, protocolWritten: true), succeeded: true)

        XCTAssertEqual(notifier.calls.map(\.title), ["Could not delete some originals"])
        XCTAssertTrue(notifier.calls[0].body.contains("Zoom part"))
    }

    func testConfiguredCallbackFinishesTheMergeOnDone() async throws {
        let pc = makeController()
        pc.configureCallbacks()
        let spy = RemoverSpy()
        pc.originalsRemover = spy
        try await pc.mergeSessions(
            SessionMergeRequest(entries: twoSessions(), title: "T", deleteOriginals: true),
            outputDir: outputDir, stagingDir: stagingDir,
        )
        let job = try finishedJob(pc, protocolWritten: true)

        pc.queue.onJobStateChange?(job, .generatingProtocol, .done)

        XCTAssertEqual(spy.removed.count, 4)
        XCTAssertTrue(pc.mergingStems.isEmpty)
    }
}
