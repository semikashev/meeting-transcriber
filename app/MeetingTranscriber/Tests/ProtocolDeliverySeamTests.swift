@testable import MeetingTranscriber
import XCTest

/// Which queues hand a saved protocol to the webhook. The URL lives in the
/// login Keychain, which a scratch home does not move, so a queue that looked
/// it up itself posted every protocol a test saved to the real receiver.
@MainActor
final class ProtocolDeliverySeamTests: XCTestCase {
    private func makeQueue(in dir: URL) -> PipelineQueue {
        PipelineQueue(
            engine: MockEngine(),
            diarizationFactory: { MockDiarization() },
            protocolGeneratorFactory: { MockProtocolGen() },
            outputDir: dir,
            logDir: dir,
            stagingDir: dir,
        )
    }

    func testASavedProtocolIsHandedToTheQueuesDelivery() async throws {
        let dir = try makeTempDirectory(prefix: "protocol_delivery")
        let queue = makeQueue(in: dir)
        let job = PipelineJob(
            meetingTitle: "Standup", appName: "Chrome",
            mixPath: dir.appendingPathComponent("a.wav"), appPath: nil, micPath: nil, micDelay: 0,
        )
        queue.insertJobForTesting(job)
        var delivered: [(job: UUID, title: String, file: String)] = []
        queue.deliverProtocol = { info, path, _ in
            delivered.append((info.jobID, info.title, path.pathExtension))
        }

        try await queue.generateProtocol(jobID: job.id, transcript: "[00:01] A: hi", title: "Standup", protocolsDir: dir)

        XCTAssertEqual(delivered.count, 1)
        XCTAssertEqual(delivered.first?.job, job.id)
        XCTAssertEqual(delivered.first?.title, "Standup")
        XCTAssertEqual(delivered.first?.file, "md")
    }

    /// A warning the delivery raises later lands on the job.
    func testTheDeliverysWarningLandsOnTheJob() async throws {
        let dir = try makeTempDirectory(prefix: "protocol_delivery_warning")
        let queue = makeQueue(in: dir)
        let job = PipelineJob(
            meetingTitle: "Standup", appName: "Chrome",
            mixPath: dir.appendingPathComponent("a.wav"), appPath: nil, micPath: nil, micDelay: 0,
        )
        queue.insertJobForTesting(job)
        queue.deliverProtocol = { _, _, warn in warn("not delivered yet") }

        try await queue.generateProtocol(jobID: job.id, transcript: "[00:01] A: hi", title: "Standup", protocolsDir: dir)

        XCTAssertEqual(queue.jobs.first?.warnings, ["not delivered yet"])
    }

    func testAQueueOfItsOwnDeliversNowhere() throws {
        let dir = try makeTempDirectory(prefix: "protocol_delivery_none")
        XCTAssertNil(makeQueue(in: dir).deliverProtocol)
    }

    func testOnlyTheProductionEnvironmentDelivers() throws {
        let dir = try makeTempDirectory(prefix: "protocol_delivery_env")
        XCTAssertNotNil(PipelineController.QueueEnvironment.production.deliverProtocol)
        XCTAssertNil(IsolatedQueueEnvironment.make(logDir: dir).deliverProtocol)
    }

    func testAQueueTheControllerBuildsTakesTheEnvironmentsDelivery() throws {
        let dir = try makeTempDirectory(prefix: "protocol_delivery_controller")
        var environment = IsolatedQueueEnvironment.make(logDir: dir)
        environment.deliverProtocol = { _, _, _ in }
        let suite = "ProtocolDeliverySeamTests-\(UUID().uuidString)"
        addTeardownBlock { DefaultsSuite.remove(suite) }
        let controller = try PipelineController(
            settings: AppSettings(defaults: XCTUnwrap(DefaultsSuite.open(suite))),
            notifier: SilentNotifier(),
            queueEnvironment: environment,
        )
        let engine = MockEngine()
        controller.activate { engine }

        XCTAssertNotNil(controller.makeQueue()?.deliverProtocol)
    }
}
