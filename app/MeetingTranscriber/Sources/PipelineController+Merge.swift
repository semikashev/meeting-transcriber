import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "SessionMerge")

/// Originals waiting to be trashed once the merged job has produced a protocol.
struct MergeCleanup {
    let entries: [ProtocolEntry]
    let outputDir: URL
}

extension PipelineController {
    /// Joins the recordings of `request` into one new job and enqueues it.
    /// Returns the job's id. Nothing of the originals is touched here: they are
    /// only trashed later, by `finishMerge`, after the merged protocol exists
    /// and only when the request asked for it.
    @discardableResult
    func mergeSessions(
        _ request: SessionMergeRequest,
        outputDir: URL,
        calendar: any CalendarMeetingLookup = NoCalendarLookup(),
        stagingDir: URL = AppPaths.recordingsDir,
    ) async throws -> UUID {
        let plan = try SessionMerge.plan(for: request.entries)
        let stems = Set(plan.sources.map(\.entry.stem))
        guard mergingStems.isDisjoint(with: stems) else { throw SessionMergeError.alreadyMerging }
        mergingStems.formUnion(stems)
        var enqueued = false
        defer { if !enqueued { mergingStems.subtract(stems) } }

        let accessing = outputDir.startAccessingSecurityScopedResource()
        defer { if accessing { outputDir.stopAccessingSecurityScopedResource() } }

        let firstStart = plan.sources.first?.entry.recordedAt ?? Date()
        let basename = SessionMerge.basename(firstStart: firstStart)
        let audio = try await Task.detached(priority: .utility) {
            try SessionMerge.render(plan, into: stagingDir, basename: basename)
        }.value

        let meetings = plan.sources.compactMap { calendar.meeting(startingAt: $0.entry.recordedAt, appName: "") }
        let title = request.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let job = SessionMerge.makeJob(
            request: SessionMergeRequest(
                entries: request.entries,
                title: title.isEmpty ? SessionMerge.defaultTitle(for: request.entries) : title,
                deleteOriginals: request.deleteOriginals,
            ),
            plan: plan,
            audio: audio,
            participants: SessionMerge.union(meetings.map(\.attendees)),
            emails: SessionMerge.union(meetings.map(\.attendeeEmails)),
        )

        ensureQueue()
        // The originals live in the output folder, not in staging, so orphan
        // recovery cannot see them; the ledger entry is the second guard for a
        // build that ever scans further.
        for source in plan.sources {
            queue.processedLedger.markProcessed(mixPath: source.mix)
        }
        if request.deleteOriginals {
            mergeCleanups[job.id] = MergeCleanup(entries: plan.sources.map(\.entry), outputDir: outputDir)
        }
        enqueued = true
        pendingMergeStems[job.id] = stems
        queue.enqueue(job)
        logger.info("Merging \(plan.sources.count) recordings into job \(job.id.uuidString, privacy: .public)")
        return job.id
    }

    /// Called for every finished job. Releases the merge's hold on the
    /// originals and, when the merge succeeded and the user asked for it,
    /// trashes them.
    func finishMerge(job: PipelineJob, succeeded: Bool) {
        if let stems = pendingMergeStems.removeValue(forKey: job.id) {
            mergingStems.subtract(stems)
        }
        guard let cleanup = mergeCleanups.removeValue(forKey: job.id) else { return }
        // A transcript-only outcome (no protocol generator, or generation
        // failed) leaves the originals alone: the merged recording is not yet
        // a replacement for them.
        guard succeeded, job.protocolPath != nil else { return }

        let accessing = cleanup.outputDir.startAccessingSecurityScopedResource()
        defer { if accessing { cleanup.outputDir.stopAccessingSecurityScopedResource() } }
        var failed: [String] = []
        for entry in cleanup.entries {
            do {
                try ProtocolLibrary.remove(entry, scope: .everything, using: originalsRemover)
            } catch {
                failed.append(entry.title)
                logger.error("Could not delete \(entry.stem, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        if !failed.isEmpty {
            notifier.notify(title: "Could not delete some originals", body: failed.joined(separator: ", "))
        }
    }
}
