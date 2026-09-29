// swiftlint:disable discouraged_optional_collection
// Optional `[Float]?` is intentional throughout this file: nil signals
// "no centroid yet" (legacy entries / dim-mismatch / empty input), which is
// semantically distinct from an empty embedding vector.
import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "SpeakerMatcher")

class SpeakerMatcher {
    private let dbPath: URL
    private let threshold: Float
    private let confidenceMargin: Float
    /// Recent-samples FIFO size (was 5 before centroid landed; 3 is enough as
    /// fallback because the centroid is the primary anchor now).
    static let maxRecentSamples = 3
    /// Minimum total speaking time (seconds) for an embedding to be folded
    /// into the centroid. Short snippets are still kept as fallback samples
    /// but don't pollute the running average.
    static let minSpeakingTimeForCentroid: TimeInterval = 3.0
    /// Process-wide lock for read-modify-write sequences against
    /// `speakers.json`. The RPC handlers, the pipeline-job confirmation
    /// path, the KnownVoices UI, and voice enrollment can all mutate the
    /// DB concurrently — without serialization, two writers can both load
    /// the same snapshot and the second `saveDB` silently overwrites the
    /// first. Reads stay unlocked: every code path reloads after a
    /// mutation anyway, and `replaceItemAt` already gives atomic file
    /// replacement at the FS level.
    private static let dbLock = NSLock()

    init(dbPath: URL? = nil, threshold: Float = 0.40, confidenceMargin: Float = 0.10) {
        self.dbPath = dbPath ?? AppPaths.speakersDB
        self.threshold = threshold
        self.confidenceMargin = confidenceMargin
        Self.migrateIfNeeded(dbPath: self.dbPath)
    }

    /// Atomic read-modify-write against `speakers.json`. Holds the
    /// process-wide DB lock for the duration of the closure so concurrent
    /// callers can't lose updates. Use this for every mutating operation;
    /// raw `loadDB` + `saveDB` paired by hand reintroduces the race.
    @discardableResult
    func mutateDB<R>(_ block: (inout [StoredSpeaker]) -> R) -> R {
        Self.dbLock.lock()
        defer { Self.dbLock.unlock() }
        var stored = loadDB()
        let result = block(&stored)
        saveDB(stored)
        return result
    }

    /// Reset old pyannote-format speakers.json (incompatible embeddings).
    /// Old format: `{ "name": [[float]] }` dict.
    /// New format: `[{ "name": str, "embedding": [float] }]` array.
    static func migrateIfNeeded(dbPath: URL) {
        guard let data = try? Data(contentsOf: dbPath) else { return }

        // Fast path: the current array format ('[') needs no migration. Skip the
        // full JSONSerialization parse for it — this runs on every SpeakerMatcher
        // init, so re-parsing the whole DB each time is pure overhead, and
        // concurrent inits parsing the same file is a TSan-hostile NSJSONReader
        // frame. saveDB writes JSONEncoder output, which always begins with '['.
        // Only the legacy dict format falls through to the parse + backup below.
        guard data.first != UInt8(ascii: "[") else { return }

        guard let json = try? JSONSerialization.jsonObject(with: data) else { return }
        // Old format is a dictionary, new format is an array
        if json is [String: Any] {
            let backup = dbPath.deletingLastPathComponent()
                .appendingPathComponent("speakers.json.bak")
            try? FileManager.default.moveItem(at: dbPath, to: backup)
        }
    }

    /// Match diarization embeddings against stored speakers.
    /// Distance uses `min(cosineDistance over [centroid] + recent samples)`
    /// — the centroid is treated as one additional anchor alongside the
    /// recent-samples FIFO, never replacing them. This preserves the
    /// previous algorithm's behaviour on identical-sample queries while
    /// adding the centroid's drift-resistance for free.
    func match(
        embeddings: [String: [Float]], speakingTimes: [String: TimeInterval] = [:],
    ) -> [String: String] {
        matchVerbose(embeddings: embeddings, speakingTimes: speakingTimes).mapValues(\.assignedName)
    }

    /// A name already given to one label may go to another label of the same
    /// track this close to it. The diarizer regularly splits one person into
    /// several clusters on one track; with every name usable once, the second
    /// cluster went unnamed or took the next-best stranger. On a replay of 50
    /// real meetings (218 labels of already-known people) this raised the
    /// correctly named labels from 101 to 133 while wrong names went from 24
    /// to 25; the result was flat for any distance between 0.20 and 0.35.
    /// Never across tracks: the same person on both is bleed on one of them.
    static let sameTrackReuseDistance: Float = 0.25

