@testable import MeetingTranscriber
import XCTest

/// The calendar's say in the browser consent gate: with the option on, a
/// browser meeting that falls into an event with other people in it records
/// without the prompt, and everything else still asks. Driven through the real
/// `start()`/poll path like `WatchLoopBrowserConsentTests`, so the shortcut is
/// exercised where it sits, between the deny list and the prompt.
@MainActor
final class WatchLoopCalendarAutoRecordTests: XCTestCase {
    private final class FixedDetector: MeetingDetecting {
        let meeting: DetectedMeeting
        init(_ meeting: DetectedMeeting) {
            self.meeting = meeting
        }

        func checkOnce() -> DetectedMeeting? {
            meeting
        }

        func isMeetingActive(_: DetectedMeeting) -> Bool {
            true
        }

        func reset(appName _: String?) {}
    }

    /// Answers every prompt with a decline and counts them: a recording that
    /// starts anyway can only have come from the calendar shortcut.
    private final class DecliningSpy: AppNotifying {
        private(set) var prompts = 0

        func notify(title _: String, body _: String, urgency _: NotificationUrgency) {}

        // swiftlint:disable async_without_await
        @MainActor
        func askToRecord(title _: String, body _: String) async -> ConsentAnswer {
            prompts += 1
            return .declined
        }
        // swiftlint:enable async_without_await
    }

    private final class StubCalendarLookup: CalendarMeetingLookup {
        let answer: CalendarMeeting?
        private(set) var askedAppName: String?
        init(answer: CalendarMeeting?) {
            self.answer = answer
        }

        func meeting(startingAt _: Date, appName: String) -> CalendarMeeting? {
            askedAppName = appName
            return answer
        }
    }

    private func browserMeeting(process: String = "Arc") throws -> DetectedMeeting {
        let pattern = try XCTUnwrap(
            PowerAssertionDetector.defaultPatterns
                .first { $0.appName == AppMeetingPattern.browserMeetings.appName },
        )
        return DetectedMeeting(
            pattern: PowerAssertionDetector.meetingIdentity(pattern: pattern, processName: process),
            windowTitle: "\(process) Call",
            ownerName: process,
            windowPID: 5632,
        )
    }

    private func makeLoop(
        lookup: StubCalendarLookup,
        spy: DecliningSpy,
        autoRecord: Bool = true,
        denyListStore: any ConsentDenyListStoring = InMemoryConsentDenyListStore(),
    ) throws -> (WatchLoop, MockRecorder) {
        let recorder = MockRecorder()
        recorder.mixPath = URL(fileURLWithPath: "/tmp/test_calendar_auto_\(UUID().uuidString).wav")
        let loop = try WatchLoop(
            detector: FixedDetector(browserMeeting()),
            recorderFactory: { recorder },
            pollInterval: 0.05,
            endGracePeriod: 0.05,
            notifier: spy,
            denyListStore: denyListStore,
            autoRecordCalendarMeetings: { autoRecord },
            calendarLookup: lookup,
        )
        loop.permissionChecker = {
            HealthCheckResult(screenRecording: .healthy, microphone: .healthy)
        }
        return (loop, recorder)
    }

    private let invitedCall = CalendarMeeting(title: "Weekly sync", attendees: ["Anna"])

    func testAnEventWithAttendeesRecordsWithoutAsking() async throws {
        let spy = DecliningSpy()
        let lookup = StubCalendarLookup(answer: invitedCall)
        let (loop, recorder) = try makeLoop(lookup: lookup, spy: spy)
        loop.start()

        await waitFor(recorder.startCalled, timeout: .seconds(2))

        XCTAssertTrue(recorder.startCalled, "the calendar vouched for the call, so it records")
        XCTAssertEqual(spy.prompts, 0, "and nobody was asked")
        XCTAssertEqual(lookup.askedAppName, "Arc", "the browser is the app the link has to fit")
        loop.stop()
    }

    func testAConferenceLinkIsEnoughWithoutInvitees() async throws {
        let spy = DecliningSpy()
        let lookup = StubCalendarLookup(answer: CalendarMeeting(title: "Interview", attendees: [], hasConferenceLink: true))
        let (loop, recorder) = try makeLoop(lookup: lookup, spy: spy)
        loop.start()

        await waitFor(recorder.startCalled, timeout: .seconds(2))

        XCTAssertTrue(recorder.startCalled)
        XCTAssertEqual(spy.prompts, 0)
        loop.stop()
    }

    /// The user's own block overlapping an ad-hoc call is not a plan to record
    /// that call.
    func testAPersonalBlockStillAsks() async throws {
        let spy = DecliningSpy()
        let lookup = StubCalendarLookup(answer: CalendarMeeting(title: "Focus time", attendees: []))
        let (loop, recorder) = try makeLoop(lookup: lookup, spy: spy)
        loop.start()

        await waitFor(spy.prompts >= 1, timeout: .seconds(2))

        XCTAssertEqual(spy.prompts, 1)
        XCTAssertFalse(recorder.startCalled, "a declined prompt is the only answer there was")
        loop.stop()
    }

    func testNoCalendarEventStillAsks() async throws {
        let spy = DecliningSpy()
        let (loop, recorder) = try makeLoop(lookup: StubCalendarLookup(answer: nil), spy: spy)
        loop.start()

        await waitFor(spy.prompts >= 1, timeout: .seconds(2))

        XCTAssertEqual(spy.prompts, 1)
        XCTAssertFalse(recorder.startCalled)
        loop.stop()
    }

    func testWithTheOptionOffTheCalendarIsNotConsulted() async throws {
        let spy = DecliningSpy()
        let lookup = StubCalendarLookup(answer: invitedCall)
        let (loop, recorder) = try makeLoop(lookup: lookup, spy: spy, autoRecord: false)
        loop.start()

        await waitFor(spy.prompts >= 1, timeout: .seconds(2))

        XCTAssertEqual(spy.prompts, 1, "off means the prompt, as before")
        XCTAssertFalse(recorder.startCalled)
        XCTAssertNil(lookup.askedAppName, "the lookup is not even asked")
        loop.stop()
    }

    /// "Never for this app" is the user's answer and outranks the calendar:
    /// the shortcut sits after the deny list, not before it.
    func testNeverForTheBrowserBeatsTheCalendar() async throws {
        let spy = DecliningSpy()
        let store = InMemoryConsentDenyListStore(denyList: ConsentDenyList(denied: ["Arc"]))
        let (loop, recorder) = try makeLoop(lookup: StubCalendarLookup(answer: invitedCall), spy: spy, denyListStore: store)
        loop.start()

        try? await Task.sleep(nanoseconds: 300_000_000) // several polls

        XCTAssertFalse(recorder.startCalled, "a denied browser must not be recorded, calendar or not")
        XCTAssertEqual(spy.prompts, 0, "and must not be asked either")
        loop.stop()
    }
}
