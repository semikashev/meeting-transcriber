import Foundation

/// Which failed meeting notes the app makes again on its own, and when.
///
/// Notes fail for two kinds of reason. Some pass by themselves and cost
/// nothing to try: the usage limit, a network the API refuses, an endpoint
/// that is down, a CLI that is signed out. Others got as far as the model, so
/// every attempt spends quota on a transcript that may fail the same way
/// again; those are spaced out and counted. The rest cannot pass without the
/// user (no CLI, notes cut off, no provider, no transcript).
enum MeetingNotesAutoRetryPolicy {
    /// Like the webhook outbox: after a week the app stops trying by itself.
    /// The job stays listed with Retry Meeting Notes.
    static let maxAge: TimeInterval = 7 * 24 * 3600
    static let costlyDelay: TimeInterval = 3600
    static let maxCostlyAttempts = 5

    /// Whether a later attempt can succeed without the user doing anything
    /// to the job.
    static func canPass(_ failure: MeetingNotesFailure) -> Bool {
        isCheap(failure) || isCostly(failure)
    }

    /// Seconds to leave a job alone after it failed this way.
    static func delay(after failure: MeetingNotesFailure) -> TimeInterval {
        isCostly(failure) ? costlyDelay : 0
    }

    /// The job to retry now: the oldest meeting that is due, one at a time, so
    /// a reason they all share is found out once.
    static func next(in jobs: [PipelineJob], now: Date) -> UUID? {
        jobs
            .filter { isDue($0, now: now) }
            .min { $0.artifactStartTime < $1.artifactStartTime }?
            .id
    }

    private static func isDue(_ job: PipelineJob, now: Date) -> Bool {
        guard job.hasRetryableMeetingNotes, let failure = job.notesFailure, canPass(failure) else { return false }
        if let failedAt = job.notesFailedAt, now.timeIntervalSince(failedAt) > maxAge { return false }
        if let notBefore = job.notesRetryNotBefore, now < notBefore { return false }
        return isCheap(failure) || (job.notesAutoRetries ?? 0) < maxCostlyAttempts
    }

    private static func isCheap(_ failure: MeetingNotesFailure) -> Bool {
        switch failure {
        case .claudeUsageLimit, .claudeBlocked, .claudeSignedOut, .providerUnreachable: true
        default: false
        }
    }

    private static func isCostly(_ failure: MeetingNotesFailure) -> Bool {
        switch failure {
        case .claudeFailed, .timedOut, .empty, .providerRejected: true
        default: false
        }
    }
}
