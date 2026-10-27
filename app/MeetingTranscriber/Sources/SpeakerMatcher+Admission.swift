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
        /// Close to samples of several other people at once (see
        /// `hubSampleDistance`), whatever it is nearest to.
        case hub(near: [String])
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
    /// A confirmed embedding within this distance of samples of at least
    /// `hubMinimumPeople` other people is not learned, even when it is nearest
    /// to the named voice. Short fragments, crosstalk and noise give
    /// embeddings that crowd into one region of the space: on a corpus of 86
    /// meetings 174 of 655 labels sat within 0.25 of one point, spread 0.04
    /// around it, under about 30 names. A profile that learns such a vector
    /// takes everyone's fragments; the ambiguity rule above misses it because
    /// the vector is usually nearest to the profile it was confirmed for.
    ///
    /// Replayed from an empty database over those meetings, wrong names went
    /// from 47 to 33 and correct ones from 266 to 263. 0.15 barely moved
    /// (45 wrong), 0.25 let more through (48), requiring three people instead
    /// of two held back less (42 at 0.20). The same test is deliberately not a
    /// Known Voices clean-up: on a database cleaned by hand, removing the
    /// stored samples it flags at 0.20 cost more names than it saved (wrong 11
    /// to 17), and at 0.15 it added nothing to the existing rules.
    static let hubSampleDistance: Float = 0.20
    static let hubMinimumPeople = 2

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
        let near = hubNeighbours(of: embedding, excluding: [name], in: stored)
        if near.count >= hubMinimumPeople { return .hub(near: near) }
        return .admitted
    }

    /// Names, sorted, of the people outside `excluded` holding any sample in
    /// their history within `hubSampleDistance` of `embedding`.
    static func hubNeighbours(of embedding: [Float], excluding excluded: Set<String>, in stored: [StoredSpeaker]) -> [String] {
        stored
            .filter { !excluded.contains($0.name) && !$0.isSynthetic }
            .filter { speaker in
                speaker.samples.contains { cosineDistance(embedding, $0.embedding) < hubSampleDistance }
            }
            .map(\.name)
            .sorted()
    }
}
