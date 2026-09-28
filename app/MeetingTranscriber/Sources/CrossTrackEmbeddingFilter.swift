import Foundation

/// Keeps a person who was named on both tracks of one recording from being
/// learned from the track they did not speak into.
///
/// On a dual-source recording a remote voice played through the loudspeakers
/// reaches the microphone as well, the microphone diarization gives it a
/// cluster of its own, and the naming dialog offers that cluster for naming
/// like any other. Naming it after the remote participant is correct for the
/// transcript, but its embedding describes loudspeaker, room and microphone as
/// much as the voice, and the same chain colours every bleed cluster alike: on
/// a real database one such vector had ended up under eight different people,
/// matching each at a distance of 0.02 and therefore none of them with a
/// margin. The same happens the other way round when the local voice returns
/// through the far end.
///
/// The echo detector only catches recordings it measured as affected, while
/// the naming itself already says which clusters are the same person: one
/// name on both tracks. The copy on the track with less speaking time is the
/// bleed and is dropped; a tie drops both, since there is nothing to tell them
/// apart. Deliberately keyed on speaking time rather than on who the owner is,
/// so it needs no notion of whose machine this is.
///
/// Like `EchoEmbeddingQuarantine`, this gates only what reaches the speaker
/// database; the transcript keeps every name the user gave.
enum CrossTrackEmbeddingFilter {
    static func admissible(
        _ embeddings: [String: [Float]],
        mapping: [String: String],
        speakingTimes: [String: TimeInterval],
    ) -> [String: [Float]] {
        // Total speaking time per (name, track), over the labels that carry a
        // confirmed name. A label mapped to itself is unnamed, not a person.
        var perTrack: [String: [SpeakerKey.Track: TimeInterval]] = [:]
        for (label, name) in mapping where name != label && !name.isEmpty {
            let track = SpeakerKey(encoded: label).track
            guard track != .single else { continue }
            perTrack[name, default: [:]][track, default: 0] += speakingTimes[label] ?? 0
        }

        // Names heard on both tracks, with the track to keep; `nil` for a tie.
        var onBoth: [String: SpeakerKey.Track?] = [:]
        for (name, times) in perTrack {
            guard let app = times[.app], let mic = times[.mic] else { continue }
            onBoth.updateValue(app > mic ? .app : mic > app ? .mic : nil, forKey: name)
        }
        guard !onBoth.isEmpty else { return embeddings }

        return embeddings.filter { label, _ in
            guard let name = mapping[label], let keep = onBoth[name] else { return true }
            return keep == SpeakerKey(encoded: label).track
        }
    }
}
