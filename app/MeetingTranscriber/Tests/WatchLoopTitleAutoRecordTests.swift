@testable import MeetingTranscriber
import XCTest

/// The window title's say in the browser consent gate: a browser meeting whose
/// window title carries one of the user's keywords records without the
/// prompt, and the same title turning up while a prompt is open answers that
/// prompt. Driven through the real `start()`/poll path like
/// `WatchLoopCalendarAutoRecordTests`, so the shortcut is exercised where it
/// sits, after the deny list and the cooldown.
@MainActor
final class WatchLoopTitleAutoRecordTests: XCTestCase {
    /// Reports whatever meeting the test last put in, so the title can change
    /// between polls the way a browser's front tab does.
    private final class SwappableDetector: MeetingDetecting {
        var meeting: DetectedMeeting
        init(_ meeting: DetectedMeeting) {
            self.meeting = meeting
        }

        func checkOnce() -> DetectedMeeting? {
            meeting
        }

        func isMeetingActive(_: DetectedMeeting) -> Bool {
            true
        }

        func reset(appName _: String?) {}
    }

    /// Answers every prompt with a decline and counts them: a recording that
    /// starts anyway can only have come from the title shortcut.
    private final class DecliningSpy: AppNotifying {
        private(set) var prompts = 0

        func notify(title _: String, body _: String, urgency _: NotificationUrgency) {}

        // swiftlint:disable async_without_await
        @MainActor
        func askToRecord(title _: String, body _: String) async -> ConsentAnswer {
            prompts += 1
            return .declined
        }
        // swiftlint:enable async_without_await
    }

    /// Parks the prompt like the real one, and takes it back the way
    /// `NotificationManager.withdrawBrowserConsent` does.
    private final class ParkingSpy: AppNotifying {
        private(set) var prompts = 0
        private(set) var withdrawals = 0
        private var continuation: CheckedContinuation<ConsentAnswer, Never>?

        var isParked: Bool {
            continuation != nil
        }

        func notify(title _: String, body _: String, urgency _: NotificationUrgency) {}

        @MainActor
        func askToRecord(title _: String, body _: String) async -> ConsentAnswer {
            prompts += 1
            return await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }

        @MainActor
        func withdrawBrowserConsent() {
            guard let continuation else { return }
            self.continuation = nil
            withdrawals += 1
            continuation.resume(returning: .withdrawn)
        }

        func resolveBrowserConsent(granted: Bool) -> Bool {
            guard let continuation else { return false }
            self.continuation = nil
            continuation.resume(returning: granted ? .granted : .declined)
            return true
        }
    }

    private func browserMeeting(title: String, process: String = "Arc") throws -> DetectedMeeting {
        let pattern = try XCTUnwrap(
            PowerAssertionDetector.defaultPatterns
                .first { $0.appName == AppMeetingPattern.browserMeetings.appName },
        )
        return DetectedMeeting(
            pattern: PowerAssertionDetector.meetingIdentity(pattern: pattern, processName: process),
            windowTitle: title,
            ownerName: process,
            windowPID: 5632,
        )
    }

    private func makeLoop(
        detector: SwappableDetector,
        notifier: any AppNotifying,
        keywords: [String] = ["Jitsi Meet"],
        consentPolicy: BrowserConsentPolicy = BrowserConsentPolicy(),
        denyListStore: any ConsentDenyListStoring = InMemoryConsentDenyListStore(),
    ) -> (WatchLoop, MockRecorder) {
        let recorder = MockRecorder()
        recorder.mixPath = URL(fileURLWithPath: "/tmp/test_title_auto_\(UUID().uuidString).wav")
        let loop = WatchLoop(
            detector: detector,
            recorderFactory: { recorder },
            pollInterval: 0.05,
            endGracePeriod: 0.05,
            notifier: notifier,
            browserTitleKeywords: { keywords },
            consentPolicy: consentPolicy,
            denyListStore: denyListStore,
        )
        loop.permissionChecker = {
            HealthCheckResult(screenRecording: .healthy, microphone: .healthy)
        }
        return (loop, recorder)
    }

    private let jitsiTitle = "design-review | Jitsi Meet"

    func testATitleWithAKeywordRecordsWithoutAsking() async throws {
        let spy = DecliningSpy()
        let (loop, recorder) = try makeLoop(detector: SwappableDetector(browserMeeting(title: jitsiTitle)), notifier: spy)
        loop.start()

        await waitFor(recorder.startCalled, timeout: .seconds(2))

        XCTAssertTrue(recorder.startCalled, "the title vouched for the call, so it records")
        XCTAssertEqual(spy.prompts, 0, "and nobody was asked")
        loop.stop()
    }

