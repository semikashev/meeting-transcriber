// swiftlint:disable discouraged_optional_collection
// `centroid: [Float]?` and `lastUsed: Date?` use nil to signal a distinct
// "absent" state (no centroid yet / never confirmed), which an empty
// collection cannot express.
import Foundation

struct StoredSpeaker: Codable, Identifiable {
    var id: String {
        name
    }

    let name: String
    /// The voice history this speaker was learned from, oldest first. The
    /// source of truth: `embeddings`, `centroid` and `centroidSampleCount` are
    /// derived from it on construction (see `VoiceSample`).
    let samples: [VoiceSample]
    /// Recent quality samples (the last `SpeakerMatcher.maxRecentSamples`
    /// non-centroid entries of `samples`). Used as fallback match anchors.
    let embeddings: [[Float]]
    /// Weighted mean of the samples that count toward it. The primary match
    /// anchor. nil until a sample with known, sufficient speech exists.
    let centroid: [Float]?
    /// Number of confirmations `centroid` averages.
    let centroidSampleCount: Int
    /// Wall-clock time when this speaker was last confirmed by the user via
    /// `updateDB`. Used to rank suggestion chips by recency. nil for entries
    /// migrated from older DB versions that didn't track usage.
    let lastUsed: Date?
    /// Number of times this speaker has been confirmed by the user across
    /// recordings. Defaults to 0 for entries that pre-date usage tracking.
    let useCount: Int
    /// True for entries seeded by the debug RPC `seedSpeaker` action, which
    /// writes random embeddings for testing. Synthetic entries are skipped
    /// in `match()`/`matchVerbose()` so a poisoned random vector can never
    /// auto-name a real speaker. Defaults to false for legacy entries and
    /// for every user-confirmed speaker.
    let isSynthetic: Bool

    /// Maximum number of unpinned samples a speaker keeps. The oldest unpinned
    /// one is dropped when a new one arrives; pinned samples are never dropped.
    static let maxHistory = 20

    /// Build from a sample history; the derived anchors are computed here.
    init(
        name: String,
        samples: [VoiceSample],
        lastUsed: Date? = nil,
        useCount: Int = 0,
        isSynthetic: Bool = false,
    ) {
        self.name = name
        self.samples = samples
        let derived = Self.derive(from: samples)
        embeddings = derived.recent
        centroid = derived.centroid
        centroidSampleCount = derived.count
        self.lastUsed = lastUsed
        self.useCount = useCount
        self.isSynthetic = isSynthetic
    }

    /// Build from the pre-history fields, as an entry written before the
    /// history existed would have them. The result carries `migrated` samples
    /// and derives exactly the given `embeddings` / `centroid` / count back.
    init(
        name: String,
        embeddings: [[Float]],
        centroid: [Float]? = nil,
        centroidSampleCount: Int = 0,
        lastUsed: Date? = nil,
        useCount: Int = 0,
        isSynthetic: Bool = false,
    ) {
        self.init(
            name: name,
            samples: Self.migratedSamples(
                embeddings: embeddings, centroid: centroid, centroidSampleCount: centroidSampleCount,
            ),
            lastUsed: lastUsed,
            useCount: useCount,
            isSynthetic: isSynthetic,
        )
    }

    // MARK: - Derivation

    /// Samples that are match anchors besides the centroid: the recent ones
    /// plus every pinned reference sample.
    var anchorEmbeddings: [[Float]] {
        embeddings + samples.filter { $0.pinned && !isRecent($0) }.map(\.embedding)
    }

    private func isRecent(_ sample: VoiceSample) -> Bool {
        Self.recentSamples(of: samples).contains { $0.id == sample.id }
    }

    private static func recentSamples(of samples: [VoiceSample]) -> ArraySlice<VoiceSample> {
        let candidates = samples.filter { $0.origin != .migratedCentroid }
        // An untouched legacy entry keeps every sample it was written with, so
        // it round-trips byte-identically; the FIFO cap applies from the first
        // real sample on, exactly as the old append-and-trim did.
        guard candidates.contains(where: { !$0.isMigrated }) else { return candidates[...] }
        return candidates.suffix(SpeakerMatcher.maxRecentSamples)
    }

    static func derive(from samples: [VoiceSample]) -> (recent: [[Float]], centroid: [Float]?, count: Int) {
        let recent = recentSamples(of: samples).map(\.embedding)
        // The first contributor fixes the dimension; a sample of another one
        // is never averaged in (we do not trust every historical entry).
        guard let dim = samples.first(where: { $0.centroidWeight > 0 && !$0.embedding.isEmpty })?.embedding.count
        else { return (recent, nil, 0) }
        let contributors = samples.filter { $0.centroidWeight > 0 && $0.embedding.count == dim }
        // Samples of an entry that never had a centroid seed one only once a
        // real sample joins them: the lazy seeding older versions did on the
        // first qualifying confirmation.
        guard contributors.contains(where: { $0.origin != .migratedSample }) else { return (recent, nil, 0) }
        let total = contributors.reduce(0) { $0 + $1.centroidWeight }
        if contributors.count == 1 {
            return (recent, contributors[0].embedding, total)
        }
        var mean = [Float](repeating: 0, count: dim)
        for sample in contributors {
            let weight = Float(sample.centroidWeight) / Float(total)
            for i in 0 ..< dim {
                mean[i] += sample.embedding[i] * weight
            }
        }
        return (recent, mean, total)
    }

