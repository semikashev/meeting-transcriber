@testable import MeetingTranscriber
import XCTest

/// Watching comes back after a manual recording that took it away. A manual
/// start stops the auto loop; before this nothing brought it back, so a
/// microphone recording in the meeting room left the machine deaf to the next
/// call until Start Watching was clicked. Only watching that was on goes back
/// on: a recording started with watching off leaves it off.
@MainActor
final class WatchingControllerResumeWatchingTests: XCTestCase {
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var tmpDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = try makeTempDirectory(prefix: "WatchingControllerResumeWatchingTests")
    }

    override func tearDown() async throws {
        if let tmpDir { try? FileManager.default.removeItem(at: tmpDir) }
        try await super.tearDown()
    }

    private func controllerWithWatchingOn() -> (WatchingController, WatchLoop) {
        let controller = makeWatchingController(logDir: tmpDir, permissionHealth: .allHealthy)
        let (loop, _) = makeTestWatchLoop()
        loop.start()
        controller.watchLoop = loop
        return (controller, loop)
    }

    func testWatchingResumesAfterAMicrophoneRecordingItWasStoppedFor() async {
        let (controller, existingLoop) = controllerWithWatchingOn()
        addTeardownBlock { await controller.watchLoop?.stop() }
        XCTAssertTrue(controller.isWatching, "precondition")

        controller.startMicrophoneRecording()
        await waitFor(controller.watchLoop?.isManualRecording == true, timeout: .seconds(2))
        XCTAssertFalse(existingLoop.isActive, "the loop taken over from is stopped")
        XCTAssertFalse(controller.isWatching, "not watching while the microphone records")

        controller.stopManualRecording()
        await waitFor(controller.isWatching, timeout: .seconds(3))

        XCTAssertTrue(controller.isWatching, "watching must come back on its own")
        XCTAssertFalse(controller.isManualRecording)
        XCTAssertFalse(controller.resumeWatchingAfterManual, "and the flag is spent")
    }

    /// The same for an app recording from the picker: the takeover is the
    /// same, so the way back is the same.
    func testWatchingResumesAfterAnAppRecordingToo() async {
        let (controller, _) = controllerWithWatchingOn()
        addTeardownBlock { await controller.watchLoop?.stop() }

        controller.startManualRecording(pid: 1234, appName: "Chrome", title: "Standup")
        await waitFor(controller.watchLoop?.isManualRecording == true, timeout: .seconds(2))
        controller.stopManualRecording()
        await waitFor(controller.isWatching, timeout: .seconds(3))

        XCTAssertTrue(controller.isWatching)
    }

    func testWatchingStaysOffWhenItWasOffBefore() async {
        let controller = makeWatchingController(logDir: tmpDir, permissionHealth: .allHealthy)
        XCTAssertFalse(controller.isWatching, "precondition")

        controller.startMicrophoneRecording()
        await waitFor(controller.watchLoop?.isManualRecording == true, timeout: .seconds(2))
        controller.stopManualRecording()
        // Give a wrongly scheduled start every chance to land before asserting.
        try? await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertFalse(controller.isWatching, "a recording started with watching off must not switch it on")
        XCTAssertNil(controller.watchLoop)
    }

    /// A start that captured nothing still took watching away, so it gives it
    /// back too — the menu has no other way to notice.
    func testWatchingResumesWhenTheManualStartIsRefused() async {
        let controller = makeWatchingController(
            logDir: tmpDir,
            permissionHealth: HealthCheckResult(screenRecording: .healthy, microphone: .denied),
        )
        let (loop, _) = makeTestWatchLoop()
        loop.start()
        controller.watchLoop = loop
        addTeardownBlock { await controller.watchLoop?.stop() }
        XCTAssertTrue(controller.isWatching, "precondition")

        let start = controller.beginManualRecording(.microphone)
        let outcome = await start?.value
        XCTAssertEqual(outcome, .permissionRefused, "precondition: the start must be refused")
        await waitFor(controller.isWatching, timeout: .seconds(3))

        XCTAssertTrue(controller.isWatching, "watching must be back after a refused start")
    }
}
