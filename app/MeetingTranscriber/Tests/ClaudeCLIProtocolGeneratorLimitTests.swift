#if !APPSTORE
    @testable import MeetingTranscriber
    import XCTest

    /// A run the Claude API turned away: told apart from any other failed run,
    /// and not left waiting for hours.
    final class ClaudeCLIProtocolGeneratorLimitTests: XCTestCase {
        private func event(status: Int?, result: String = "API Error: refused") -> ClaudeCLIProtocolGenerator.ResultEventInfo {
            .init(isError: true, errors: [], result: result, terminalReason: "api_error", apiErrorStatus: status)
        }

        private func failure(status: Int?) -> any Error {
            ClaudeCLIProtocolGenerator.handleFailure(
                exitCode: 1, stderrData: Data(), text: "", resultEvent: event(status: status), arguments: [],
            )
        }

        // MARK: - Waiting

        /// Whatever the user's own sessions wait, and over an inherited value.
        func testBuildEnvironmentCapsTheWaitForAUsageLimit() {
            let env = ClaudeCLIProtocolGenerator.buildEnvironment(
                baseEnvironment: [ClaudeCLIProtocolGenerator.retryWaitLimitVariable: "99999999"], searchPaths: [],
            )
            XCTAssertEqual(env[ClaudeCLIProtocolGenerator.retryWaitLimitVariable], "60000")
        }

        // MARK: - Classification

        func testA429IsTheUsageLimit() {
            guard case let ProtocolError.cliUsageLimit(message) = failure(status: 429) else {
                XCTFail("a 429 was not told apart")
                return
            }
            XCTAssertEqual(message, "API Error: refused")
        }

        func testA403IsABlockedConnection() {
            guard case let ProtocolError.cliBlocked(message) = failure(status: 403) else {
                XCTFail("a 403 was not told apart")
                return
            }
            XCTAssertEqual(message, "API Error: refused")
        }

        func testAnyOtherStatusStaysAFailedRun() {
            for status in [nil, 400, 401, 500] {
                guard case ProtocolError.cliFailed = failure(status: status) else {
                    XCTFail("status \(String(describing: status)) is not a plain failure")
                    return
                }
            }
        }

        /// The terminal event of CLI 2.1.331, recorded against a stub API.
        func testParseResultEventReadsTheStatus() {
            let line = #"{"type":"result","subtype":"success","is_error":true,"result":"API Error: Request rejected (429)","# +
                #""terminal_reason":"api_error","api_error_status":429}"#
            XCTAssertEqual(ClaudeCLIProtocolGenerator.parseResultEvent(line)?.apiErrorStatus, 429)
            XCTAssertNil(ClaudeCLIProtocolGenerator.parseResultEvent(#"{"type":"result","is_error":false}"#)?.apiErrorStatus)
        }

        func testGenerateThrowsTheUsageLimit() async throws {
            let script = try makeExecutableScript(in: makeTempDirectory(prefix: "fake-claude"), name: "claude", body: """
            if [ "$1" = "--help" ]; then
            printf '%s\\n' '  -p, --print  Print response and exit'
            exit 0
            fi
            cat > /dev/null
            printf '%s\\n' '{"type":"result","is_error":true,"result":"limit","terminal_reason":"api_error","api_error_status":429}'
            exit 1
            """)
            let generator = ClaudeCLIProtocolGenerator(claudeBin: script, language: "German", clock: ManualClock())
            do {
                _ = try await generator.generate(transcript: "Speaker 1: hello", title: "Sync", diarized: false)
                XCTFail("a refused run returned")
            } catch ProtocolError.cliUsageLimit {
                // Expected.
            }
        }

        // MARK: - Kinds

        func testTheKindsNameTheReason() {
            XCTAssertEqual(MeetingNotesFailure(ProtocolError.cliUsageLimit("x")), .claudeUsageLimit)
            XCTAssertEqual(MeetingNotesFailure(ProtocolError.cliBlocked("x")), .claudeBlocked)
            XCTAssertEqual(MeetingNotesFailure.claudeUsageLimit.summary, "The Claude usage limit is reached")
            XCTAssertEqual(
                MeetingNotesFailure.claudeBlocked.summary,
                "Claude refused the connection from this network (HTTP 403); check the VPN",
            )
        }
    }
#endif
