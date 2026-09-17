import Foundation

/// Pure choice of the calendar event worth offering to record from the
/// microphone: one that has begun, has other people in it and has no call to
/// join, so nothing else in the app is going to notice it. Kept apart from
/// `CalendarMeetingMatcher`, which answers a different question (which event a
/// recording that already exists belongs to).
///
/// An event is asked about at most `maxAsks` times, and only while it is still
/// worth joining (`lateWindow` after its start): the prompt stays open for
/// `NotificationManager.consentPromptTimeout`, so two asks cover ten minutes
/// of a meeting the user is late for. Any answer settles it; only a prompt
/// nobody touched is repeated.
enum InRoomMeetingPolicy {
    /// How long after an event's start a prompt is still worth posting.
    static let lateWindow: TimeInterval = 10 * 60
    static let maxAsks = 2

    /// One event, as the user sees it: a recurring meeting is a new key each
    /// day, a retitled one is a new key, a moved one too.
    struct Key: Hashable, Sendable {
        let title: String
        let start: Date

        init(_ event: CalendarEventCandidate) {
            title = event.title
            start = event.start
        }
    }

    /// What has happened about one event so far.
    struct Record: Equatable, Sendable {
        var asks = 0
        /// The user answered (either way) or a recording started: no more asks.
        var isSettled = false
    }

    /// Whether the event describes a meeting in the room that is on now.
    static func isInRoomMeeting(_ event: CalendarEventCandidate, now: Date) -> Bool {
        guard !event.isAllDay, !event.isDeclined,
              !event.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !event.attendees.isEmpty,
              !CalendarMeetingMatcher.hasConferenceLink(event, forApp: "Microphone") else { return false }
        return event.start <= now && now < event.end && now <= event.start.addingTimeInterval(lateWindow)
    }

    /// The event to ask about now, if any: the one that started most recently
    /// among those not yet settled or asked out.
    static func candidate(
        now: Date, among events: [CalendarEventCandidate], history: [Key: Record],
    ) -> CalendarEventCandidate? {
        events
            .filter { isInRoomMeeting($0, now: now) }
            .filter { event in
                let record = history[Key(event)] ?? Record()
                return !record.isSettled && record.asks < maxAsks
            }
            .max { $0.start < $1.start }
    }
}