    /// Per-label match result. Reuses `TopCandidate` so the matcher and the
    /// JSONL log share one shape — eliminates a field-by-field re-pack at the
    /// call site.
    struct VerboseMatch {
        /// Real speaker name when the threshold + margin checks pass; the
        /// label itself otherwise.
        let assignedName: String
        /// Candidates sorted by `hybrid` ascending; empty if the DB is empty.
        let topCandidates: [TopCandidate]
    }

    /// Match each label against the stored DB, returning the top candidates
    /// with their per-anchor distances.
    /// Labels are matched longest speaker first (`speakingTimes`; key order
    /// breaks ties and stands in when no times are given), so a contested name
    /// goes to the label with the most evidence behind it.
    func matchVerbose(
        embeddings: [String: [Float]], speakingTimes: [String: TimeInterval] = [:], topK: Int = 3,
    ) -> [String: VerboseMatch] {
        // Synthetic entries (RPC `seedSpeaker`) carry random embeddings —
        // letting them participate in matching would let any caller with
        // RPC access poison auto-naming. Drop them before scoring.
        let stored = loadDB().filter { !$0.isSynthetic }
        var result: [String: VerboseMatch] = [:]
        var usedOnTracks: [String: Set<SpeakerKey.Track>] = [:]

        let order: [String] = Self.longestFirst(Array(embeddings.keys), speakingTimes: speakingTimes)

        for label in order {
            guard let embedding = embeddings[label] else { continue }
            let track = SpeakerKey(encoded: label).track
            let scored: [TopCandidate] = stored
                .map { Self.candidate($0, for: embedding) }
                .filter { candidate in
                    guard let tracks = usedOnTracks[candidate.name] else { return true }
                    return tracks == [track] && candidate.hybrid < Self.sameTrackReuseDistance
                }
                .sorted { $0.hybrid < $1.hybrid }

            let best = scored.first
            let second = scored.count > 1 ? scored[1] : nil
            let assignedName: String
            if let best,
               best.hybrid < threshold,
               (second?.hybrid ?? .greatestFiniteMagnitude) - best.hybrid >= confidenceMargin {
                assignedName = best.name
                usedOnTracks[best.name, default: []].insert(track)
            } else {
                assignedName = label
            }
            Self.logMatchDecision(
                label: label, best: best, second: second,
                assigned: assignedName,
                thresholds: (distance: threshold, margin: confidenceMargin),
            )
            result[label] = VerboseMatch(
                assignedName: assignedName, topCandidates: Array(scored.prefix(topK)),
            )
        }

        return result
    }

    /// Labels ordered by speaking time, longest first; key order breaks ties.
    static func longestFirst(_ labels: [String], speakingTimes: [String: TimeInterval]) -> [String] {
        labels.sorted { (lhs: String, rhs: String) -> Bool in
            let l: TimeInterval = speakingTimes[lhs] ?? 0
            let r: TimeInterval = speakingTimes[rhs] ?? 0
            return l != r ? l > r : lhs < rhs
        }
    }

    /// Per-anchor distances from `embedding` to one stored speaker.
    private static func candidate(_ speaker: StoredSpeaker, for embedding: [Float]) -> TopCandidate {
        let sampleDist: Float = speaker.anchorEmbeddings
            .map { cosineDistance(embedding, $0) }.min() ?? .greatestFiniteMagnitude
        let centroidDist: Float? = speaker.centroid.map { cosineDistance(embedding, $0) }
        return TopCandidate(name: speaker.name, sample: sampleDist, centroid: centroidDist)
    }

    /// Distance from a query embedding to a stored speaker.
    /// Computes `min(cosineDistance over [centroid] + recent samples)`.
    /// For legacy entries (no centroid persisted), the recent-samples FIFO
    /// is the sole anchor — which is identical to the pre-centroid algorithm.
    static func distance(query: [Float], speaker: StoredSpeaker) -> Float {
        var anchors = speaker.anchorEmbeddings
        if let c = speaker.centroid { anchors.append(c) }
        return anchors.map { cosineDistance(query, $0) }.min() ?? .greatestFiniteMagnitude
    }

    /// Element-wise mean of a non-empty list of equal-length embedding
    /// vectors. Returns nil for an empty input or for vectors of mixed
    /// dimensionality (we never produce mixed-dim arrays in normal flow,
    /// but we don't trust historical entries).
    static func meanEmbedding(_ vectors: [[Float]]) -> [Float]? {
        guard let first = vectors.first, !first.isEmpty else { return nil }
        let dim = first.count
        guard vectors.allSatisfy({ $0.count == dim }) else { return nil }
        var sum = [Float](repeating: 0, count: dim)
        for vec in vectors {
            for i in 0 ..< dim {
                sum[i] += vec[i]
            }
        }
        let n = Float(vectors.count)
        return sum.map { $0 / n }
    }

