import Foundation

/// What a confirmed speaker-naming dialog settles on. The dialog seeds every
/// name field with the matcher's suggestion, so a confirmation carries three
/// kinds of entry: a name, an empty name (a suggestion the user deleted), and
/// no entry at all (a label the caller left out, which keeps its suggestion;
/// the automation API relies on that).
///
/// A deleted suggestion used to be treated like a label left out: the
/// confirmed names were laid over the suggestions and an empty field overrode
/// nothing, so the name the user had just rejected was learned for that voice
/// and stayed on its transcript lines. A wrong suggestion then reinforced
/// itself on every meeting where the user corrected it.
enum NamingConfirmation {
    /// The name each label ends up with. A cleared suggestion sends its label
    /// back to itself, which every consumer reads as unnamed:
    /// `SpeakerMatcher.updateDB` learns nothing for it and the recognition log
    /// records it as skipped.
    static func resolvedNames(suggested: [String: String], confirmed: [String: String]) -> [String: String] {
        var names = suggested
        for (label, name) in confirmed {
            names[label] = name.isEmpty ? label : name
        }
        return names
    }

    /// Puts the label back on the transcript lines of each cleared suggestion,
    /// but only where the suggestion was that label's alone. The matcher can
    /// give one name to two labels of a track, and a written line no longer
    /// says which label spoke it, so a shared name stays on every line rather
    /// than being stripped from the label that kept it.
    static func revertClearedSuggestions(
        in transcript: String, suggested: [String: String], confirmed: [String: String],
    ) -> String {
        var result = transcript
        for (label, name) in confirmed where name.isEmpty {
            guard let suggestion = suggested[label], suggestion != label,
                  suggested.values.count(where: { $0 == suggestion }) == 1
            else { continue }
            // Same anchor as the rename that follows: `] ` + speaker + `:`.
            result = result.replacingOccurrences(of: "] \(suggestion):", with: "] \(label):")
        }
        return result
    }
}
