// swiftlint:disable discouraged_optional_collection
// `[Float]?` is intentional here as in SpeakerMatcher.swift: nil means "no
// centroid", which an empty vector cannot say.
import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "SpeakerMatcher")

/// Writing confirmed voices: what a confirmation teaches, and merging two
/// entries. Split out of `SpeakerMatcher.swift` for the length limits.
extension SpeakerMatcher {
    /// Update speaker DB with confirmed names and their embeddings.
    /// - Each embedding first passes `sampleAdmission`: too little speech, or
    ///   a vector that already stands for someone else, is not learned. The
    ///   confirmation still counts as a use of an existing speaker, but never
    ///   creates one without a voice.
    /// - Labels are written longest speaker first, so when two labels of one
    ///   recording carry near-identical embeddings the better-evidenced one
    ///   becomes the anchor the other is judged against, independent of
    ///   dictionary order.
    /// - Admitted embeddings with at least `minSpeakingTimeForCentroid` seconds
    ///   are folded into the running-mean `centroid`; every admitted one joins
    ///   the recent-samples FIFO (max `maxRecentSamples`). An embedding without
    ///   a known duration keeps the older behaviour: FIFO only.
    /// - An embedding with a NaN/Inf value (FluidAudio emits these for short
    ///   or silent segments) is skipped like a missing one. Folded into the
    ///   centroid it would turn it NaN for good, and the plain JSON encoder
    ///   cannot write it, which used to drop the other labels of the same
    ///   confirmation too. The outcome names it so the caller can tell the
    ///   user that voice was not learned.
    @discardableResult
    func updateDB(
        mapping: [String: String],
        embeddings: [String: [Float]],
        speakingTimes: [String: TimeInterval] = [:],
        provenance: SampleProvenance? = nil,
        now: Date = Date(),
    ) -> ConfirmationOutcome {
        let confirmed = mapping
            // An empty name is a suggestion the user cleared (see `NamingConfirmation`).
            .filter { label, name in !name.isEmpty && name != label && embeddings[label] != nil }
            .sorted { lhs, rhs in
                let l = speakingTimes[lhs.key] ?? 0
                let r = speakingTimes[rhs.key] ?? 0
                return l != r ? l > r : lhs.key < rhs.key
            }
        let mutation = mutateDB { stored -> ConfirmationTally in
            var tally = ConfirmationTally()
            for (label, name) in confirmed {
                guard let embedding = embeddings[label] else { continue }
                guard embedding.allSatisfy(\.isFinite) else {
                    logger.warning("Skipping non-finite embedding for \(label, privacy: .public)")
                    tally.unusable.insert(name)
                    continue
                }
                var labelProvenance = provenance ?? SampleProvenance()
                labelProvenance.track = SpeakerKey(encoded: label).track
                let voice = ConfirmedVoice(
                    name: name, embedding: embedding, duration: speakingTimes[label],
                    provenance: labelProvenance, confirmedAt: now,
                )
                let admission = Self.sampleAdmission(
                    embedding, named: name, duration: voice.duration, against: stored,
                )
                tally.admissions[label] = admission
                if admission == .admitted { tally.applied.insert(name) }
                Self.record(voice, admission, in: &stored)
            }
            Self.logAdmissions(tally.admissions)
            return tally
        }
        return ConfirmationOutcome(
            stored: mutation.saved ? mutation.value.applied.sorted() : [],
            // A name another label of the same confirmation did teach is not
            // missing.
            unusableVoice: mutation.value.unusable.subtracting(mutation.value.applied).sorted(),
            persistence: mutation.persistence,
            admissions: mutation.value.admissions,
        )
    }

    /// What one `updateDB` block decided, collected while it runs.
    private struct ConfirmationTally {
        var applied: Set<String> = []
        var unusable: Set<String> = []
        var admissions: [String: SampleAdmission] = [:]
    }

    /// One confirmed label on its way into the DB.
    private struct ConfirmedVoice {
        let name: String
        let embedding: [Float]
        let duration: TimeInterval?
        let provenance: SampleProvenance
        let confirmedAt: Date
    }

    /// Writes one confirmed voice as the admission gate decided: an admitted
    /// one is learned, anything else counts as a use of an existing speaker.
    private static func record(_ voice: ConfirmedVoice, _ admission: SampleAdmission, in stored: inout [StoredSpeaker]) {
        let idx = stored.firstIndex { $0.name == voice.name }
        switch (admission, idx) {
        case let (.admitted, idx?):
            stored[idx] = applyConfirmation(
                to: stored[idx], embedding: voice.embedding, duration: voice.duration ?? 0, now: voice.confirmedAt,
                provenance: voice.provenance,
            )

        case (.admitted, nil):
            stored.append(newSpeaker(
                name: voice.name, embedding: voice.embedding, duration: voice.duration ?? 0, now: voice.confirmedAt,
                provenance: voice.provenance,
            ))

        case let (_, idx?):
            stored[idx] = stored[idx].recordingUse(at: voice.confirmedAt)

        case (_, nil):
            break
        }
    }

