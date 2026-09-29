import Foundation

/// Finds what is suspect in the speaker database, for Known Voices to show
/// and to clean up. Pure, so the rules are tested here rather than through
/// the view.
///
/// Three findings, each one a way the database was seen to go wrong on real
/// data before the write path was hardened:
/// - two profiles whose centroids nearly coincide, usually one person saved
///   under two spellings (a display name and an e-mail address);
/// - a sample that stands for another person at least as well as for its own:
///   bleed or a mislabelled cluster, the kind that ended up under eight names;
/// - a sample far from its own centroid while that centroid rests on enough
///   confirmations to be trusted: a different voice under this name.
///
/// Only the last two are samples, and only those are cleaned up automatically;
/// a possible duplicate is for the user to merge or not. Pinned reference
/// samples are reported but never removed by a clean-up.
enum VoiceHealth {
    enum Issue: Hashable {
        case possibleDuplicate(of: String)
        case sharedSample(UUID, with: String)
        case outlierSample(UUID)

        var sampleID: UUID? {
            switch self {
            case .possibleDuplicate: nil
            case let .sharedSample(id, _), let .outlierSample(id): id
            }
        }
    }

    /// Profiles whose centroids are this close are flagged as one person. On
    /// the real database two spellings of one person sat at 0.04, the closest
    /// distinct people at 0.26.
    static let duplicateDistance: Float = 0.10
    /// A sample this far from its own centroid is flagged, once the centroid
    /// averages at least `outlierMinimumCount` confirmations.
    static let outlierDistance: Float = 0.55
    static let outlierMinimumCount = 4

    /// Findings per speaker name; speakers without findings are absent.
    static func issues(in speakers: [StoredSpeaker]) -> [String: [Issue]] {
        let real = speakers.filter { !$0.isSynthetic }
        var found: [String: [Issue]] = [:]
        var duplicates: [String: Set<String>] = [:]

        for (i, a) in real.enumerated() {
            guard let ca = a.centroid else { continue }
            for b in real[(i + 1)...] {
                guard let cb = b.centroid,
                      SpeakerMatcher.cosineDistance(ca, cb) < duplicateDistance else { continue }
                found[a.name, default: []].append(.possibleDuplicate(of: b.name))
                found[b.name, default: []].append(.possibleDuplicate(of: a.name))
                duplicates[a.name, default: []].insert(b.name)
                duplicates[b.name, default: []].insert(a.name)
            }
        }

        for speaker in real {
            // A duplicate's samples are this voice's own: the fix is a merge,
            // and judging them against each other would clean both out.
            let others = real.filter { !(duplicates[speaker.name]?.contains($0.name) ?? false) }
            for sample in speaker.samples where sample.origin != .migratedCentroid {
                if let issue = sampleIssue(sample, of: speaker, among: others) {
                    found[speaker.name, default: []].append(issue)
                }
            }
        }
        return found
    }

    private static func sampleIssue(
        _ sample: VoiceSample, of speaker: StoredSpeaker, among speakers: [StoredSpeaker],
    ) -> Issue? {
        let own = speaker.centroid.map { SpeakerMatcher.cosineDistance(sample.embedding, $0) }
        let nearestOther = speakers
            .filter { $0.name != speaker.name }
            .map { (name: $0.name, distance: SpeakerMatcher.distance(query: sample.embedding, speaker: $0)) }
            .min { $0.distance < $1.distance }
        if let nearestOther,
           nearestOther.distance < SpeakerMatcher.ambiguousSampleDistance,
           nearestOther.distance <= (own ?? .greatestFiniteMagnitude) {
            return .sharedSample(sample.id, with: nearestOther.name)
        }
        if let own, own > outlierDistance, speaker.centroidSampleCount >= outlierMinimumCount {
            return .outlierSample(sample.id)
        }
        return nil
    }

    /// Samples a clean-up would remove: every shared or outlier sample that
    /// is not pinned, per speaker name.
    static func cleanUpPlan(for speakers: [StoredSpeaker]) -> [String: Set<UUID>] {
        let pinned = Set(speakers.flatMap { $0.samples.filter(\.pinned).map(\.id) })
        var plan: [String: Set<UUID>] = [:]
        for (name, issues) in issues(in: speakers) {
            let ids = Set(issues.compactMap(\.sampleID)).subtracting(pinned)
            if !ids.isEmpty { plan[name] = ids }
        }
        return plan
    }

    /// One-line summary for the Known Voices table.
    static func summary(_ issues: [Issue]) -> String {
        guard !issues.isEmpty else { return "OK" }
        let suspect = Set(issues.compactMap(\.sampleID)).count
        let duplicate = issues.contains { if case .possibleDuplicate = $0 { true } else { false } }
        var parts: [String] = []
        if duplicate { parts.append("duplicate?") }
        if suspect > 0 { parts.append("\(suspect) suspect sample\(suspect == 1 ? "" : "s")") }
        return parts.joined(separator: ", ")
    }

    /// Longer explanation, for a tooltip.
    static func details(_ issues: [Issue]) -> String {
        issues.map { issue in
            switch issue {
            case let .possibleDuplicate(other):
                "Sounds like the same person as \(other). Merge if it is."

            case let .sharedSample(_, other):
                "A sample matches \(other) at least as well as this voice."

            case .outlierSample:
                "A sample is far from this voice's average."
            }
        }.joined(separator: "\n")
    }
}
