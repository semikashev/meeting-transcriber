import Foundation

/// A calendar event reduced to what matching needs, so the matcher can be
/// exercised without EventKit and the EventKit adapter stays a thin mapping.
struct CalendarEventCandidate: Equatable, Sendable {
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    /// Display names (or addresses) of the other attendees; empty for a
    /// personal block with nobody invited.
    let attendees: [String]
    /// URL, location and notes joined together: where a conference link lives.
    let conferenceText: String
    /// The user answered the invitation with a no. Defaulted because only the
    /// in-room prompt cares: a recording is still named after the event it
    /// happens to fall into.
    var isDeclined = false
    /// Email addresses of the same attendees, where the invitation carries
    /// one. Defaulted for the same reason as `isDeclined`: only the protocol
    /// webhook reads them.
    var attendeeEmails: [String] = []
}

/// What the pipeline learns from a calendar match: the title the recording is
/// filed under, the attendees the protocol can name, and whether the event
/// looks like a call at all.
struct CalendarMeeting: Equatable, Sendable {
    let title: String
    let attendees: [String]
    /// The event carries a link to a conference the app in use could be
    /// showing. Defaulted because most readers only want the name.
    var hasConferenceLink = false
    /// See `CalendarEventCandidate.attendeeEmails`.
    var attendeeEmails: [String] = []

    /// A meeting with other people in it, as opposed to a block the user put
    /// on their own calendar: somebody was invited, or there is a call to
    /// join. Auto-recording keys on this (see `WatchLoop+Consent`).
    var involvesOthers: Bool {
        !attendees.isEmpty || hasConferenceLink
    }
}

/// Pure choice of the calendar event a recording belongs to.
///
/// The event must still be running when the recording starts (an early join
/// is allowed up to `earlyJoin`), because the one failure worth designing
/// around is a call in the free slot after a meeting inheriting that
/// meeting's name. A meeting with others (invitees, or a link to the call)
/// beats a block on one's own calendar even when only the block is running:
/// a webinar joined a minute early was filed under the all-afternoon
/// conference block it fell into. Between two meetings, or two blocks, an
/// event that is running beats one that has not started yet: a recording in
/// the last minutes of a meeting belongs to that meeting, not to the next one
/// on the calendar (measured with the distance alone: the threshold was
/// exactly the early-join window). Among the rest, a conference link
/// pointing at the app in use wins, then events with attendees, then the
/// closest start.
enum CalendarMeetingMatcher {
    /// How long before an event's start a recording may begin and still count.
    static let earlyJoin: TimeInterval = 15 * 60

    struct Match: Equatable {
        let meeting: CalendarMeeting
        /// Another event scored the same, so the choice was arbitrary. Logged,
        /// not surfaced: the usual cause is one meeting present twice (an
        /// external invite plus one's own copy), where either title is right.
        let isAmbiguous: Bool
    }

    /// Every conference service a browser might be showing. Also what decides
    /// that an event has no call to join at all (`InRoomMeetingPolicy`), so a
    /// service missing here turns its online meetings into in-room prompts.
    /// A self-hosted service (a company's own Jitsi, say) cannot be listed
    /// here, so the user adds its domain in Settings and every caller takes it
    /// as `extraDomains` (see `customDomains(from:)`).
    static let anyConferenceDomains = [
        "zoom.us", "teams.microsoft.com", "teams.live.com", "webex.com", "meet.google.com", "whereby.com",
        "telemost.yandex", "telemost.360.yandex", "salutejazz.ru", "jazz.sber.ru", "ktalk.ru", "dion.vc", "vk.com/call", "calls.mail.ru",
        "meet.jit.si", "facetime.apple.com",
    ]

    /// Conference domains a native meeting app implies. A browser implies
    /// nothing in particular, so any conference link counts for it, the
    /// user's own domains included; a native client still implies only its
    /// own service.
    static func conferenceDomains(forApp appName: String, extraDomains: [String] = []) -> [String] {
        let name = appName.lowercased()
        if name.contains("zoom") { return ["zoom.us"] }
        if name.contains("teams") { return ["teams.microsoft.com", "teams.live.com"] }
        if name.contains("webex") { return ["webex.com"] }
        if name.contains("facetime") { return ["facetime.apple.com"] }
        return anyConferenceDomains + extraDomains
    }

    static func hasConferenceLink(_ event: CalendarEventCandidate, forApp appName: String, extraDomains: [String] = []) -> Bool {
        let text = event.conferenceText.lowercased()
        return conferenceDomains(forApp: appName, extraDomains: extraDomains).contains { text.contains($0) }
    }

    /// The user's conference domains from the comma-separated setting, in the
    /// form the substring match above needs: lowercased, without a scheme or
    /// a trailing slash, since what gets pasted is usually a whole address. A
    /// path is kept (the built-in list has `vk.com/call`).
    static func customDomains(from raw: String) -> [String] {
        raw.split { $0 == "," || $0.isWhitespace }
            .map { entry -> String in
                var domain = entry.lowercased()
                for scheme in ["https://", "http://"] where domain.hasPrefix(scheme) {
                    domain.removeFirst(scheme.count)
                }
                while domain.hasSuffix("/") {
                    domain.removeLast()
                }
                return domain
            }
            .filter { !$0.isEmpty }
    }

    static func bestMatch(
        recordingStart: Date, appName: String, among events: [CalendarEventCandidate], extraDomains: [String] = [],
    ) -> Match? {
        let scored: [(CalendarEventCandidate, Int)] = events.compactMap { event in
            let title = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !event.isAllDay, !title.isEmpty else { return nil }
            guard event.start <= recordingStart.addingTimeInterval(earlyJoin),
                  event.end >= recordingStart else { return nil }
            let linked = hasConferenceLink(event, forApp: appName, extraDomains: extraDomains)
            var score = 0
            if !event.attendees.isEmpty || linked { score += 2000 }
            if event.start <= recordingStart { score += 1000 }
            if linked { score += 100 }
            if !event.attendees.isEmpty { score += 10 }
            score -= Int(abs(event.start.timeIntervalSince(recordingStart)) / 60)
            return (event, score)
        }
        guard let top = scored.max(by: { $0.1 < $1.1 }) else { return nil }
        let meeting = CalendarMeeting(
            title: top.0.title.trimmingCharacters(in: .whitespacesAndNewlines),
            attendees: top.0.attendees,
            hasConferenceLink: hasConferenceLink(top.0, forApp: appName, extraDomains: extraDomains),
            attendeeEmails: top.0.attendeeEmails,
        )
        return Match(meeting: meeting, isAmbiguous: scored.filter { $0.1 == top.1 }.count > 1)
    }
}
