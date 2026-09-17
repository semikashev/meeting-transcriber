import Foundation

/// The state-change handler both recording paths install, and what happens
/// to watching when a manual recording ends. Split out of `WatchingController`
/// for the file length cap; `notifier`, `channelHealth` and
/// `liveTranscription` are internal rather than private for that split.
@MainActor
extension WatchingController {
    /// Put watching back if a manual recording took it away. A manual start
    /// stops the auto loop and nothing brought it back, so a microphone
    /// recording in the meeting room left the machine deaf to the next call
    /// until Start Watching was clicked. Called when a manual loop leaves
    /// `.recording` (the menu's Stop, the API's stop, the duration cap) and when
    /// a manual start fails before recording anything. The flag is cleared
    /// first so the start it launches, which fires this handler again via its
    /// own transitions, cannot loop.
    ///
    /// Only a start that captured nothing goes through `rearmWatching`'s
    /// awaited path: the API answers after the loop is settled, and this one
    /// runs detached, which is enough for the menu.
    func resumeWatchingAfterManualIfNeeded() {
        guard resumeWatchingAfterManual else { return }
        resumeWatchingAfterManual = false
        Task { @MainActor [weak self] in
            _ = await self?.startWatching()
        }
    }

    /// Attaches the state-change callback that drives channel-health monitoring
    /// and post-`.error` notifications. Shared between the auto-detect path
    /// (`toggleWatching`) and the manual-recording path (`startManualRecording`)
    /// so the red-tint indicator + asymmetric-silence notification fire in both.
    /// `notifyOnRecording` only fires "Meeting Detected" notifications for the
    /// auto-detect path; manual recording emits its own start notification.
    func attachStateChangeHandler(to loop: WatchLoop, notifyOnRecording: Bool) {
        loop.onStateChange = { [weak self, weak loop, notifier] oldState, newState in
            // Leaving `.recording` (natural meeting end, manual stop, or
            // mid-recording cancel — all route through this transition) is the
            // unified stop signal for both the auto-detect and manual paths.
            // Flush the live pipeline here so the pending tail utterance is
            // committed before the next recording's prepareForNextRecording() clears state. The
            // flush runs after `recorder.stop()` (WatchLoop stops the recorder
            // before this transition fires); the buffered tail lives in the
            // streaming actors, not the recorder, so it survives the stop.
            if oldState == .recording {
                Task { @MainActor in await self?.liveTranscription.flush() }
                self?.resumeWatchingAfterManualIfNeeded()
            }
            switch newState {
            case .recording:
                if notifyOnRecording, let meeting = loop?.currentMeeting {
                    notifier.notify(
                        title: "Meeting Detected",
                        body: "Recording: \(meeting.windowTitle)",
                    )
                }
                // No source means no live recording, so there are no channels to
                // watch and starting the monitor would only assume a topology.
                if let source = self?.watchLoop?.activeRecordingSource {
                    self?.channelHealth.start(source: source) { [weak self] in
                        self?.watchLoop?.activeRecorder
                    }
                }

            case .error:
                if let err = loop?.lastError {
                    notifier.notify(title: "Error", body: err)
                }
                self?.channelHealth.stop()

            default:
                self?.channelHealth.stop()
            }
        }
    }
}
