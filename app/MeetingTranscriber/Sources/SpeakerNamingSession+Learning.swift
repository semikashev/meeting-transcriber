import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "SpeakerNamingSession")

/// What a confirmed naming may teach the speaker database. Split out of
/// `SpeakerNamingSession+Late.swift` for the length limits.
extension SpeakerNamingSession {
    /// The embeddings of `namingData` that may be learned under the names in
    /// `mapping`: without what an echo-affected recording must not teach, and
    /// without the bleed copy of a person named on both tracks.
    func admissibleEmbeddings(
        _ namingData: SpeakerNamingData, of job: PipelineJob, named fullMapping: [String: String],
    ) -> [String: [Float]] {
        // Hold back what an echo-affected recording must not teach the app. The
        // filter sits here rather than in `updateDB` because this is the only
        // place a job's embeddings reach the database, and it is the last point
        // at which the track each one came from is still readable — `updateDB`
        // sees labels but never parses them. Dropping an entry is enough to
        // suppress the write: `updateDB` skips any label with no embedding.
        //
        // Note this filters `fullMapping`'s effect, not `fullMapping` itself.
        // The transcript rewrite below still uses every name the user gave, so a
        // quarantined speaker is still named in the transcript — only the voice
        // is not memorised.
        let unquarantined = EchoEmbeddingQuarantine.admissible(
            namingData.embeddings,
            verdict: EchoVerdict(job.echo),
            isDualSource: namingData.isDualSource,
            provenSilentAppTrack: micSpeakersOverSilence(namingData, of: job),
        )
        if unquarantined.count != namingData.embeddings.count {
            let held = namingData.embeddings.count - unquarantined.count
            logger.info("echo_quarantine held=\(held, privacy: .public) of=\(namingData.embeddings.count, privacy: .public)")
        }
        // The same person named on both tracks: learn only the track they
        // spoke into, the other copy is bleed (see `CrossTrackEmbeddingFilter`).
        let admissible = CrossTrackEmbeddingFilter.admissible(
            unquarantined, mapping: fullMapping, speakingTimes: namingData.speakingTimes,
        )
        if admissible.count != unquarantined.count {
            let held = unquarantined.count - admissible.count
            logger.info("cross_track_bleed held=\(held, privacy: .public) of=\(unquarantined.count, privacy: .public)")
        }
        return admissible
    }

    /// Microphone speakers who did their talking while the app track carried
    /// nothing, and so cannot have been bleed.
    ///
    /// Without this an affected recording teaches the app nothing at all —
    /// including the voice of the person sitting at the machine, whose own
    /// track was never in doubt. The evidence comes from the persisted app
    /// sidecar, the same file late re-diarization reads; if it is missing, the
    /// answer is "no evidence", and the whole microphone track stays held.
    private func micSpeakersOverSilence(
        _ namingData: SpeakerNamingData, of job: PipelineJob,
    ) -> Set<String> {
        // Both halves of the precondition `admissible` applies, so the two
        // cannot drift: a single-source job has no app track to clear anyone
        // with, and probing for one costs folder stats, an audio open and a
        // per-segment RMS for a result that is then discarded.
        guard EchoVerdict(job.echo) == .affected,
              namingData.isDualSource,
              let slug = job.namingSlug,
              let recordingsDir = sidecarDir(
                  of: job, slug: slug, holdingAnyOf: [SpeakerNamingStore.appTrackSuffix],
              )
        else { return [] }
        let proven = AppTrackSilence.micSpeakersProvenClean(
            segments: namingData.segments,
            appTrackURL: recordingsDir
                .appendingPathComponent("\(slug)\(SpeakerNamingStore.appTrackSuffix)"),
        )
        if !proven.isEmpty {
            logger.info("echo_quarantine_admitted count=\(proven.count, privacy: .public) spoke only over a silent app track")
        }
        return proven
    }
}
