// swiftlint:disable discouraged_optional_collection
// Optional `[Float]?` is intentional throughout this file: nil signals
// "no centroid yet" (legacy entries / dim-mismatch / empty input), which is
// semantically distinct from an empty embedding vector.
import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "SpeakerMatcher")

class SpeakerMatcher {
    private let dbPath: URL
    let threshold: Float
    private let confidenceMargin: Float
    /// Recent-samples FIFO size (was 5 before centroid landed; 3 is enough as
    /// fallback because the centroid is the primary anchor now).
    static let maxRecentSamples = 3
    /// Minimum total speaking time (seconds) for an embedding to be folded
    /// into the centroid. Short snippets are still kept as fallback samples
    /// but don't pollute the running average.
    static let minSpeakingTimeForCentroid: TimeInterval = 3.0
    /// A label heard for less than this gets no automatic name, from the
    /// voice database or from the participant list; the dialog still ranks
    /// candidates for it. Short fragments (interjections, crosstalk, noise)
    /// give embeddings that crowd into one region near many voices, so the
    /// name they get is mostly a guess. In the recognition log, suggestions
    /// for labels under 10 s were accepted 4 times and rejected 19 times. On
    /// a replay of 86 meetings against a fixed database the gate took wrong
    /// names from 20 to 11 and correct ones from 296 to 289.
    static let minSpeakingTimeForAutoName: TimeInterval = 10
    /// Process-wide lock for read-modify-write sequences against
    /// `speakers.json`. The RPC handlers, the pipeline-job confirmation
    /// path, the KnownVoices UI, and voice enrollment can all mutate the
    /// DB concurrently — without serialization, two writers can both load
    /// the same snapshot and the second `saveDB` silently overwrites the
    /// first. Reads stay unlocked: every code path reloads after a
    /// mutation anyway, and `replaceItemAt` already gives atomic file
    /// replacement at the FS level.
    private static let dbLock = NSLock()
    /// Last problem reported per DB path (see `shouldReport`). Process-wide
    /// because matchers are created per call; guarded by `dbLock`.
    nonisolated(unsafe) private static var problemReports: [URL: ProblemReport] = [:]

    /// Told when `mutateDB` could not use or write the DB, so the user learns
    /// their enrolled voices are not being kept. Deduplicated, and called
    /// after `dbLock` is released. Silent by default, like `WatchLoop`'s
    /// notifier: production builds matchers through `factory(dbPath:notifier:)`,
    /// which routes it to the app's one `AppNotifying`.
    private let onDBProblem: (DBProblem) -> Void
    /// Runs between the two reads of an undecodable DB, without `dbLock`
    /// held (see `rereadDelay`). Injected so tests neither wait nor race a
    /// timer.
    private let settleBeforeReread: () -> Void

    init(
        dbPath: URL? = nil,
        threshold: Float = 0.40,
        confidenceMargin: Float = 0.10,
        // First of the two closures, so a trailing closure binds to it.
        onDBProblem: @escaping (DBProblem) -> Void = { _ in },
        settleBeforeReread: @escaping () -> Void = { Thread.sleep(forTimeInterval: SpeakerMatcher.rereadDelay) },
    ) {
        self.dbPath = dbPath ?? AppPaths.speakersDB
        self.threshold = threshold
        self.confidenceMargin = confidenceMargin
        self.settleBeforeReread = settleBeforeReread
        self.onDBProblem = onDBProblem
        Self.migrateIfNeeded(dbPath: self.dbPath)
    }

    /// Atomic read-modify-write against `speakers.json`. Holds the
    /// process-wide DB lock for the duration of the closure so concurrent
    /// callers can't lose updates. Use this for every mutating operation;
    /// raw `loadDB` + `saveDB` paired by hand reintroduces the race.
    ///
    /// A DB that exists but cannot be used is never overwritten blind.
    /// Treating it as empty and saving would replace every enrolled voice
    /// with just this one change. A damaged DB is first copied aside
    /// unchanged (`quarantineDamagedDB`), and the block runs against the
    /// entries that could be salvaged (`.salvaged`; none if the file is not a
    /// JSON array). Only then is the new array swapped in by an atomic
    /// replace, so the original stays in place until the new file takes its
    /// path: a failed write leaves it untouched, and a reader never finds the
    /// path empty. A DB that failed to *read* may be intact, so it stays in
    /// place and nothing is written; so does a damaged one that cannot be
    /// copied. The block still runs in that case, because callers need its
    /// result; `persistence` says whether the change reached the disk.
    @discardableResult
    func mutateDB<R>(_ block: (inout [StoredSpeaker]) -> R) -> Mutation<R> {
        var mayQuarantine = false
        while true {
            let attempt = Self.dbLock.withLock { lockedMutate(block, mayQuarantine: mayQuarantine) }
            guard let (mutation, problem) = attempt else {
                // Undecodable on the first read. Wait outside the lock, so
                // other writers are not held up, then read it once more.
                settleBeforeReread()
                mayQuarantine = true
                continue
            }
            // Outside the lock: the callback posts a notification and may call
            // back into a matcher, and `dbLock` is not recursive.
            if let problem { onDBProblem(problem) }
            return mutation
        }
    }

