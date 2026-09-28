import Foundation

/// The gate every confirmed embedding passes before it may teach the database
/// a voice (see `SpeakerMatcher.updateDB`).
extension SpeakerMatcher {
    /// Whether a confirmed embedding may teach the DB the voice it was named as.
    enum SampleAdmission: Equatable {
        case admitted
        /// Less speech behind it than `minSpeakingTimeForSample`.
        case tooShort
        /// Already stands for another stored person at least as well as for
        /// the named one (see `ambiguousSampleDistance`).
        case ambiguous(nearest: String)
    }

    /// Minimum speaking time behind an embedding for it to be learned at all.
    /// Below it the recent-samples FIFO used to take it anyway as a fallback;
    /// matching takes the minimum over those samples, so one such vector
    /// decided matches on its own.
    static let minSpeakingTimeForSample: TimeInterval = 3.0
    /// A confirmed embedding this close to another person's anchor is not
    /// learned for the named one. Such a vector matches both people at once:
    /// neither then clears `confidenceMargin`, the user types the name by
    /// hand, and the same vector is written under yet another person. On a
    /// real database this loop had spread one vector across eight people.
    /// Distinct people's centroids sat no closer than 0.26 on that database,
    /// so the radius does not reach a merely similar voice.
    static let ambiguousSampleDistance: Float = 0.15

    /// Pure: decide whether `embedding`, confirmed as `name`, may be learned.
    /// A missing duration is not judged, so legacy callers keep their samples.
    static func sampleAdmission(
        _ embedding: [Float], named name: String, duration: TimeInterval?, against stored: [StoredSpeaker],
    ) -> SampleAdmission {
        if let duration, duration < minSpeakingTimeForSample { return .tooShort }
        let own = stored.first { $0.name == name }
            .map { distance(query: embedding, speaker: $0) } ?? .greatestFiniteMagnitude
        let nearestOther = stored
            .filter { $0.name != name && !$0.isSynthetic }
            .map { (name: $0.name, distance: distance(query: embedding, speaker: $0)) }
            .min { $0.distance < $1.distance }
        if let nearestOther, nearestOther.distance < ambiguousSampleDistance, nearestOther.distance <= own {
            return .ambiguous(nearest: nearestOther.name)
        }
        return .admitted
    }
}
