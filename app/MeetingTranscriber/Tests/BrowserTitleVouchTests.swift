@testable import MeetingTranscriber
import XCTest

/// Pure rule for the window-title shortcut through the browser consent gate:
/// which titles the user's keywords vouch for, and how the setting's text
/// becomes a keyword list.
final class BrowserTitleVouchTests: XCTestCase {
    func testAKeywordInTheTitleVouches() {
        XCTAssertTrue(BrowserTitleVouch.vouches(
            windowTitle: "design-review | Jitsi Meet", appName: "Arc", keywords: ["Jitsi Meet"],
        ))
    }

    func testMatchingIgnoresCase() {
        XCTAssertTrue(BrowserTitleVouch.vouches(
            windowTitle: "design-review | JITSI MEET", appName: "Arc", keywords: ["jitsi meet"],
        ))
    }

    func testATitleWithoutAnyKeywordDoesNotVouch() {
        XCTAssertFalse(BrowserTitleVouch.vouches(
            windowTitle: "Inbox - Mail", appName: "Arc", keywords: ["Jitsi Meet"],
        ))
    }

    func testNoKeywordsVouchForNothing() {
        XCTAssertFalse(BrowserTitleVouch.vouches(windowTitle: "design-review | Jitsi Meet", appName: "Arc", keywords: []))
    }

    /// With no readable window the detector substitutes "<App> Call". That is
    /// the app's own text, not anything the page said, so a keyword such as
    /// "Call" must not turn it into consent for every page in the browser.
    func testThePlaceholderTitleNeverVouches() {
        let placeholder = PowerAssertionDetector.placeholderTitle(appName: "Arc")
        XCTAssertFalse(BrowserTitleVouch.vouches(windowTitle: placeholder, appName: "Arc", keywords: ["Call", "Arc"]))
    }

    func testKeywordsAreSplitOnCommasAndNewlinesAndTrimmed() {
        XCTAssertEqual(
            BrowserTitleVouch.keywords(from: " Jitsi Meet , Whereby\nTelemost ,, \n"),
            ["Jitsi Meet", "Whereby", "Telemost"],
        )
    }

    func testAnEmptySettingHasNoKeywords() {
        XCTAssertEqual(BrowserTitleVouch.keywords(from: "  ,\n "), [])
    }
}