    /// The body of `mutateDB`, run with `dbLock` held. Returns the problem to
    /// report, already deduplicated, for the caller to report after unlocking;
    /// or nil, without running `block`, when the DB is undecodable and
    /// `mayQuarantine` is false (see `rereadDelay`).
    private func lockedMutate<R>(
        _ block: (inout [StoredSpeaker]) -> R, mayQuarantine: Bool,
    ) -> (Mutation<R>, DBProblem?)? {
        let outcome = Self.readDB(at: dbPath)
        // The problem already reported for this very file, if it has not
        // changed since: it was left in place, or its write failed after the
        // copy. Such a file has stopped changing.
        let known = Self.problemReports[dbPath].flatMap { $0.file == FileState(of: dbPath) ? $0.problem : nil }
        // Only a file that is not even a JSON array can be a sync tool caught
        // mid-write, and one already reported need not be waited on again by
        // the (mostly main-actor) callers.
        if case .undecodable = outcome, !mayQuarantine, known == nil {
            return nil
        }
        var plan = Self.writePlan(for: outcome)
        // The copy must exist before anything is written: the entries a
        // salvage drops survive only in it. An unchanged file whose write
        // failed already has one, so a write that keeps failing makes no more.
        var copiedTo: URL?
        if let damage = plan.damage {
            copiedTo = Self.existingCopy(after: known, of: dbPath)
                ?? Self.quarantineDamagedDB(at: dbPath, damage: damage)
            if copiedTo == nil { plan.writable = false }
        }
        var stored = plan.stored
        let value = block(&stored)

        let persistence: Persistence
        let problem: DBProblem?
        if plan.writable {
            do {
                try Self.writeDB(stored, to: dbPath)
                persistence = .saved
                problem = copiedTo.flatMap { plan.damage?.problem(copiedTo: $0) }
                Self.problemReports[dbPath] = nil
            } catch {
                // The atomic replace never happened, so the original is still
                // in place, untouched; the copy stays too, is named, and is
                // reused by the next attempt while the file is unchanged.
                logger.error("Failed to save speaker DB: \(error.localizedDescription, privacy: .public)")
                persistence = .writeFailed
                problem = .saveFailed(copiedTo: copiedTo)
            }
        } else {
            persistence = .dbUnavailable
            problem = .leftInPlace
        }
        let toReport = problem.flatMap { Self.shouldReport($0, at: dbPath, reports: &Self.problemReports) ? $0 : nil }
        let replaced = persistence == .saved ? copiedTo : nil
        return (Mutation(value: value, persistence: persistence, replacedCorruptDB: replaced), toReport)
    }

    /// Classify the DB on disk without the re-read `mutateDB` does. See
    /// `ReadOutcome`.
    func readDB() -> ReadOutcome {
        Self.readDB(at: dbPath)
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
    /// with their per-anchor distances; `against` is a kept `matchableSpeakers()`.
    /// Labels are matched longest speaker first (`speakingTimes`; key order
    /// breaks ties and stands in when no times are given), so a contested name
    /// goes to the label with the most evidence behind it.
    func matchVerbose(
        embeddings: [String: [Float]], speakingTimes: [String: TimeInterval] = [:], topK: Int = 3,
        against: [StoredSpeaker]? = nil,
    ) -> [String: VerboseMatch] {
        let stored = against ?? matchableSpeakers()
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
            let tooLittleSpeech = Self.hasTooLittleSpeech(label, in: speakingTimes)
            let assignedName: String
            if !tooLittleSpeech,
               let best,
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
                tooLittleSpeech: tooLittleSpeech,
            )
            result[label] = VerboseMatch(
                assignedName: assignedName, topCandidates: Array(scored.prefix(topK)),
            )
        }

        return result
    }

    /// True when the diarizer heard `label` for less than
    /// `minSpeakingTimeForAutoName`. A label without a known time is not held
    /// back: callers that pass no times keep the behaviour they had.
    static func hasTooLittleSpeech(_ label: String, in speakingTimes: [String: TimeInterval]) -> Bool {
        speakingTimes[label].map { $0 < minSpeakingTimeForAutoName } ?? false
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

    /// Stored speakers for read-only use. An unreadable DB reads as empty
    /// here, a partly undecodable one as the entries that can be salvaged,
    /// and either is left in place; only `mutateDB` copies it aside, under
    /// the lock, before it would write.
    func loadDB() -> [StoredSpeaker] {
        readDB().usableSpeakers
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

    /// Write the DB unconditionally, logging a failure. Skips the lock and
    /// every safeguard in `mutateDB`, so production writes go through that.
    func saveDB(_ speakers: [StoredSpeaker]) {
        do {
            try Self.writeDB(speakers, to: dbPath)
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
        // Find unmatched labels: name equals raw label (not yet named), not
        // excluded, and long enough to be named at all. A short noise cluster
        // counted here used to complete an exact count and take a name.
        let unmatchedLabels = mapping.keys.filter { label in
            mapping[label] == label && !excludeLabels.contains(label)
                && !hasTooLittleSpeech(label, in: speakingTimes)
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
