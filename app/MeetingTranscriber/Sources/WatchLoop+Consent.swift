import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "WatchLoopConsent")

/// Browser-meeting recording-consent gate (issue #503), split out of `WatchLoop`
/// to keep its body under the line-length cap. Only patterns with
/// `requiresRecordingConsent` reach it; native meetings auto-start unchanged.
/// A browser meeting the calendar vouches for may skip the prompt too, when
/// the user opted into that (`calendarVouches(for:)`), and so may one whose
/// window title carries a keyword the user listed (`titleVouches(for:)`).
///
/// The answer is awaited in its own task rather than inline in the poll loop
/// (issue #543). Inline, `detector.checkOnce()` was not called at all while a
/// prompt was open — up to `NotificationManager.consentPromptTimeout` of not
/// looking, during which a Teams or Zoom call that needs no consent went
/// unnoticed. Google Meet raises the same WebRTC assertion on a page you cannot
/// even join, so a stale link was enough to freeze native detection for a
/// minute.
extension WatchLoop {
    /// Whether this meeting has to wait for the user instead of recording now.
    /// Returns immediately in every case.
    ///
    /// True also covers "we are already asking about this app" and "a recent
    /// decline still suppresses the question" — both reasons to skip the
    /// meeting, neither a reason to ask again.
    func requestConsentIfNeeded(for meeting: DetectedMeeting) -> Bool {
        guard meeting.pattern.requiresRecordingConsent else { return false }
        // One question at a time. The WebRTC assertion re-detects the same call
        // every poll, so without this the loop would post a fresh prompt every
        // few seconds while the first one is still on screen.
        if let asking = pendingConsentApp {
            // The one thing that settles the open question before the user
            // does: the call's own tab coming to the front. The call was
            // detected under another tab's title, and the user, now looking at
            // the call, is the least likely person to notice the prompt.
            guard asking == meeting.pattern.appName, titleVouches(for: meeting) else { return true }
            withdrawParkedConsent()
            return false
        }

        let app = meeting.pattern.appName
        guard case .ask = consentPolicy.decision(
            app: app, now: nowProvider(), isDenied: denyListStore.isDenied(app),
        ) else {
            detector.reset(appName: app) // re-detect after the debounce
            return true
        }
        // Checked after the policy, not before it: "Never for this app" and a
        // decline still fresh in the cooldown are answers the user gave, and
        // neither the title nor the calendar may talk over them.
        if titleVouches(for: meeting) || calendarVouches(for: meeting) { return false }

        pendingConsentApp = app
        // `app` is already the concrete browser: a browser meeting is carried
        // under the process that held the assertion, so the debounce above and
        // the name below refer to the same one browser. `ownerName` is kept as
        // the source with a fallback because it is the value the detector read
        // straight off the assertion, and an empty identity would otherwise
        // produce a prompt naming nothing at all.
        let browserName = meeting.ownerName.isEmpty ? app : meeting.ownerName
        consentTask = Task { [weak self] in
            guard let self else { return }
            let answer = await notifier.askToRecord(
                title: "Record browser meeting?",
                body: "A meeting is active in \(browserName).",
            )
            finishConsent(for: meeting, answer: answer)
        }
        return true
    }

    /// Whether the calendar answers the consent question for this browser
    /// meeting. With the setting on, a call that falls into an event the user
    /// was invited to (or that has a link to join) is one they planned to be
    /// in, and the prompt only adds a button they forget to click. A block
    /// with nobody else in it says nothing about a call that happens to
    /// overlap it, so the prompt stays for those. The lookup is the same one
    /// that names the recording, so a calendar the user has not granted, or
    /// the naming feature switched off, keeps this off too.
    private func calendarVouches(for meeting: DetectedMeeting) -> Bool {
        guard autoRecordCalendarMeetings() else { return false }
        let app = meeting.pattern.appName
        guard let event = calendarLookup.meeting(startingAt: nowProvider(), appName: app),
              event.involvesOthers else { return false }
        logger.info("Recording \(app, privacy: .public) without asking: calendar event \(event.title, privacy: .private) is running")
        return true
    }

    /// Whether the browser window's title answers the consent question: it
    /// carries a keyword the user listed for pages that are always calls.
    /// Read from the meeting this poll detected, so a title that changed since
    /// the prompt went out is the one judged.
    private func titleVouches(for meeting: DetectedMeeting) -> Bool {
        let app = meeting.pattern.appName
        guard BrowserTitleVouch.vouches(
            windowTitle: meeting.windowTitle, appName: app, keywords: browserTitleKeywords(),
        ) else { return false }
        logger.info("Recording \(app, privacy: .public) without asking: window title \(meeting.windowTitle, privacy: .private) matches a keyword")
        return true
    }

    /// Take back the open question because the title answered it. The state is
    /// cleared here rather than when the prompt's task sees `.withdrawn`, so
    /// the poll that withdrew it can start the recording at once.
    private func withdrawParkedConsent() {
        notifier.withdrawBrowserConsent()
        clearConsentState()
    }

    /// Take the approved meeting, if any, clearing it. The poll loop is the
    /// only caller: recordings start there and nowhere else, so two of them
    /// cannot overlap.
    func takeApprovedConsentMeeting() -> DetectedMeeting? {
        defer { approvedConsentMeeting = nil }
        return approvedConsentMeeting
    }

    /// Answer a parked prompt as a decline, for `stop()`. Routed through the
    /// notifier so the real prompt's parked continuation completes; without it
    /// the question would linger for the rest of its timeout.
    func declineParkedConsent() {
        guard pendingConsentApp != nil else { return }
        _ = notifier.resolveBrowserConsent(granted: false)
        // Cleared regardless of whether anything was waiting: a notifier with
        // no coordinator behind it never resolves, and a prompt stuck
        // "pending" forever would silence every future question.
        clearConsentState()
    }

    /// Land the user's answer. Main-actor isolated like the rest of
    /// `WatchLoop`, so it cannot race the poll loop's reads.
    private func finishConsent(for meeting: DetectedMeeting, answer: ConsentAnswer) {
        // Taken back by `withdrawParkedConsent`, which already cleared the
        // state and handed the call to the loop. Nothing here is about this
        // prompt any more, and clearing again could only hit a newer one.
        guard answer != .withdrawn else { return }
        let app = meeting.pattern.appName
        clearConsentState()

        guard answer.isGranted else {
            // A refusal and a prompt nobody saw are different facts, and the
            // cooldown treats them differently: ten minutes of quiet after a
            // no, one minute after silence. Never is a third fact and outlives
            // both, and takes no cooldown of its own.
            switch answer {
            case .expired:
                consentPolicy.recordExpiry(app: app, now: nowProvider())

            case .never:
                // No decline cooldown alongside it. The denial already
                // suppresses, and a cooldown would outlive a Settings "Remove"
                // by up to ten minutes, so undoing a mistaken Never would
                // silently keep doing nothing.
                denyListStore.deny(app)

            default:
                consentPolicy.recordDecline(app: app, now: nowProvider())
            }
            detector.reset(appName: app)
            return
        }
        // Minutes can pass between prompt and click, and watching may have been
        // switched off in between — recording then would be recording without
        // having been asked to watch at all.
        guard isActive else {
            logger.info("Consent granted for \(app, privacy: .public) after watching stopped — ignoring")
            return
        }
        // The call itself may also have ended while the question sat there.
        guard detector.isMeetingActive(meeting) else {
            detector.reset(appName: app)
            return
        }
        approvedConsentMeeting = meeting
    }
}