    /// Update an existing centroid with a new sample using a running average:
    /// `new = (centroid * count + sample) / (count + 1)`. Returns nil if the
    /// sample dimensionality doesn't match the centroid (we never let a bad
    /// sample corrupt the centroid).
    static func updateCentroid(
        current: [Float]?, count: Int, with sample: [Float],
    ) -> (centroid: [Float], count: Int)? {
        guard !sample.isEmpty else { return nil }
        guard let current, !current.isEmpty else {
            return (sample, 1)
        }
        guard current.count == sample.count else { return nil }
        let n = Float(count)
        let total = n + 1
        var updated = [Float](repeating: 0, count: current.count)
        for i in 0 ..< current.count {
            updated[i] = (current[i] * n + sample[i]) / total
        }
        return (updated, count + 1)
    }

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
    @discardableResult
    func updateDB(
        mapping: [String: String],
        embeddings: [String: [Float]],
        speakingTimes: [String: TimeInterval] = [:],
        provenance: SampleProvenance? = nil,
        now: Date = Date(),
    ) -> [String: SampleAdmission] {
        let confirmed = mapping
            .filter { label, name in name != label && embeddings[label] != nil }
            .sorted { lhs, rhs in
                let l = speakingTimes[lhs.key] ?? 0
                let r = speakingTimes[rhs.key] ?? 0
                return l != r ? l > r : lhs.key < rhs.key
            }
        return mutateDB { stored in
            var outcome: [String: SampleAdmission] = [:]
            for (label, name) in confirmed {
                guard let embedding = embeddings[label] else { continue }
                let duration = speakingTimes[label]
                let admission = Self.sampleAdmission(
                    embedding, named: name, duration: duration, against: stored,
                )
                outcome[label] = admission
                let idx = stored.firstIndex { $0.name == name }
                var labelProvenance = provenance ?? SampleProvenance()
                labelProvenance.track = SpeakerKey(encoded: label).track
                switch (admission, idx) {
                case let (.admitted, idx?):
                    stored[idx] = Self.applyConfirmation(
                        to: stored[idx], embedding: embedding, duration: duration ?? 0, now: now,
                        provenance: labelProvenance,
                    )

                case (.admitted, nil):
                    stored.append(Self.newSpeaker(
                        name: name, embedding: embedding, duration: duration ?? 0, now: now,
                        provenance: labelProvenance,
                    ))

                case let (_, idx?):
                    stored[idx] = stored[idx].recordingUse(at: now)

                case (_, nil):
                    break
                }
            }
            Self.logAdmissions(outcome)
            return outcome
        }
    }

    /// Pure helper: fold a confirmed embedding into an existing `StoredSpeaker`.
    /// The embedding joins the history; it counts toward the centroid only
    /// with `duration >= minSpeakingTimeForCentroid` and a dimension the
    /// centroid can take, and is a recent-sample anchor either way.
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

    enum RenameResult: Equatable {
        case renamed
        case merged
        case notFound
        case noop
    }

    /// Rename a speaker. If a speaker with `to` already exists, merges `from`
    /// into it. Persists immediately. `noop` covers same-source-and-target;
    /// `notFound` covers a missing source.
    @discardableResult
    func renameSpeaker(from: String, to: String) -> RenameResult {
        guard from != to else { return .noop }
        return mutateDB { stored in
            guard let srcIdx = stored.firstIndex(where: { $0.name == from }) else {
                return .notFound
            }
            if let dstIdx = stored.firstIndex(where: { $0.name == to }) {
                stored[dstIdx] = Self.merged(into: stored[dstIdx], from: stored[srcIdx])
                stored.remove(at: srcIdx)
                return .merged
            }
            stored[srcIdx] = stored[srcIdx].renamed(to: to)
            return .renamed
        }
    }

    /// Remove a speaker. Returns `false` if no speaker with that name was found.
    @discardableResult
    func deleteSpeaker(name: String) -> Bool {
        mutateDB { stored in
            guard let idx = stored.firstIndex(where: { $0.name == name }) else { return false }
            stored.remove(at: idx)
            return true
        }
    }

    /// Merge `from` into `into`. Embeddings concatenated and FIFO-trimmed,
    /// centroid weighted-averaged, lastUsed/useCount combined. Returns false
    /// if either name is missing or if `from == into`.
    @discardableResult
    func mergeSpeakers(from: String, into: String) -> Bool {
        guard from != into else { return false }
        return mutateDB { stored in
            guard let srcIdx = stored.firstIndex(where: { $0.name == from }),
                  let dstIdx = stored.firstIndex(where: { $0.name == into }) else {
                return false
            }
            stored[dstIdx] = Self.merged(into: stored[dstIdx], from: stored[srcIdx])
            stored.removeAll { $0.name == from }
            return true
        }
    }

