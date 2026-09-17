@testable import MeetingTranscriber
import XCTest

/// The prompter against closures: what it asks and what it does with the
/// answer. Driven through `tick()` so no interval is waited on.
@MainActor
final class InRoomMeetingPrompterTests: XCTestCase {
    private final class StubLookup: CalendarMeetingLookup {
        var events: [CalendarEventCandidate]
        init(events: [CalendarEventCandidate]) {
            self.events = events
        }

        func meeting(startingAt _: Date, appName _: String) -> CalendarMeeting? {
            nil
        }

        func events(around _: Date) -> [CalendarEventCandidate] {
            events
        }
    }

    private final class PromptSpy: AppNotifying {
        var answer: ConsentAnswer
        private(set) var titles: [String] = []
        private(set) var lastBody = ""
        init(answer: ConsentAnswer) {
            self.answer = answer
        }

        func notify(title _: String, body _: String, urgency _: NotificationUrgency) {}

        // swiftlint:disable async_without_await
        @MainActor
        func askToRecordMicrophone(title: String, body: String) async -> ConsentAnswer {
            titles.append(title)
            lastBody = body
            return answer
        }
        // swiftlint:enable async_without_await
    }

    /// The controller's side, as the prompter sees it.
    private final class Harness {
        var mayPrompt = true
        var startSucceeds = true
        private(set) var starts = 0

        var hooks: InRoomMeetingPrompter.Hooks {
            InRoomMeetingPrompter.Hooks(
                mayPrompt: { [self] in mayPrompt },
                startRecording: { [self] in
                    starts += 1
                    return startSucceeds
                },
            )
        }
    }

    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private var now: Date {
        start.addingTimeInterval(60)
    }

    private func meeting(_ title: String = "Design review", attendees: [String] = ["Anna", "Ben"]) -> CalendarEventCandidate {
        CalendarEventCandidate(
            title: title, start: start, end: start.addingTimeInterval(3600), isAllDay: false,
            attendees: attendees, conferenceText: "Room 4",
        )
    }

    private func makePrompter(
        events: [CalendarEventCandidate], spy: PromptSpy, harness: Harness, enabled: Bool = true,
    ) -> InRoomMeetingPrompter {
        let clock: () -> Date = { [now] in now }
        return InRoomMeetingPrompter(
            lookup: StubLookup(events: events),
            isEnabled: { enabled },
            notifier: spy,
            hooks: harness.hooks,
            nowProvider: clock,
        )
    }

    func testAsksAboutTheMeetingAndStartsRecordingOnRecord() async {
        let spy = PromptSpy(answer: .granted)
        let harness = Harness()
        let prompter = makePrompter(events: [meeting()], spy: spy, harness: harness)

        await prompter.tick()

        XCTAssertEqual(spy.titles, ["Record \"Design review\" from the microphone?"])
        XCTAssertTrue(spy.lastBody.contains("Anna, Ben"), spy.lastBody)
        XCTAssertEqual(harness.starts, 1)
        XCTAssertEqual(prompter.recordingsStarted, 1)
    }

    func testDoesNotAskTwiceAboutOneMeeting() async {
        let spy = PromptSpy(answer: .granted)
        let harness = Harness()
        let prompter = makePrompter(events: [meeting()], spy: spy, harness: harness)

        await prompter.tick()
        await prompter.tick()
        await prompter.tick()

        XCTAssertEqual(spy.titles.count, 1, "an answered meeting is settled")
        XCTAssertEqual(harness.starts, 1)
    }

    func testIgnoreSettlesTheMeetingWithoutRecording() async {
        let spy = PromptSpy(answer: .declined)
        let harness = Harness()
        let prompter = makePrompter(events: [meeting()], spy: spy, harness: harness)

        await prompter.tick()
        await prompter.tick()

        XCTAssertEqual(spy.titles.count, 1)
        XCTAssertEqual(harness.starts, 0)
    }

    /// A prompt nobody touched is repeated once: the user may be walking to
    /// the room. Two unanswered prompts are the end of it.
    func testAnUnansweredPromptIsRepeatedOnce() async {
        let spy = PromptSpy(answer: .expired)
        let harness = Harness()
        let prompter = makePrompter(events: [meeting()], spy: spy, harness: harness)

        await prompter.tick()
        await prompter.tick()
        await prompter.tick()

        XCTAssertEqual(spy.titles.count, 2)
        XCTAssertEqual(harness.starts, 0)
    }

    func testRecordTappedAfterSomethingElseStartedRecordingIsIgnored() async {
        let spy = PromptSpy(answer: .granted)
        let harness = Harness()
        let hooks = harness.hooks
        var reads = 0
        let clock: () -> Date = { [now] in now }
        let prompter = InRoomMeetingPrompter(
            lookup: StubLookup(events: [meeting()]), isEnabled: { true }, notifier: spy,
            hooks: InRoomMeetingPrompter.Hooks(
                // Yes to "may we ask?", no to "may we act?": the answer arrives
                // minutes later, and by then a Zoom call is recording.
                mayPrompt: {
                    reads += 1
                    return reads == 1
                },
                startRecording: hooks.startRecording,
            ),
            nowProvider: clock,
        )

        await prompter.tick()

        XCTAssertEqual(spy.titles.count, 1)
        XCTAssertEqual(harness.starts, 0, "a stale yes must not start a second recording")
    }

    func testAFailedStartIsNotCountedAsARecording() async {
        let spy = PromptSpy(answer: .granted)
        let harness = Harness()
        harness.startSucceeds = false
        let prompter = makePrompter(events: [meeting()], spy: spy, harness: harness)

        await prompter.tick()

        XCTAssertEqual(harness.starts, 1)
        XCTAssertEqual(prompter.recordingsStarted, 0)
    }

    func testNothingHappensWhenOffOrWhenItMayNotPrompt() async {
        let spy = PromptSpy(answer: .granted)
        let harness = Harness()
        let off = makePrompter(events: [meeting()], spy: spy, harness: harness, enabled: false)
        await off.tick()
        XCTAssertEqual(spy.titles.count, 0)

        harness.mayPrompt = false
        let busy = makePrompter(events: [meeting()], spy: spy, harness: harness)
        await busy.tick()
        XCTAssertEqual(spy.titles.count, 0)
    }

    func testBodyNamesUpToThreeAttendees() {
        let event = meeting(attendees: ["Anna", "Ben", "Cara", "Dan", "Eve"])
        XCTAssertEqual(
            InRoomMeetingPrompter.body(for: event),
            "On your calendar now with Anna, Ben, Cara and 2 more. No call link, so nothing records on its own.",
        )
    }
}
