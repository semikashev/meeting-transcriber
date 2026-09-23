@testable import MeetingTranscriber
import ViewInspector
import XCTest

/// The auto-record row in the General tab's Calendar section. The lookup it
/// relies on is off without calendar naming, so the row has to look
/// unavailable then rather than like a choice that does nothing.
@MainActor
final class GeneralSettingsAutoRecordTests: XCTestCase {
    private static let rowTitle = "Record browser meetings on the calendar without asking"

    private func makeSettings(calendarTitles: Bool) throws -> AppSettings {
        let suiteName = "GeneralSettingsAutoRecordTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { DefaultsSuite.remove(suiteName) }
        let settings = AppSettings(defaults: suite)
        settings.calendarTitlesEnabled = calendarTitles
        return settings
    }

    private func autoRecordToggle(calendarTitles: Bool) throws -> InspectableView<ViewType.Toggle> {
        let view = try GeneralSettingsView(settings: makeSettings(calendarTitles: calendarTitles), notificationVisibility: nil)
        return try view.inspect().find(ViewType.Toggle.self) { toggle in
            try toggle.labelView().text().string() == Self.rowTitle
        }
    }

    func testTheRowIsDisabledWithoutCalendarNaming() throws {
        XCTAssertTrue(try autoRecordToggle(calendarTitles: false).isDisabled())
    }

    func testTheRowIsAvailableWithCalendarNaming() throws {
        XCTAssertFalse(try autoRecordToggle(calendarTitles: true).isDisabled())
    }

    /// The in-room prompt row shares the gate: same lookup, same reason.
    func testTheInRoomPromptRowFollowsTheSameGate() throws {
        let title = "Offer to record in-person meetings from the microphone"
        let gated = try GeneralSettingsView(settings: makeSettings(calendarTitles: false), notificationVisibility: nil)
            .inspect().find(ViewType.Toggle.self) { try $0.labelView().text().string() == title }
        XCTAssertTrue(gated.isDisabled())
        let open = try GeneralSettingsView(settings: makeSettings(calendarTitles: true), notificationVisibility: nil)
            .inspect().find(ViewType.Toggle.self) { try $0.labelView().text().string() == title }
        XCTAssertFalse(open.isDisabled())
    }

    func testTappingTheRowWritesTheSetting() throws {
        let settings = try makeSettings(calendarTitles: true)
        let view = GeneralSettingsView(settings: settings, notificationVisibility: nil)
        let toggle = try view.inspect().find(ViewType.Toggle.self) { toggle in
            try toggle.labelView().text().string() == Self.rowTitle
        }
        XCTAssertFalse(settings.autoRecordCalendarMeetings, "precondition: opt-in defaults off")

        try toggle.tap()

        XCTAssertTrue(settings.autoRecordCalendarMeetings)
    }
}
