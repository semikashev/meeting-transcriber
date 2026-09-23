import Foundation
@testable import MeetingTranscriber
import XCTest

/// What happens to a payload the webhook could not deliver. The network is
/// `MockURLProtocol` throughout; nothing leaves the process.
final class ProtocolWebhookOutboxTests: XCTestCase {
    // XCTest makes a fresh instance per test, so each test gets its own folder.
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("outbox-\(UUID().uuidString)", isDirectory: true)
    private let endpoint = URL(string: "https://hooks.example/webhook") ?? URL(fileURLWithPath: "/")
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Start from a clean mock whatever an earlier suite left behind.
        MockURLProtocol.handler = nil
        MockURLProtocol.errorHandler = nil
    }

    override func tearDownWithError() throws {
        MockURLProtocol.handler = nil
        MockURLProtocol.errorHandler = nil
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    private func mockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    /// Answer with `codes` in turn (200 once they run out); returns the calls
    /// made so far and the Idempotency-Key of each.
    private func respond(_ codes: [Int]) -> () -> [String?] {
        var remaining = codes
        var keys: [String?] = []
        MockURLProtocol.handler = { request in
            keys.append(request.value(forHTTPHeaderField: "Idempotency-Key"))
            let code = remaining.isEmpty ? 200 : remaining.removeFirst()
            let url = request.url ?? self.endpoint
            return (HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil) ?? HTTPURLResponse(), Data())
        }
        return { keys }
    }

    private func payload(_ id: String = UUID().uuidString) -> ProtocolWebhook.Payload {
        ProtocolWebhook.makePayload(
            job: .init(
                jobID: UUID(uuidString: id) ?? UUID(), title: "Weekly sync", appName: "Zoom",
                meetingStartTime: start, participants: ["Anna"],
            ),
            markdown: "## Summary\nok", protocolFilename: "a.md",
        )
    }

    private func outbox(now: @escaping @Sendable () -> Date = { Date() }) -> ProtocolWebhookOutbox {
        ProtocolWebhookOutbox(directory: directory, now: now)
    }

    /// Retry delays pass at once.
    private func noSleep(_: Duration) {}

    private func file(_ jobID: String) -> URL {
        directory.appendingPathComponent("\(jobID).json")
    }

    func testFailedDeliveryLeavesAnOwnerOnlyFile() async throws {
        MockURLProtocol.errorHandler = { _ in URLError(.notConnectedToInternet) }
        let box = outbox()
        let queued = payload()

        let outcome = await ProtocolWebhook.deliver(
            queued, to: endpoint, outbox: box, session: mockSession(), retryDelays: [.zero], sleep: noSleep,
        )

        guard case .failed = outcome else {
            XCTFail("expected failure, got \(outcome)")
            return
        }
        let pending = await box.pending()
        XCTAssertEqual(pending, [queued.jobID])
        let attributes = try FileManager.default.attributesOfItem(atPath: file(queued.jobID).path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)
    }

    func testRetryThatSucceedsRemovesTheFileAndKeepsTheKey() async {
        let box = outbox()
        let queued = payload()
        await box.save(queued)
        let calls = respond([202])

        let report = await box.flush(url: endpoint, session: mockSession())

        XCTAssertEqual(report.delivered, [queued.jobID])
        XCTAssertEqual(calls(), [queued.jobID], "the job id stays the Idempotency-Key")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file(queued.jobID).path))
    }

    func testRejectionOnRetryRemovesTheFileWithoutRepeating() async {
        let box = outbox()
        let queued = payload()
        await box.save(queued)
        let calls = respond([404])

        let first = await box.flush(url: endpoint, session: mockSession())
        let second = await box.flush(url: endpoint, session: mockSession())

        XCTAssertEqual(first.rejected, [queued.jobID])
        XCTAssertEqual(second, .init())
        XCTAssertEqual(calls().count, 1)
        XCTAssertNotNil(ProtocolWebhookOutbox.notice(for: first))
    }

    func testExpiredEntryIsDroppedUnsent() async {
        let clock = Clock(start)
        let box = outbox { clock.now }
        let queued = payload()
        await box.save(queued)
        let calls = respond([])
        clock.now = start.addingTimeInterval(ProtocolWebhookOutbox.defaultMaxAge + 60)

        let report = await box.flush(url: endpoint, session: mockSession())

        XCTAssertEqual(report.expired, [queued.jobID])
        XCTAssertTrue(calls().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file(queued.jobID).path))
        XCTAssertNotNil(ProtocolWebhookOutbox.notice(for: report))
    }

    func testFailedRetryKeepsEverythingAndStops() async {
        let box = outbox()
        await box.save(payload())
        await box.save(payload())
        var calls = 0
        MockURLProtocol.errorHandler = { _ in
            calls += 1
            return URLError(.timedOut)
        }

        let report = await box.flush(url: endpoint, session: mockSession())

        XCTAssertEqual(report.remaining, 2)
        XCTAssertEqual(calls, 1, "the network is down; the second entry is not tried")
        let pending = await box.pending()
        XCTAssertEqual(pending.count, 2)
        XCTAssertNil(ProtocolWebhookOutbox.notice(for: report))
    }

    func testSuccessfulDeliveryAlsoSendsWhatWasQueued() async {
        let box = outbox()
        let older = payload()
        await box.save(older)
        let fresh = payload()
        let calls = respond([200, 200])

        let outcome = await ProtocolWebhook.deliver(
            fresh, to: endpoint, outbox: box, session: mockSession(), retryDelays: [], sleep: noSleep,
        )

        XCTAssertEqual(outcome, .delivered(status: 200))
        XCTAssertEqual(calls(), [fresh.jobID, older.jobID])
        let pending = await box.pending()
        XCTAssertTrue(pending.isEmpty)
    }

    func testRequeueKeepsTheFirstDate() async throws {
        let clock = Clock(start)
        let box = outbox { clock.now }
        let queued = payload()
        await box.save(queued)
        clock.now = start.addingTimeInterval(3600)
        await box.save(queued)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entry = try decoder.decode(ProtocolWebhookOutbox.Entry.self, from: Data(contentsOf: file(queued.jobID)))
        XCTAssertEqual(entry.createdAt, start)
        XCTAssertEqual(entry.payload, queued)
    }
}

/// A settable clock the outbox can read from its own isolation.
private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ start: Date) {
        value = start
    }

    var now: Date {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}
