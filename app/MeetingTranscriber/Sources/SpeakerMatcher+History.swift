import Foundation

/// Edits to a speaker's sample history. Each recomputes the derived centroid
/// and recent samples from what remains (see `VoiceSample`).
extension SpeakerMatcher {
    /// Drop the given samples from one speaker; its centroid and recent
    /// samples are recomputed from what remains. A speaker left without
    /// samples keeps its name (and chip ranking) but no longer matches.
    /// Returns the number of samples removed.
    @discardableResult
    func removeSamples(_ ids: Set<UUID>, from name: String) -> Int {
        mutateDB { stored in
            guard let idx = stored.firstIndex(where: { $0.name == name }) else { return 0 }
            let kept = stored[idx].samples.filter { !ids.contains($0.id) }
            let removed = stored[idx].samples.count - kept.count
            if removed > 0 { stored[idx] = stored[idx].withSamples(kept) }
            return removed
        }
    }

    /// Undo what one recording taught the database: every sample it
    /// contributed, across all speakers, is removed. Contributions already
    /// evicted from a history, or averaged into a migrated centroid, are
    /// beyond reach. Returns the names of the speakers that changed.
    @discardableResult
    func removeContributions(ofJob jobID: UUID) -> [String] {
        mutateDB { stored in
            var changed: [String] = []
            for idx in stored.indices where stored[idx].samples.contains(where: { $0.jobID == jobID }) {
                stored[idx] = stored[idx].withSamples(stored[idx].samples.filter { $0.jobID != jobID })
                changed.append(stored[idx].name)
            }
            return changed
        }
    }

    /// Pin or unpin one sample as a reference voice (see `VoiceSample.pinned`).
    @discardableResult
    func setPinned(_ pinned: Bool, sample id: UUID, of name: String) -> Bool {
        mutateDB { stored in
            guard let idx = stored.firstIndex(where: { $0.name == name }),
                  let sampleIdx = stored[idx].samples.firstIndex(where: { $0.id == id }) else { return false }
            var samples = stored[idx].samples
            samples[sampleIdx] = samples[sampleIdx].pinned(pinned)
            stored[idx] = stored[idx].withSamples(samples)
            return true
        }
    }
}
