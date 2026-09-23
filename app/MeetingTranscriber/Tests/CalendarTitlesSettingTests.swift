@testable import MeetingTranscriber
import XCTest

/// The calendar-titles preference's write path, in its own file for the same
/// reason as `LiveCaptionsOverlaySettingTests`: `AppSettingsTests` pins only
/// the default.
final class CalendarTitlesSettingTests: XCTestCase {
    private func scratchDefaults(_ prefix: String) throws -> UserDefaults {
        let name = "\(prefix)-\(getpid())-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { DefaultsSuite.remove(name) }
        return defaults
    }

    func testPersistsAcrossInstances() throws {
        let defaults = try scratchDefaults("calendar-titles")
        let settings = AppSettings(defaults: defaults)
        XCTAssertFalse(settings.calendarTitlesEnabled, "opt-in: it asks for a Calendar permission")

        settings.calendarTitlesEnabled = true

        XCTAssertEqual(defaults.object(forKey: "calendarTitlesEnabled") as? Bool, true)
        XCTAssertTrue(
            AppSettings(defaults: defaults).calendarTitlesEnabled,
            "the choice has to survive a relaunch",
        )
    }

    func testAutoRecordPersistsAcrossInstances() throws {
        let defaults = try scratchDefaults("calendar-auto-record")
        let settings = AppSettings(defaults: defaults)
        XCTAssertFalse(settings.autoRecordCalendarMeetings, "opt-in: it starts recordings nobody clicked for")

        settings.autoRecordCalendarMeetings = true

        XCTAssertEqual(defaults.object(forKey: "autoRecordCalendarMeetings") as? Bool, true)
        XCTAssertTrue(AppSettings(defaults: defaults).autoRecordCalendarMeetings)
    }

    func testInRoomPromptPersistsAcrossInstances() throws {
        let defaults = try scratchDefaults("in-room-prompt")
        let settings = AppSettings(defaults: defaults)
        XCTAssertFalse(settings.promptInRoomMeetings, "opt-in: it posts prompts on a schedule")

        settings.promptInRoomMeetings = true

        XCTAssertEqual(defaults.object(forKey: "promptInRoomMeetings") as? Bool, true)
        XCTAssertTrue(AppSettings(defaults: defaults).promptInRoomMeetings)
    }
}
