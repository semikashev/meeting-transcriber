@testable import MeetingTranscriber
import ViewInspector
import XCTest

/// The title-keyword field under Browser Web Meetings: what is typed lands in
/// the setting, and the field looks unavailable while browser meetings are not
/// watched, since nothing would read it then.
@MainActor
final class GeneralSettingsBrowserTitleTests: XCTestCase {
    private func makeSettings(watchBrowser: Bool) throws -> AppSettings {
        let suiteName = "GeneralSettingsBrowserTitleTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { DefaultsSuite.remove(suiteName) }
        let settings = AppSettings(defaults: suite)
        settings.watchBrowserMeetings = watchBrowser
        return settings
    }

    private func keywordField(_ settings: AppSettings) throws -> InspectableView<ViewType.TextField> {
        try GeneralSettingsView(settings: settings, notificationVisibility: nil).inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.browserAutoRecordTitlesField)
            .find(ViewType.TextField.self)
    }

    func testTypingWritesTheKeywords() throws {
        let settings = try makeSettings(watchBrowser: true)
        XCTAssertEqual(settings.browserAutoRecordTitleKeywords, "", "precondition: opt-in defaults empty")

        try keywordField(settings).setInput("Jitsi Meet")

        XCTAssertEqual(settings.browserAutoRecordTitleKeywords, "Jitsi Meet")
    }

    func testTheFieldIsDisabledWithoutBrowserWatching() throws {
        XCTAssertTrue(try keywordField(makeSettings(watchBrowser: false)).isDisabled())
        XCTAssertFalse(try keywordField(makeSettings(watchBrowser: true)).isDisabled())
    }
}
