import Foundation
import Network
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "MeetingNotesAutoRetry")

/// Makes failed meeting notes again without being asked: at launch, every
/// `interval`, and a little after the network comes back. Which notes and when
/// is `MeetingNotesAutoRetryPolicy`; the retry itself is the menu's
/// (`PipelineQueue.retryMeetingNotes`), which reads the saved transcript and
/// never overwrites notes that exist.
///
/// One meeting per turn. If it succeeds the next follows at once; if it fails
/// the turn ends, since the others would most likely fail the same way.
@MainActor
final class MeetingNotesAutoRetry {
    private let pipeline: PipelineController
    private let isOnline: () -> Bool
    private let now: () -> Date
    private var tasks: [Task<Void, Never>] = []

    init(
        pipeline: PipelineController,
        now: @escaping () -> Date = Date.init,
        isOnline: @escaping () -> Bool,
    ) {
        self.pipeline = pipeline
        self.isOnline = isOnline
        self.now = now
        pipeline.onAutomaticNotesRetrySucceeded = { [weak self] in
            // Out of the state change that reported it: the queue is still
            // finishing that job.
            Task { @MainActor in self?.retryNext() }
        }
    }

    func retryNext() {
        guard isOnline() else { return }
        let queue = pipeline.queue
        guard let id = MeetingNotesAutoRetryPolicy.next(in: queue.jobs, now: now()) else { return }
        let started = queue.retryMeetingNotes(id: id, automatic: true)
        logger.info("[\(PipelineJob.shortID(for: id), privacy: .public)] notes_auto_retry started=\(started, privacy: .public)")
    }

    /// Started from the app scene, never from `AppState`, which unit tests
    /// construct too. `networkDelay` gives a VPN time to come up behind the
    /// network: without it the first attempt after a wake is refused.
    func start(
        initialDelay: Duration = .seconds(60), interval: Duration = .seconds(15 * 60),
        networkDelay: Duration = .seconds(45), networkReturned: AsyncStream<Void>? = nil,
    ) {
        tasks.append(Task { [weak self] in
            try? await Task.sleep(for: initialDelay)
            while !Task.isCancelled {
                self?.retryNext()
                try? await Task.sleep(for: interval)
            }
        })
        guard let networkReturned else { return }
        tasks.append(Task { [weak self] in
            for await _ in networkReturned {
                try? await Task.sleep(for: networkDelay)
                self?.retryNext()
            }
        })
    }

    deinit {
        for task in tasks {
            task.cancel()
        }
    }
}

/// Whether the Mac has a network path, and when one comes back.
final class NetworkReachability: Sendable {
    private let monitor = NWPathMonitor()
    private let online = OSAllocatedUnfairLock(initialState: true)
    let returned: AsyncStream<Void>

    init() {
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        returned = stream
        monitor.pathUpdateHandler = { [online] path in
            let isOnline = path.status == .satisfied
            let cameBack = online.withLock { was in
                defer { was = isOnline }
                return isOnline && !was
            }
            if cameBack { continuation.yield() }
        }
        monitor.start(queue: DispatchQueue(label: "com.meetingtranscriber.reachability"))
    }

    var isOnline: Bool {
        online.withLock(\.self)
    }

    deinit {
        monitor.cancel()
    }
}
