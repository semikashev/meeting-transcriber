import Foundation

extension PipelineController {
    /// The notification when the provider is None, and nothing was queued.
    static let notesProviderNoneNotice = (
        title: "Meeting Notes Not Generated",
        body: "Choose a meeting notes provider in Settings → Output first.",
    )

    /// Generate Meeting Notes from Transcript: one notes-only job per file
    /// (`PipelineQueue.enqueueNotes(fromTranscripts:)`). Files it leaves out
    /// are named in a notification. Nil, with nothing queued, while the
    /// provider is None: the jobs would finish without notes. `notify: false`
    /// for `/v1`, whose caller has the answer in the response.
    @discardableResult
    func generateNotes(fromTranscripts urls: [URL], notify: Bool = true) -> NotesFromTranscriptOutcome? {
        guard settings.protocolProvider != .none else {
            if notify { notifier.notify(title: Self.notesProviderNoneNotice.title, body: Self.notesProviderNoneNotice.body) }
            return nil
        }
        ensureQueue()
        let outcome = queue.enqueueNotes(fromTranscripts: urls)
        if notify, let notice = outcome.skippedNotice {
            notifier.notify(title: notice.title, body: notice.body)
        }
        return outcome
    }

    /// Meeting notes for a recording in the Protocols window that has only its
    /// transcript: the retry of the job that still holds it, which knows the
    /// meeting and its participants, else a notes-only job as for a picked one.
    func makeNotes(forTranscript url: URL) {
        ensureQueue()
        let path = url.standardizedFileURL.path
        if let held = queue.jobsWithRetryableMeetingNotes.first(where: { $0.transcriptPath?.standardizedFileURL.path == path }) {
            queue.retryMeetingNotes(id: held.id)
        } else {
            generateNotes(fromTranscripts: [url])
        }
    }
}