    /// Pure helper: fold a confirmed embedding into an existing `StoredSpeaker`.
    /// The embedding joins the history; it counts toward the centroid only
    /// with `duration >= minSpeakingTimeForCentroid` and a dimension the
    /// centroid can take, and is a recent-sample anchor either way. A legacy
    /// entry's seed (the mean of its samples) becomes its centroid on its first
    /// confirmation of any length; an awaiting entry never seeds.
    static func applyConfirmation(
        to speaker: StoredSpeaker, embedding: [Float], duration: TimeInterval, now: Date,
        provenance: SampleProvenance? = nil,
    ) -> StoredSpeaker {
        let dimensionFits = speaker.centroid.map { $0.count == embedding.count } ?? true
        let sample = makeSample(
            embedding: embedding, duration: duration, qualifies: dimensionFits,
            now: now, provenance: provenance,
        )
        return StoredSpeaker(
            name: speaker.name,
            samples: speaker.appending(sample),
            lastUsed: now,
            useCount: speaker.useCount + 1,
        )
    }

    /// Pure helper: build a fresh `StoredSpeaker` from a single confirmation.
    static func newSpeaker(
        name: String, embedding: [Float], duration: TimeInterval, now: Date,
        provenance: SampleProvenance? = nil,
    ) -> StoredSpeaker {
        let sample = makeSample(
            embedding: embedding, duration: duration, qualifies: true,
            now: now, provenance: provenance,
        )
        return StoredSpeaker(name: name, samples: [sample], lastUsed: now, useCount: 1)
    }

    private static func makeSample(
        embedding: [Float], duration: TimeInterval, qualifies: Bool, now: Date,
        provenance: SampleProvenance?,
    ) -> VoiceSample {
        let counts = qualifies && !embedding.isEmpty && duration >= minSpeakingTimeForCentroid
        return VoiceSample(
            embedding: embedding,
            origin: provenance?.origin ?? .meeting,
            centroidWeight: counts ? 1 : 0,
            addedAt: now,
            duration: duration > 0 ? duration : nil,
            track: provenance?.track,
            jobID: provenance?.jobID,
            meetingTitle: provenance?.meetingTitle,
            pinned: provenance?.pinned ?? false,
        )
    }

    /// Pure helper: combine `src` into `dst`. Used by both rename-collision
    /// and explicit merge.
    static func merged(into dst: StoredSpeaker, from src: StoredSpeaker) -> StoredSpeaker {
        // Both histories, destination first; the derived centroid is then the
        // weighted average of both, exactly as `mergeCentroids` computes it.
        // Where only one side has a centroid, the other's samples join as
        // anchors and leave it unchanged.
        let anchorsOnly = { (speaker: StoredSpeaker, other: StoredSpeaker) -> [VoiceSample] in
            guard speaker.centroid == nil, other.centroid != nil else { return speaker.samples }
            return speaker.samples.map { $0.anchorOnly() }
        }
        var samples = anchorsOnly(dst, src) + anchorsOnly(src, dst)
        // Migrated recent samples were only ever FIFO anchors: keep as many as
        // the old append-and-trim kept, the most recent ones.
        let migratedRecent = samples.indices.filter { samples[$0].origin == .migratedSample }
        let excess = migratedRecent.count - maxRecentSamples
        if excess > 0 {
            let drop = Set(migratedRecent.prefix(excess))
            samples = samples.enumerated().filter { !drop.contains($0.offset) }.map(\.element)
        }
        while samples.count(where: { !$0.pinned }) > StoredSpeaker.maxHistory,
              let oldest = samples.firstIndex(where: { !$0.pinned }) {
            samples.remove(at: oldest)
        }
        // Neither side was confirmed since the history exists: seed the
        // centroid from the samples that may count, weighted by their number.
        // An awaiting side's samples never do.
        let seeds = samples.filter { $0.centroidWeight > 0 }.map(\.embedding)
        if samples.allSatisfy({ $0.origin == .migratedSample && !$0.pinned }), let seed = meanEmbedding(seeds) {
            samples = StoredSpeaker.migratedSamples(
                embeddings: samples.map(\.embedding), centroid: seed, centroidSampleCount: seeds.count,
            )
        }
        let lastUsed = [dst.lastUsed, src.lastUsed].compactMap(\.self).max()
        return StoredSpeaker(
            name: dst.name,
            samples: samples,
            lastUsed: lastUsed,
            useCount: dst.useCount + src.useCount,
            // Stay synthetic only when both sides are synthetic. Merging a
            // real entry in promotes the result back to real.
            isSynthetic: dst.isSynthetic && src.isSynthetic,
        )
    }

    /// Pure helper: weighted-average two centroids. Returns nil centroid if
    /// both inputs are nil. Dimension mismatches yield the larger-count side
    /// (we never let a dim-mismatched merge corrupt the centroid).
    static func mergeCentroids(
        a: [Float]?, aCount: Int, b: [Float]?, bCount: Int,
    ) -> (centroid: [Float]?, count: Int) {
        switch (a, b) {
        case (nil, nil):
            return (nil, aCount + bCount)

        case let (a?, nil):
            return (a, aCount + bCount)

        case let (nil, b?):
            return (b, aCount + bCount)

        case let (a?, b?):
            guard a.count == b.count, !a.isEmpty else {
                return aCount >= bCount ? (a, aCount + bCount) : (b, aCount + bCount)
            }
            let total = Float(max(aCount + bCount, 1))
            let aw = Float(aCount) / total
            let bw = Float(bCount) / total
            var merged = [Float](repeating: 0, count: a.count)
            for i in 0 ..< a.count {
                merged[i] = a[i] * aw + b[i] * bw
            }
            return (merged, aCount + bCount)
        }
    }
}

// swiftlint:enable discouraged_optional_collection
