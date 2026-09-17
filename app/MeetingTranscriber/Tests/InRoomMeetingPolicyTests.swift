@testable import MeetingTranscriber
import XCTest

/// Which calendar event is worth an in-room prompt, and when to stop asking.
final class InRoomMeetingPolicyTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ minutes: Int) -> Date {
        base.addingTimeInterval(TimeInterval(minutes * 60))
    }

    private func event(
        _ title: String, from: Int, to: Int, attendees: [String] = ["Someone"],
        text: String = "Room 4", allDay: Bool = false, declined: Bool = false,
    ) -> CalendarEventCandidate {
        CalendarEventCandidate(
            title: title, start: at(from), end: at(to), isAllDay: allDay,
            attendees: attendees, conferenceText: text, isDeclined: declined,
        )
    }

    // MARK: - What counts as an in-room meeting

    func testAMeetingWithPeopleAndNoLinkThatHasBegunQualifies() {
        XCTAssertTrue(InRoomMeetingPolicy.isInRoomMeeting(event("Sync", from: 0, to: 60), now: at(1)))
    }

    func testNotBeforeItStarts() {
        XCTAssertFalse(InRoomMeetingPolicy.isInRoomMeeting(event("Sync", from: 0, to: 60), now: at(-1)))
    }

    /// Ten minutes in, the meeting is well under way without a recording; a
    /// prompt then would only record the second half.
    func testNotOnceTheLateWindowHasPassed() {
        XCTAssertTrue(InRoomMeetingPolicy.isInRoomMeeting(event("Sync", from: 0, to: 60), now: at(10)))
        XCTAssertFalse(InRoomMeetingPolicy.isInRoomMeeting(event("Sync", from: 0, to: 60), now: at(11)))
    }

    func testNotAfterItEnds() {
        XCTAssertFalse(InRoomMeetingPolicy.isInRoomMeeting(event("Stand-up", from: 0, to: 5), now: at(6)))
    }

    func testAllDayAndPersonalBlocksDoNotQualify() {
        XCTAssertFalse(InRoomMeetingPolicy.isInRoomMeeting(event("Offsite", from: 0, to: 600, allDay: true), now: at(1)))
        XCTAssertFalse(InRoomMeetingPolicy.isInRoomMeeting(event("Focus", from: 0, to: 60, attendees: []), now: at(1)))
        XCTAssertFalse(InRoomMeetingPolicy.isInRoomMeeting(event("   ", from: 0, to: 60), now: at(1)))
    }

    /// A call to join is meeting detection's business, not the microphone's.
    func testAnyConferenceLinkDisqualifies() {
        let links = [
            "https://zoom.us/j/1", "https://telemost.yandex.ru/j/2", "https://telemost.360.yandex.ru/j/3",
            "https://salutejazz.ru/x", "https://meet.google.com/a-b",
        ]
        for text in links {
            XCTAssertFalse(InRoomMeetingPolicy.isInRoomMeeting(event("Sync", from: 0, to: 60, text: text), now: at(1)), text)
        }
    }

    func testAnInvitationTheUserDeclinedDoesNotQualify() {
        XCTAssertFalse(InRoomMeetingPolicy.isInRoomMeeting(event("Sync", from: 0, to: 60, declined: true), now: at(1)))
    }

    // MARK: - Asking, and asking again

    func testCandidateIsTheMostRecentlyStartedQualifyingEvent() {
        let long = event("All-hands", from: -5, to: 120)
        let nested = event("Breakout", from: 0, to: 30)
        let later = event("Next", from: 30, to: 60)
        let pick = InRoomMeetingPolicy.candidate(now: at(1), among: [later, long, nested], history: [:])
        XCTAssertEqual(pick?.title, "Breakout")
    }

    func testASettledEventIsNotAskedAgain() {
        let sync = event("Sync", from: 0, to: 60)
        let history = [InRoomMeetingPolicy.Key(sync): InRoomMeetingPolicy.Record(asks: 1, isSettled: true)]
        XCTAssertNil(InRoomMeetingPolicy.candidate(now: at(1), among: [sync], history: history))
    }

    func testAnUnansweredEventIsAskedTwiceAtMost() {
        let sync = event("Sync", from: 0, to: 60)
        let once = [InRoomMeetingPolicy.Key(sync): InRoomMeetingPolicy.Record(asks: 1, isSettled: false)]
        XCTAssertEqual(InRoomMeetingPolicy.candidate(now: at(6), among: [sync], history: once)?.title, "Sync")
        let twice = [InRoomMeetingPolicy.Key(sync): InRoomMeetingPolicy.Record(asks: 2, isSettled: false)]
        XCTAssertNil(InRoomMeetingPolicy.candidate(now: at(6), among: [sync], history: twice))
    }

    /// Tomorrow's weekly is a different key from today's, so yesterday's answer
    /// does not silence it.
    func testTheKeyIsDated() {
        let today = event("Weekly", from: 0, to: 60)
        let tomorrow = event("Weekly", from: 24 * 60, to: 25 * 60)
        XCTAssertNotEqual(InRoomMeetingPolicy.Key(today), InRoomMeetingPolicy.Key(tomorrow))
    }
}
