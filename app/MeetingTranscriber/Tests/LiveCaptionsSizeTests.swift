@testable import MeetingTranscriber
import XCTest

/// The caption-bar size presets. Each preset couples a font size with the
/// panel dimensions that fit it, so the two cannot drift apart in Settings.
final class LiveCaptionsSizeTests: XCTestCase {
    /// `.medium` is the default, so it must reproduce the metrics the bar
    /// shipped with before the preset existed: an existing install sees no
    /// change on upgrade.
    func testMediumMatchesHistoricalOverlayMetrics() {
        XCTAssertEqual(LiveCaptionsSize.medium.fontSize, 22)
        XCTAssertEqual(LiveCaptionsSize.medium.panelSize, CGSize(width: 720, height: 200))
    }

    func testSmallIsTheCompactPreset() {
        XCTAssertEqual(LiveCaptionsSize.small.fontSize, 16)
        XCTAssertEqual(LiveCaptionsSize.small.panelSize, CGSize(width: 520, height: 140))
    }

    /// Every metric grows with the preset. A preset whose panel shrank while
    /// its font grew would clip captions, so the ordering is pinned.
    func testPresetsGrowMonotonically() {
        let ordered: [LiveCaptionsSize] = [.small, .medium, .large]
        for (smaller, larger) in zip(ordered, ordered.dropFirst()) {
            XCTAssertLessThan(smaller.fontSize, larger.fontSize)
            XCTAssertLessThan(smaller.panelSize.width, larger.panelSize.width)
            XCTAssertLessThan(smaller.panelSize.height, larger.panelSize.height)
        }
    }

    /// Raw values are what `UserDefaults` stores. A rename that changed them
    /// would silently reset every user's choice to the default.
    func testRawValuesArePinned() {
        XCTAssertEqual(LiveCaptionsSize.small.rawValue, "small")
        XCTAssertEqual(LiveCaptionsSize.medium.rawValue, "medium")
        XCTAssertEqual(LiveCaptionsSize.large.rawValue, "large")
        XCTAssertEqual(LiveCaptionsSize.allCases, [.small, .medium, .large])
    }

    /// Resizing keeps the bar where the user parked it: same bottom edge,
    /// same horizontal centre. Keeping the bottom-left corner instead would
    /// walk a shrinking bar sideways on every change.
    @MainActor
    func testResizedFrameKeepsBottomCentre() {
        let medium = NSRect(x: 100, y: 60, width: 720, height: 200)

        let small = LiveCaptionsWindowController.resizedFrame(medium, to: .small)

        XCTAssertEqual(small.size, LiveCaptionsSize.small.panelSize)
        XCTAssertEqual(small.midX, medium.midX)
        XCTAssertEqual(small.minY, medium.minY)
    }
}