    static func migratedSamples(
        embeddings: [[Float]], centroid: [Float]?, centroidSampleCount: Int,
    ) -> [VoiceSample] {
        var samples: [VoiceSample] = []
        if let centroid, !centroid.isEmpty {
            samples.append(VoiceSample(
                embedding: centroid, origin: .migratedCentroid, centroidWeight: max(centroidSampleCount, 1),
                id: VoiceSample.migratedID(centroid, origin: .migratedCentroid, index: 0),
            ))
        }
        // Without a centroid the recent samples are what older versions seeded
        // one from; with one they were already averaged into it.
        let sampleWeight = samples.isEmpty ? 1 : 0
        samples += embeddings.enumerated().map { index, embedding in
            VoiceSample(
                embedding: embedding, origin: .migratedSample, centroidWeight: sampleWeight,
                id: VoiceSample.migratedID(embedding, origin: .migratedSample, index: index),
            )
        }
        return samples
    }

    // MARK: - History edits

    /// Copy with `sample` appended and the oldest unpinned samples dropped
    /// past `maxHistory`.
    func appending(_ sample: VoiceSample) -> [VoiceSample] {
        var next = samples + [sample]
        while next.count(where: { !$0.pinned }) > Self.maxHistory,
              let oldest = next.firstIndex(where: { !$0.pinned }) {
            next.remove(at: oldest)
        }
        return next
    }

    /// Copy with a different history, everything else kept.
    func withSamples(_ samples: [VoiceSample]) -> Self {
        Self(name: name, samples: samples, lastUsed: lastUsed, useCount: useCount, isSynthetic: isSynthetic)
    }

    // MARK: - Coding

    // Migrate old single-embedding format automatically (legacy `embedding`
    // key); default lastUsed/useCount for entries before recency tracking;
    // default centroid/centroidSampleCount for entries before v3 schema;
    // derive a migrated history for entries before the history existed.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name = try container.decode(String.self, forKey: .name)
        let lastUsed = try container.decodeIfPresent(Date.self, forKey: .lastUsed)
        let useCount = try container.decodeIfPresent(Int.self, forKey: .useCount) ?? 0
        let isSynthetic = try container.decodeIfPresent(Bool.self, forKey: .isSynthetic) ?? false
        if let samples = try container.decodeIfPresent([VoiceSample].self, forKey: .samples) {
            self.init(name: name, samples: samples, lastUsed: lastUsed, useCount: useCount, isSynthetic: isSynthetic)
            return
        }
        let embeddings: [[Float]] = if let multi = try? container.decode([[Float]].self, forKey: .embeddings) {
            multi
        } else if let single = try? container.decode([Float].self, forKey: .embedding) {
            [single]
        } else {
            []
        }
        try self.init(
            name: name,
            embeddings: embeddings,
            centroid: container.decodeIfPresent([Float].self, forKey: .centroid),
            centroidSampleCount: container.decodeIfPresent(Int.self, forKey: .centroidSampleCount) ?? 0,
            lastUsed: lastUsed,
            useCount: useCount,
            isSynthetic: isSynthetic,
        )
    }

    private enum CodingKeys: String, CodingKey {
        case name, embeddings, embedding, centroid, centroidSampleCount,
             lastUsed, useCount, isSynthetic, samples
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        // The derived anchors are written too, so an older build reading this
        // file still finds a usable entry (it ignores `samples`).
        try container.encode(embeddings, forKey: .embeddings)
        try container.encodeIfPresent(centroid, forKey: .centroid)
        if centroidSampleCount > 0 {
            try container.encode(centroidSampleCount, forKey: .centroidSampleCount)
        }
        try container.encodeIfPresent(lastUsed, forKey: .lastUsed)
        // Skip when 0 so entries that pre-date recency tracking round-trip
        // byte-identical (no spurious useCount=0 field added on first save).
        if useCount > 0 {
            try container.encode(useCount, forKey: .useCount)
        }
        // Same byte-identity rule for legacy entries.
        if isSynthetic {
            try container.encode(isSynthetic, forKey: .isSynthetic)
        }
        // A history of migrated samples only says nothing the fields above do
        // not, and is re-derived from them on load; writing it would rewrite
        // every untouched legacy entry on first save.
        if samples.contains(where: { !$0.isMigrated || $0.pinned }) {
            try container.encode(samples, forKey: .samples)
        }
    }

    /// Copy of this speaker with one more confirmed use at `date` and nothing
    /// else changed: a naming that counts for chip ranking but taught no voice.
    func recordingUse(at date: Date) -> Self {
        Self(name: name, samples: samples, lastUsed: date, useCount: useCount + 1, isSynthetic: isSynthetic)
    }

    /// Copy of this speaker with a new `name`, preserving all other fields.
    /// Used by `SpeakerMatcher.renameSpeaker`; centralises the field list so
    /// future additions don't have to be threaded through the rename site.
    func renamed(to newName: String) -> Self {
        Self(name: newName, samples: samples, lastUsed: lastUsed, useCount: useCount, isSynthetic: isSynthetic)
    }
}

// swiftlint:enable discouraged_optional_collection
