@testable import MeetingTranscriber
import XCTest

/// Which failed notes the app tries again on its own, and when.
final class MeetingNotesAutoRetryPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func failedJob(
        _ failure: MeetingNotesFailure, failedAt: TimeInterval? = -60, startedAt: TimeInterval = -3600,
        notBefore: TimeInterval? = nil, attempts: Int? = nil, transcript: Bool = true,
    ) -> PipelineJob {
        var job = PipelineJob(
            meetingTitle: "Sprint", appName: "Teams", mixPath: nil, appPath: nil, micPath: nil, micDelay: 0,
            meetingStartTime: now.addingTimeInterval(startedAt),
        )
        job.state = .done
        job.notesFailure = failure
        job.transcriptPath = transcript ? URL(fileURLWithPath: "/tmp/sprint.txt") : nil
        job.notesFailedAt = failedAt.map { now.addingTimeInterval($0) }
        job.notesRetryNotBefore = notBefore.map { now.addingTimeInterval($0) }
        job.notesAutoRetries = attempts
        return job
    }

    private func next(_ jobs: PipelineJob...) -> UUID? {
        MeetingNotesAutoRetryPolicy.next(in: jobs, now: now)
    }

    func testTheOldestMeetingGoesFirst() {
        let newer = failedJob(.claudeBlocked, startedAt: -100)
        let older = failedJob(.claudeUsageLimit, startedAt: -200)
        XCTAssertEqual(next(newer, older), older.id)
    }

    func testOnlyFailuresThatCanPassAreRetried() {
        let passing: [MeetingNotesFailure] = [
            .claudeUsageLimit, .claudeBlocked, .claudeSignedOut, .providerUnreachable,
            .claudeFailed, .timedOut, .empty, .providerRejected,
        ]
        for kind in passing {
            let job = failedJob(kind)
            XCTAssertEqual(next(job), job.id, "\(kind) should be retried")
        }
        let lasting: [MeetingNotesFailure] = [.claudeNotFound, .truncated, .noProvider, .transcriptUnreadable, .other]
        for kind in lasting {
            XCTAssertNil(next(failedJob(kind)), "\(kind) fails the same way again")
        }
    }

    func testAJobWithoutATranscriptOrAFailureIsLeftAlone() {
        XCTAssertNil(next(failedJob(.claudeBlocked, transcript: false)))
        var fine = failedJob(.claudeBlocked)
        fine.notesFailure = nil
        XCTAssertNil(next(fine))
    }

    func testAfterAWeekTheAppGivesUp() {
        let week: TimeInterval = 7 * 24 * 3600
        let inside = failedJob(.claudeBlocked, failedAt: -week + 60)
        XCTAssertEqual(next(inside), inside.id)
        XCTAssertNil(next(failedJob(.claudeBlocked, failedAt: -week - 60)))
    }

    /// Failed under a version that did not stamp the time.
    func testAJobWithoutAFailureTimeIsRetried() {
        let job = failedJob(.claudeBlocked, failedAt: nil)
        XCTAssertEqual(next(job), job.id)
    }

    func testAJobIsLeftAloneUntilItsTime() {
        XCTAssertNil(next(failedJob(.timedOut, notBefore: 10)))
        let due = failedJob(.timedOut, notBefore: -10)
        XCTAssertEqual(next(due), due.id)
    }

    /// A run that gets as far as the model costs quota every time; one the
    /// API turns away at the door costs nothing.
    func testCostlyFailuresStopAfterFiveAttemptsAndCheapOnesDoNot() {
        XCTAssertNil(next(failedJob(.timedOut, attempts: 5)))
        let fifth = failedJob(.timedOut, attempts: 4)
        XCTAssertEqual(next(fifth), fifth.id)
        let blocked = failedJob(.claudeBlocked, attempts: 400)
        XCTAssertEqual(next(blocked), blocked.id)
    }

    func testCostlyFailuresWaitAnHour() {
        XCTAssertEqual(MeetingNotesAutoRetryPolicy.delay(after: .timedOut), 3600)
        XCTAssertEqual(MeetingNotesAutoRetryPolicy.delay(after: .claudeFailed), 3600)
        XCTAssertEqual(MeetingNotesAutoRetryPolicy.delay(after: .claudeUsageLimit), 0)
        XCTAssertEqual(MeetingNotesAutoRetryPolicy.delay(after: .claudeBlocked), 0)
    }
}