    /// Pure helper: combine `src` into `dst`. Used by both rename-collision
    /// and explicit merge.
    static func merged(into dst: StoredSpeaker, from src: StoredSpeaker) -> StoredSpeaker {
        // Both histories, destination first; the derived centroid is then the
        // weighted average of both, exactly as `mergeCentroids` computes it.
        var samples = dst.samples + src.samples
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
        let lastUsed: Date? = switch (dst.lastUsed, src.lastUsed) {
        case let (a?, b?): max(a, b)
        case let (a?, nil): a
        case let (nil, b?): b
        case (nil, nil): nil
        }
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

    func loadDB() -> [StoredSpeaker] {
        guard let data = try? Data(contentsOf: dbPath) else { return [] }
        return (try? JSONDecoder().decode([StoredSpeaker].self, from: data)) ?? []
    }

    /// Names of all stored speakers, ordered for picker display: most recently
    /// used first, then by `useCount` descending, then alphabetically. Speakers
    /// without `lastUsed` (legacy entries) are sorted alphabetically at the end.
    /// This is the source-of-truth ordering for the "Known voices" row.
    func allSpeakerNames() -> [String] {
        Self.rankByRecency(speakers: loadDB()).map(\.name)
    }

    /// Sort stored speakers for picker display. Pure for testability.
    /// Tier order:
    /// 1. Speakers with `lastUsed != nil`, most recent first.
    /// 2. Within that group, ties (same timestamp) broken by `useCount` desc.
    /// 3. Speakers without `lastUsed` come last, alphabetically.
    static func rankByRecency(speakers: [StoredSpeaker]) -> [StoredSpeaker] {
        let used = speakers.filter { $0.lastUsed != nil }
        let unused = speakers.filter { $0.lastUsed == nil }
        let sortedUsed = used.sorted { lhs, rhs in
            let l = lhs.lastUsed ?? .distantPast
            let r = rhs.lastUsed ?? .distantPast
            if l != r { return l > r }
            if lhs.useCount != rhs.useCount { return lhs.useCount > rhs.useCount }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        let sortedUnused = unused.sorted { lhs, rhs in
            lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        return sortedUsed + sortedUnused
    }

    func saveDB(_ speakers: [StoredSpeaker]) {
        do {
            let data = try JSONEncoder().encode(speakers)
            let tmp = dbPath.deletingLastPathComponent()
                .appendingPathComponent("speakers.json.tmp")
            try data.write(to: tmp)
            _ = try FileManager.default.replaceItemAt(dbPath, withItemAt: tmp)
            // Voice embeddings/centroids are biometric-adjacent — restrict the
            // persisted DB to owner-only. The temp-file rename does not carry a
            // chmod applied pre-rename, so set it on the final path.
            try FileManager.default.restrictToOwner(dbPath)
        } catch {
            logger.error("Failed to save speaker DB: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Pre-assign participant names to unmatched speakers by speaking time.
    /// When unmatched remote speaker count == unmatched participant count,
    /// assign by descending speaking time order.
    /// This is a heuristic — the naming popup lets users correct mistakes.
    ///
    /// - Parameters:
    ///   - mapping: Current label → name mapping (from `match()`)
    ///   - speakingTimes: Speaking time per label
    ///   - participants: Meeting participant names (e.g. from Teams)
    ///   - excludeLabels: Labels to exclude (e.g. mic speaker already identified)
    /// - Returns: Updated mapping with participants pre-assigned
    static func preMatchParticipants(
        mapping: [String: String],
        speakingTimes: [String: TimeInterval],
        participants: [String],
        excludeLabels: Set<String> = [],
    ) -> [String: String] {
        // Find unmatched labels: name equals raw label (not yet named) and not excluded
        let unmatchedLabels = mapping.keys.filter { label in
            mapping[label] == label && !excludeLabels.contains(label)
        }

        // Find unused participants: not already assigned as a value in mapping
        let usedNames = Set(mapping.values)
        let unusedParticipants = participants.filter { !usedNames.contains($0) }

        // Only assign when counts match exactly
        guard unmatchedLabels.count == unusedParticipants.count,
              !unmatchedLabels.isEmpty else {
            return mapping
        }

        // Sort unmatched labels by speaking time descending
        let sortedLabels = unmatchedLabels.sorted { a, b in
            (speakingTimes[a] ?? 0) > (speakingTimes[b] ?? 0)
        }

        var updated = mapping
        for (label, participant) in zip(sortedLabels, unusedParticipants) {
            updated[label] = participant
        }

        return updated
    }

    /// Cosine distance: 0 = identical, 2 = opposite.
    static func cosineDistance(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 2 }
        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        for i in 0 ..< a.count {
            dot += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        let denom = sqrt(normA) * sqrt(normB)
        guard denom > 0 else { return 2 }
        return 1 - dot / denom
    }
}

// swiftlint:enable discouraged_optional_collection
