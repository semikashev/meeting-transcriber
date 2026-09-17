import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "InRoomMeetingPrompter")

/// Offers to record the microphone when a calendar meeting that happens in the
/// room begins. Meeting detection sees apps and browsers; a meeting with no
/// call to join is invisible to it, and the menu's "Record Microphone" only
/// helps if remembered. So this watches the calendar instead: when an event
/// with other attendees and no conference link starts, and watching is on with
/// nothing recording, it asks — Record starts a microphone recording, which the
/// calendar then names as usual.
///
/// Owned by `AppState` beside the other controllers and running for the app's
/// lifetime, not tied to the watch loop: starting a microphone recording stops
/// that loop (the controller puts it back afterwards, see
/// `WatchingController.resumeWatchingAfterManualIfNeeded`). The controller it
/// drives is reached through `Hooks`, so the whole thing runs in a test
/// against closures.
@MainActor
final class InRoomMeetingPrompter {
    struct Hooks {
        /// Watching is on and nothing records, so a prompt has something to do.
        let mayPrompt: () -> Bool
        /// Start the microphone recording; true when it actually began.
        let startRecording: () async -> Bool
    }

    private let lookup: any CalendarMeetingLookup
    private let isEnabled: () -> Bool
    private let notifier: any AppNotifying
    private let hooks: Hooks
    private let nowProvider: () -> Date
    private let sleepProvider: (TimeInterval) async throws -> Void
    private let checkInterval: TimeInterval

    /// What has been asked, per event, so the same meeting is not asked about
    /// on every tick. Kept for the process lifetime; the keys are dated, so it
    /// cannot mistake tomorrow's weekly for today's.
    private(set) var history: [InRoomMeetingPolicy.Key: InRoomMeetingPolicy.Record] = [:]
    /// Recordings this prompter started, for tests and the log.
    private(set) var recordingsStarted = 0
    private var task: Task<Void, Never>?

    init(
        lookup: any CalendarMeetingLookup,
        isEnabled: @escaping () -> Bool,
        notifier: any AppNotifying,
        hooks: Hooks,
        nowProvider: @escaping () -> Date = Date.init,
        sleepProvider: @escaping (TimeInterval) async throws -> Void = { interval in
            try await Task.sleep(for: .seconds(interval))
        },
        checkInterval: TimeInterval = 20,
    ) {
        self.lookup = lookup
        self.isEnabled = isEnabled
        self.notifier = notifier
        self.hooks = hooks
        self.nowProvider = nowProvider
        self.sleepProvider = sleepProvider
        self.checkInterval = checkInterval
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await tick()
                try? await sleepProvider(checkInterval)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    /// One look at the clock and the calendar. Exposed for tests, which drive
    /// it directly instead of waiting on the interval.
    func tick() async {
        guard isEnabled(), hooks.mayPrompt() else { return }
        let now = nowProvider()
        guard let event = InRoomMeetingPolicy.candidate(now: now, among: lookup.events(around: now), history: history) else {
            return
        }
        await ask(about: event)
    }

    private func ask(about event: CalendarEventCandidate) async {
        let key = InRoomMeetingPolicy.Key(event)
        history[key, default: InRoomMeetingPolicy.Record()].asks += 1
        logger.info("Asking to record in-room meeting \(event.title, privacy: .private)")
        let answer = await notifier.askToRecordMicrophone(
            title: "Record \"\(event.title)\" from the microphone?",
            body: Self.body(for: event),
        )
        // Only silence is asked again; every answer is final for this event.
        guard answer != .expired else { return }
        history[key]?.isSettled = true
        guard answer.isGranted else { return }
        // Minutes may have passed with the prompt open; the state that made the
        // question worth asking is checked again before acting on the answer.
        guard hooks.mayPrompt() else {
            logger.info("Record tapped, but something is recording or watching stopped — ignoring")
            return
        }
        if await hooks.startRecording() {
            recordingsStarted += 1
            logger.info("Microphone recording started for \(event.title, privacy: .private)")
        }
    }

    /// Who is there, as the invitation lists them, with no attempt at the
    /// user's own name: the calendar drops the current user from attendees.
    static func body(for event: CalendarEventCandidate) -> String {
        let names = event.attendees.prefix(3).joined(separator: ", ")
        let rest = event.attendees.count - min(3, event.attendees.count)
        let who = rest > 0 ? "\(names) and \(rest) more" : names
        return "On your calendar now with \(who). No call link, so nothing records on its own."
    }
}
