import Foundation

// MARK: - AppNotifying

/// Notification abstraction that keeps AppKit out of AppState.
///
/// Real implementation: `NotificationManager` (AppKit, used in menu bar app).
/// Test implementation: `RecordingNotifier` (records calls, no side effects).
protocol AppNotifying {
    /// The urgency is part of the requirement, not a defaulted convenience, so
    /// that a conformer which ignores it has to say so. The reverse shape (a
    /// 2-arg requirement plus a defaulted 3-arg extension) compiles just as
    /// well and silently downgrades every time-sensitive notification a
    /// forgetful conformer receives, which is the exact failure this urgency
    /// exists to prevent. `notify(title:body:)` lives in the extension below.
    func notify(title: String, body: String, urgency: NotificationUrgency)

    /// Ask the user whether to record a just-detected browser meeting (issue
    /// #503); true = record. `@MainActor` — the real prompt is UI. Defaults to
    /// false so a notifier without a prompt never records silently.
    @MainActor
    func askToRecord(title: String, body: String) async -> ConsentAnswer

    /// Ask whether to record a calendar meeting happening in the room from the
    /// microphone (`InRoomMeetingPrompter`). Same contract as `askToRecord`;
    /// defaults to it, so a double that answers one answers both.
    @MainActor
    func askToRecordMicrophone(title: String, body: String) async -> ConsentAnswer

    /// Resolve a parked `askToRecord` prompt programmatically (the debug-RPC
    /// consent hook, issue #503); returns whether one was waiting. Lives on the
    /// same seam as `askToRecord` so park + resolve share it. Defaults to false
    /// (no prompt) for notifiers without a real coordinator.
    func resolveBrowserConsent(granted: Bool) -> Bool

    /// How a posted notification would be presented. On the same seam as
    /// `askToRecord` because it answers whether that prompt could be SEEN, which
    /// decides whether browser meetings work at all (see
    /// `BrowserConsentReadiness`).
    ///
    /// Here rather than as a probe closure on `PermissionsController` because
    /// `NotificationManager` already owns both the scheduler port and the
    /// `canDeliver` bundle guard this read needs; a separate closure would
    /// re-derive that guard and add a second injection point to every test that
    /// already injects a notifier.
    ///
    /// `@MainActor` for the same reason as `askToRecord`: `AppNotifying` is not
    /// Sendable, so a non-isolated async requirement would force callers to send
    /// the notifier across an actor boundary.
    @MainActor
    func notificationVisibility() async -> NotificationVisibility

    #if !APPSTORE
        /// Recently posted notifications, oldest first, for the debug RPC
        /// `/state.notifications` snapshot. Defaults to empty — only the
        /// production `NotificationManager` keeps a log.
        var recentNotifications: [NotificationRingBuffer.Entry] {
            get
        }
    #endif
}

#if !APPSTORE
    extension AppNotifying {
        var recentNotifications: [NotificationRingBuffer.Entry] {
            []
        }
    }
#endif

extension AppNotifying {
    /// Convenience for the majority of notifications, which have no deadline.
    /// Static dispatch on purpose: it cannot be witnessed, so it can never
    /// become a lossy override of the requirement above.
    func notify(title: String, body: String) {
        notify(title: title, body: body, urgency: .standard)
    }

    // swiftlint:disable async_without_await
    /// Deny by default — only `NotificationManager` shows a real prompt, and
    /// "we could not ask" must never record.
    @MainActor
    func askToRecord(title _: String, body _: String) async -> ConsentAnswer {
        .declined
    }

    @MainActor
    func askToRecordMicrophone(title: String, body: String) async -> ConsentAnswer {
        await askToRecord(title: title, body: body)
    }

    /// Nothing to report by default. Notably this keeps
    /// `UNUserNotificationCenter.current()` out of every headless context: it
    /// raises NSInternalInconsistencyException without a real app bundle, so a
    /// default that reached for it would abort any test touching the notifier.
    @MainActor
    func notificationVisibility() async -> NotificationVisibility {
        .unread
    }

    // swiftlint:enable async_without_await

    /// No prompt to resolve by default — only `NotificationManager` parks one.
    func resolveBrowserConsent(granted _: Bool) -> Bool {
        false
    }
}

// MARK: - SilentNotifier

/// No-op notifier for CLI targets and tests that don't need notifications.
struct SilentNotifier: AppNotifying {
    func notify(title _: String, body _: String, urgency _: NotificationUrgency) {}
}
