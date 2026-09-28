import CryptoKit
import Foundation

/// One embedding a stored speaker was learned from, with where it came from.
///
/// The speaker database used to keep only a running-mean centroid and the last
/// three embeddings. A running mean has no history, so a sample learned by
/// mistake stayed in the centroid for good and nothing could say which meeting
/// had put it there. A speaker now keeps a bounded history of these instead;
/// its centroid and recent samples are derived from it (see
/// `StoredSpeaker.init(name:samples:…)`), so removing one sample, or every
/// sample one meeting contributed, recomputes both exactly.
///
/// Entries written before the history existed are carried as `migrated`
/// samples: their centroid becomes one sample weighted by the number of
/// confirmations it had averaged, which keeps the old centroid bit-for-bit
/// until a real sample joins it, but can only ever be removed as a whole.
struct VoiceSample: Codable, Equatable, Identifiable {
    enum Origin: String, Codable {
        /// Confirmed in a meeting's naming dialog (or its automation API).
        case meeting
        /// Enrolled from a recording picked in Settings → Known Voices.
        case enrollment
        /// The running-mean centroid of an entry written before the history existed.
        case migratedCentroid = "migrated_centroid"
        /// A recent sample of an entry written before the history existed.
        case migratedSample = "migrated_sample"
    }

    let id: UUID
    let embedding: [Float]
    let origin: Origin
    /// How many confirmations this sample stands for in the centroid. 1 for a
    /// learned sample, the old averaging count for a migrated centroid, 0 for
    /// a sample that is kept only as a recent-sample anchor (unknown length,
    /// or a dimension the centroid cannot take).
    let centroidWeight: Int
    let addedAt: Date?
    /// Seconds of speech behind the embedding; nil when unknown.
    let duration: TimeInterval?
    /// Which diarized track the embedding was taken from; nil when unknown.
    let track: SpeakerKey.Track?
    let jobID: UUID?
    let meetingTitle: String?
    /// A reference sample the user chose to keep: never evicted by newer
    /// samples, never dropped as an outlier, and always a match anchor.
    let pinned: Bool

    init(
        embedding: [Float],
        origin: Origin,
        centroidWeight: Int,
        addedAt: Date? = nil,
        duration: TimeInterval? = nil,
        track: SpeakerKey.Track? = nil,
        jobID: UUID? = nil,
        meetingTitle: String? = nil,
        pinned: Bool = false,
        id: UUID = UUID(),
    ) {
        self.id = id
        self.embedding = embedding
        self.origin = origin
        self.centroidWeight = centroidWeight
        self.addedAt = addedAt
        self.duration = duration
        self.track = track
        self.jobID = jobID
        self.meetingTitle = meetingTitle
        self.pinned = pinned
    }

    /// Identity of a migrated sample, derived from its content. Migrated
    /// samples are re-derived on every load until a real sample joins them,
    /// so a random id would change between the load that shows a sample and
    /// the one that removes it, and the removal would find nothing.
    static func migratedID(_ embedding: [Float], origin: Origin, index: Int) -> UUID {
        var hasher = SHA256()
        hasher.update(data: Data(origin.rawValue.utf8))
        withUnsafeBytes(of: Int64(index).littleEndian) { hasher.update(bufferPointer: $0) }
        embedding.withUnsafeBytes { hasher.update(bufferPointer: $0) }
        var bytes = Array(hasher.finalize().prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50 // name-based UUID (version 5 layout)
        bytes[8] = (bytes[8] & 0x3F) | 0x80 // RFC 4122 variant
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15],
        ))
    }

    var isMigrated: Bool {
        origin == .migratedCentroid || origin == .migratedSample
    }

    /// Copy with `pinned` set.
    func pinned(_ value: Bool) -> Self {
        Self(
            embedding: embedding, origin: origin, centroidWeight: centroidWeight,
            addedAt: addedAt, duration: duration, track: track, jobID: jobID,
            meetingTitle: meetingTitle, pinned: value, id: id,
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id, embedding, origin, centroidWeight, addedAt, duration, track, jobID, meetingTitle, pinned
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        embedding = try c.decode([Float].self, forKey: .embedding)
        origin = try c.decode(Origin.self, forKey: .origin)
        centroidWeight = try c.decode(Int.self, forKey: .centroidWeight)
        addedAt = try c.decodeIfPresent(Date.self, forKey: .addedAt)
        duration = try c.decodeIfPresent(TimeInterval.self, forKey: .duration)
        track = try c.decodeIfPresent(SpeakerKey.Track.self, forKey: .track)
        jobID = try c.decodeIfPresent(UUID.self, forKey: .jobID)
        meetingTitle = try c.decodeIfPresent(String.self, forKey: .meetingTitle)
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(embedding, forKey: .embedding)
        try c.encode(origin, forKey: .origin)
        try c.encode(centroidWeight, forKey: .centroidWeight)
        try c.encodeIfPresent(addedAt, forKey: .addedAt)
        try c.encodeIfPresent(duration, forKey: .duration)
        try c.encodeIfPresent(track, forKey: .track)
        try c.encodeIfPresent(jobID, forKey: .jobID)
        try c.encodeIfPresent(meetingTitle, forKey: .meetingTitle)
        if pinned { try c.encode(pinned, forKey: .pinned) }
    }
}

/// Where a confirmed embedding came from, for the history entry it becomes.
struct SampleProvenance: Equatable {
    var origin: VoiceSample.Origin = .meeting
    var jobID: UUID?
    var meetingTitle: String?
    /// Diarized track of the label; set per label by `SpeakerMatcher.updateDB`.
    var track: SpeakerKey.Track?
    /// Learn the sample as a reference voice (see `VoiceSample.pinned`).
    var pinned = false
}