    func testAnotherTitleStillAsks() async throws {
        let spy = DecliningSpy()
        let (loop, recorder) = try makeLoop(detector: SwappableDetector(browserMeeting(title: "Inbox - Mail")), notifier: spy)
        loop.start()

        await waitFor(spy.prompts >= 1, timeout: .seconds(2))

        XCTAssertEqual(spy.prompts, 1)
        XCTAssertFalse(recorder.startCalled, "a declined prompt is the only answer there was")
        loop.stop()
    }

    func testWithNoKeywordsEveryBrowserMeetingAsks() async throws {
        let spy = DecliningSpy()
        let (loop, recorder) = try makeLoop(
            detector: SwappableDetector(browserMeeting(title: jitsiTitle)), notifier: spy, keywords: [],
        )
        loop.start()

        await waitFor(spy.prompts >= 1, timeout: .seconds(2))

        XCTAssertEqual(spy.prompts, 1, "an empty setting is the prompt, as before")
        XCTAssertFalse(recorder.startCalled)
        loop.stop()
    }

    /// "Never for this app" is the user's answer and outranks the title.
    func testNeverForTheBrowserBeatsTheTitle() async throws {
        let spy = DecliningSpy()
        let store = InMemoryConsentDenyListStore(denyList: ConsentDenyList(denied: ["Arc"]))
        let (loop, recorder) = try makeLoop(
            detector: SwappableDetector(browserMeeting(title: jitsiTitle)), notifier: spy, denyListStore: store,
        )
        loop.start()

        try? await Task.sleep(nanoseconds: 300_000_000) // several polls

        XCTAssertFalse(recorder.startCalled, "a denied browser must not be recorded, title or not")
        XCTAssertEqual(spy.prompts, 0)
        loop.stop()
    }

    /// So is an Ignore still in its cooldown: the title must not talk over it.
    func testAFreshDeclineBeatsTheTitle() async throws {
        let spy = DecliningSpy()
        var policy = BrowserConsentPolicy()
        policy.recordDecline(app: "Arc", now: Date())
        let (loop, recorder) = try makeLoop(
            detector: SwappableDetector(browserMeeting(title: jitsiTitle)), notifier: spy, consentPolicy: policy,
        )
        loop.start()

        try? await Task.sleep(nanoseconds: 300_000_000) // several polls

        XCTAssertFalse(recorder.startCalled, "a decline in its cooldown must hold")
        XCTAssertEqual(spy.prompts, 0)
        loop.stop()
    }

    /// The call was detected while another tab was in front, so the user was
    /// asked. Switching to the call's tab is then the answer: the prompt is
    /// taken back, the recording starts, and it carries the title that
    /// vouched rather than the one the question was asked under.
    func testTheTitleTurningUpWhileAskingAnswersThePrompt() async throws {
        let spy = ParkingSpy()
        let detector = try SwappableDetector(browserMeeting(title: "Chat - Arc"))
        let (loop, recorder) = makeLoop(detector: detector, notifier: spy)
        loop.start()

        await waitFor(spy.isParked, timeout: .seconds(2))
        XCTAssertFalse(recorder.startCalled, "precondition: the first title asks")

        detector.meeting = try browserMeeting(title: jitsiTitle)
        await waitFor(recorder.startCalled, timeout: .seconds(2))

        XCTAssertTrue(recorder.startCalled)
        XCTAssertEqual(spy.withdrawals, 1, "the open prompt is taken back, not left to expire")
        XCTAssertEqual(spy.prompts, 1, "and no second one is posted")
        XCTAssertEqual(loop.currentMeeting?.windowTitle, jitsiTitle)
        // The prompt's task hears `.withdrawn` after the recording has
        // started, so give it a few polls to land before judging what it left.
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(
            loop.consentPolicy.decision(app: "Arc", now: Date()), .ask,
            "a withdrawn prompt is nobody's decline: no cooldown is left behind",
        )
        loop.stop()
    }

    /// Without a matching title the parked prompt stays put: the re-check is
    /// not a second way of reposting it.
    func testAParkedPromptStaysWhileTheTitleDoesNotMatch() async throws {
        let spy = ParkingSpy()
        let (loop, recorder) = try makeLoop(detector: SwappableDetector(browserMeeting(title: "Chat - Arc")), notifier: spy)
        loop.start()

        await waitFor(spy.isParked, timeout: .seconds(2))
        try? await Task.sleep(nanoseconds: 300_000_000) // several polls

        XCTAssertTrue(spy.isParked)
        XCTAssertEqual(spy.withdrawals, 0)
        XCTAssertEqual(spy.prompts, 1)
        XCTAssertFalse(recorder.startCalled)
        _ = spy.resolveBrowserConsent(granted: false)
        loop.stop()
    }
}
