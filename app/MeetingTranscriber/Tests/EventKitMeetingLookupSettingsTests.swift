@testable import MeetingTranscriber
import XCTest

/// The lookup as the settings build it: the user's conference domains reach
/// it, parsed, and are read on every call rather than captured once, so a
/// change in Settings applies to the next lookup without rebuilding the loop.
/// Only the settings side is exercised; nothing here reads a calendar.
@MainActor
final class EventKitMeetingLookupSettingsTests: XCTestCase {
    func testTheUsersConferenceDomainsReachTheLookupLive() throws {
        let suiteName = "EventKitMeetingLookupSettingsTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { DefaultsSuite.remove(suiteName) }
        let settings = AppSettings(defaults: suite)
        let lookup = EventKitMeetingLookup(settings: settings)
        XCTAssertEqual(lookup.extraConferenceDomains, [], "precondition: none by default")

        settings.extraConferenceDomains = "https://Meet.Example.com/"

        XCTAssertEqual(lookup.extraConferenceDomains, ["meet.example.com"])
    }
}
