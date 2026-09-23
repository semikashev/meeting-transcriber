import EventKit
import Foundation
import os

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "CalendarMeetingLookup")

/// Answers "which calendar event was this recording made in?" for `WatchLoop`.
/// Synchronous on purpose: it is consulted once, at enqueue time, and the
/// production implementation reads a local store. Permission is requested
/// from Settings when the feature is switched on, never from the poll loop.
protocol CalendarMeetingLookup {
    func meeting(startingAt start: Date, appName: String) -> CalendarMeeting?

    /// The events around `now`, unranked, for a caller with its own rule
    /// (`InRoomMeetingPolicy`). Defaults to none, so a lookup that only names
    /// recordings need not know about it.
    func events(around now: Date) -> [CalendarEventCandidate]
}

extension CalendarMeetingLookup {
    func events(around _: Date) -> [CalendarEventCandidate] {
        []
    }
}

/// The default: no calendar, window titles as before.
struct NoCalendarLookup: CalendarMeetingLookup {
    func meeting(startingAt _: Date, appName _: String) -> CalendarMeeting? {
        nil
    }
}

/// EventKit-backed lookup over every calendar the user has on the Mac. Reads
/// only: `EKEventStore` with full read access is the same store Calendar.app
/// shows, so a Google or Exchange account added in System Settings works
/// without a login of its own.
///
/// `isEnabled` is read on every call rather than captured once, so switching
/// the feature off in Settings takes effect for the next recording without
/// rebuilding the loop.
final class EventKitMeetingLookup: CalendarMeetingLookup {
    private let isEnabled: () -> Bool
    /// Attendee spelling → the name speaker labels use; see
    /// `ParticipantDisplayName`. Read per lookup, like `isEnabled`.
    private let attendeeAliases: () -> [String: String]
    private let store = EKEventStore()

    /// The window scanned either side of the recording start. Wide enough for
    /// a long all-hands to still be running; the matcher trims it to events
    /// that actually cover the start.
    private static let scanWindow: TimeInterval = 4 * 3600

    init(
        isEnabled: @escaping () -> Bool,
        attendeeAliases: @escaping () -> [String: String] = { ParticipantDisplayName.aliasesFromDefaults() },
    ) {
        self.isEnabled = isEnabled
        self.attendeeAliases = attendeeAliases
    }

    static var hasAccess: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    /// Asks macOS for full (read) access. Called from Settings when the toggle
    /// is switched on; the answer is also what the toggle's footnote reports.
    static func requestAccess() async -> Bool {
        do {
            return try await EKEventStore().requestFullAccessToEvents()
        } catch {
            logger.error("Calendar access request failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    func events(around now: Date) -> [CalendarEventCandidate] {
        guard isEnabled(), Self.hasAccess else { return [] }
        let predicate = store.predicateForEvents(
            withStart: now.addingTimeInterval(-Self.scanWindow),
            end: now.addingTimeInterval(Self.scanWindow),
            calendars: nil,
        )
        let aliases = attendeeAliases()
        return store.events(matching: predicate).compactMap { Self.candidate($0, aliases: aliases) }
    }

    func meeting(startingAt start: Date, appName: String) -> CalendarMeeting? {
        guard isEnabled(), Self.hasAccess else { return nil }
        let candidates = events(around: start)
        guard let match = CalendarMeetingMatcher.bestMatch(recordingStart: start, appName: appName, among: candidates) else {
            logger.info("No calendar event covers the recording start")
            return nil
        }
        logger.info(
            "Calendar event matched: \(match.meeting.title, privacy: .private)\(match.isAmbiguous ? " (another event shares the slot)" : "", privacy: .public)",
        )
        return match.meeting
    }

    /// Birthday and subscribed (holiday) calendars never describe a call, and
    /// a cancelled event is not a meeting anybody attended. `calendar`,
    /// `startDate` and `endDate` are implicitly unwrapped in EventKit; a nil
    /// here would crash after the audio is finalised and before the job
    /// exists, losing the recording, so they are unwrapped by hand.
    private static func candidate(_ event: EKEvent, aliases: [String: String]) -> CalendarEventCandidate? {
        guard event.status != .canceled,
              let calendar = event.calendar as EKCalendar?,
              calendar.type != .birthday, calendar.type != .subscription,
              let start = event.startDate as Date?, let end = event.endDate as Date? else { return nil }
        let attendees = (event.attendees ?? []).compactMap { attendee -> String? in
            guard attendee.participantType == .person, !attendee.isCurrentUser else { return nil }
            if let name = attendee.name, !name.isEmpty { return ParticipantDisplayName.resolve(name, aliases: aliases) }
            let address = attendee.url.absoluteString.replacingOccurrences(of: "mailto:", with: "")
            return address.isEmpty ? nil : ParticipantDisplayName.resolve(address, aliases: aliases)
        }
        let me = (event.attendees ?? []).first(where: \.isCurrentUser)
        return CalendarEventCandidate(
            title: event.title ?? "",
            start: start,
            end: end,
            isAllDay: event.isAllDay,
            attendees: attendees,
            conferenceText: [event.url?.absoluteString, event.location, event.notes].compactMap(\.self).joined(separator: " "),
            isDeclined: me?.participantStatus == .declined,
        )
    }
}
