import Foundation
@testable import MeetingTranscriber
import XCTest

final class ProtocolWebhookTests: XCTestCase {
    private let job = ProtocolWebhook.JobInfo(
        jobID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
        title: "Weekly sync",
        appName: "Microsoft Teams",
        meetingStartTime: Date(timeIntervalSince1970: 1_790_000_000),
        participants: ["Anna", "Boris"],
    )

    override func tearDown() {
        MockURLProtocol.handler = nil
        MockURLProtocol.errorHandler = nil
        super.tearDown()
    }

    private func mockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func respond(_ codes: [Int]) -> () -> Int {
        var remaining = codes
        var calls = 0
        MockURLProtocol.handler = { request in
            calls += 1
            let code = remaining.isEmpty ? 200 : remaining.removeFirst()
            return (HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!, Data())
        }
        return { calls }
    }

    // MARK: - Configuration

    func testConfiguredURLAcceptsHTTPSAndTrimsWhitespace() {
        let url = ProtocolWebhook.configuredURL { _ in "  https://multica.example/api/webhooks/autopilots/tok\n" }
        XCTAssertEqual(url?.absoluteString, "https://multica.example/api/webhooks/autopilots/tok")
    }

    func testConfiguredURLRejectsMissingOrNonHTTPValues() {
        XCTAssertNil(ProtocolWebhook.configuredURL { _ in nil })
        XCTAssertNil(ProtocolWebhook.configuredURL { _ in "" })
        XCTAssertNil(ProtocolWebhook.configuredURL { _ in "file:///etc/passwd" })
        XCTAssertNil(ProtocolWebhook.configuredURL { _ in "not a url" })
    }

    func testFingerprintNeverContainsThePath() throws {
        let url = try XCTUnwrap(URL(string: "https://multica.example/api/webhooks/autopilots/secret-token"))
        let fingerprint = ProtocolWebhook.fingerprint(of: url)
        XCTAssertTrue(fingerprint.hasPrefix("multica.example · "))
        XCTAssertFalse(fingerprint.contains("secret"))
    }

    // MARK: - Payload

    func testPayloadCarriesMeetingFieldsAndProtocol() throws {
        let payload = ProtocolWebhook.makePayload(job: job, markdown: "## Summary\nok", protocolFilename: "a.md")
        let request = try ProtocolWebhook.makeRequest(url: XCTUnwrap(URL(string: "https://h/x")), payload: payload)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Idempotency-Key"), job.jobID.uuidString)

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(json["event"] as? String, "protocol.ready")
        XCTAssertEqual(json["version"] as? Int, 1)
        XCTAssertEqual(json["title"] as? String, "Weekly sync")
        XCTAssertEqual(json["app"] as? String, "Microsoft Teams")
        XCTAssertEqual(json["participants"] as? [String], ["Anna", "Boris"])
        XCTAssertEqual(json["protocol_filename"] as? String, "a.md")
        XCTAssertEqual(json["protocol_markdown"] as? String, "## Summary\nok")
        XCTAssertEqual(json["truncated"] as? Bool, false)
        XCTAssertNotNil(json["meeting_start"] as? String)
    }

    func testPayloadCarriesParticipantEmailsWhenKnown() throws {
        var withEmails = job
        withEmails.participantEmails = ["anna@example.com", "boris@example.org"]
        let payload = ProtocolWebhook.makePayload(job: withEmails, markdown: "ok", protocolFilename: "a.md")
        let request = try ProtocolWebhook.makeRequest(url: XCTUnwrap(URL(string: "https://h/x")), payload: payload)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(json["participant_emails"] as? [String], ["anna@example.com", "boris@example.org"])
        XCTAssertEqual(json["participants"] as? [String], ["Anna", "Boris"])
        XCTAssertEqual(json["version"] as? Int, 1, "an added field does not bump the version")
    }

    func testPayloadLeavesParticipantEmailsOutWhenUnknown() throws {
        let payload = ProtocolWebhook.makePayload(job: job, markdown: "ok", protocolFilename: "a.md")
        let request = try ProtocolWebhook.makeRequest(url: XCTUnwrap(URL(string: "https://h/x")), payload: payload)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertNil(json["participant_emails"], "same shape as a payload sent before the field existed")
    }

    func testFitDropsFullTranscriptBeforeCutting() {
        let head = "## Summary\nshort"
        let markdown = head + ProtocolWebhook.fullTranscriptMarker + String(repeating: "x", count: 500)
        let (text, truncated) = ProtocolWebhook.fit(markdown, limit: 100)
        XCTAssertEqual(text, head)
        XCTAssertTrue(truncated)
    }

    func testCutProtocolStaysUnderReceiverBodyCap() throws {
        // No transcript marker, so the text itself is cut; short lines with
        // quotes are the worst realistic case for JSON escaping.
        let markdown = String(repeating: "[Анна] Проверим \"квоту\".\n", count: 20000)
        let payload = ProtocolWebhook.makePayload(job: job, markdown: markdown, protocolFilename: "a.md")
        let request = try ProtocolWebhook.makeRequest(url: XCTUnwrap(URL(string: "https://h/x")), payload: payload)
        XCTAssertTrue(payload.truncated)
        XCTAssertLessThanOrEqual(try XCTUnwrap(request.httpBody).count, ProtocolWebhook.maxBodyBytes)
    }

    func testFitCutsOnCharacterBoundary() {
        let (text, truncated) = ProtocolWebhook.fit(String(repeating: "я", count: 10), limit: 7)
        XCTAssertEqual(text, "яяя")
        XCTAssertTrue(truncated)
        XCTAssertEqual(ProtocolWebhook.fit("ok", limit: 7).0, "ok")
    }

    // MARK: - Delivery

    private func send(_ session: URLSession) async -> ProtocolWebhook.Outcome {
        let request = URLRequest(url: URL(string: "https://h/x")!)
        return await ProtocolWebhook.send(
            request, session: session, retryDelays: [.zero, .zero], sleep: { _ in },
        )
    }

    func testDeliveredOn2xx() async {
        let calls = respond([200])
        let outcome = await send(mockSession())
        XCTAssertEqual(outcome, .delivered(status: 200))
        XCTAssertEqual(calls(), 1)
    }

    func testRetriesServerErrorsThenDelivers() async {
        let calls = respond([503, 429, 202])
        let outcome = await send(mockSession())
        XCTAssertEqual(outcome, .delivered(status: 202))
        XCTAssertEqual(calls(), 3)
    }

    func testClientErrorIsNotRetried() async {
        let calls = respond([404, 200])
        let outcome = await send(mockSession())
        XCTAssertEqual(outcome, .rejected(status: 404))
        XCTAssertEqual(calls(), 1)
    }

    func testGivesUpAfterRetriesOnTransportError() async {
        var calls = 0
        MockURLProtocol.errorHandler = { _ in
            calls += 1
            return URLError(.cannotConnectToHost)
        }
        let outcome = await send(mockSession())
        guard case .failed = outcome else { return XCTFail("expected failure, got \(outcome)") }
        XCTAssertEqual(calls, 3)
    }
}
