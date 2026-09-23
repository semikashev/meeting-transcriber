import Foundation

/// Turns a calendar attendee into the name a speaker label should carry.
///
/// EventKit gives no name for many Google and Exchange attendees, and the
/// lookup used to fall back to the bare address. That address then labelled
/// voices in the naming step and named speaker profiles, so one colleague
/// ended up under two labels (`jsmith@example.com` next to `John Smith`).
///
/// Resolution order: the user's alias file, then a `first.last@` address read
/// as "First Last", then the input unchanged. The derivation stops at anything
/// less regular (`jsmith@`, `petrov.av@`, `a.petrov@`): a wrong name is
/// worse than an address the user recognises and can map in the alias file.
enum ParticipantDisplayName {
    /// UserDefaults key holding the path of the alias file. There is no
    /// Settings UI for it: `defaults write app.meetingtranscriber
    /// participantAliasesPath <path>`.
    static let aliasesPathKey = "participantAliasesPath"

    static func resolve(_ attendee: String, aliases: [String: String]) -> String {
        let key = attendee.trimmingCharacters(in: .whitespaces).lowercased()
        if let alias = aliases[key] { return alias }
        return derivedName(fromAddress: attendee) ?? attendee
    }

    /// `Display Name => alias | alias`, one person per line, the format the
    /// terminology rules already use. Blank lines and `#` comments are
    /// skipped; aliases match without regard to case.
    static func parseAliases(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            let parts = trimmed.components(separatedBy: "=>")
            guard parts.count == 2 else { continue }
            let name = parts[0].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            for alias in parts[1].components(separatedBy: "|") {
                let key = alias.trimmingCharacters(in: .whitespaces).lowercased()
                if !key.isEmpty { result[key] = name }
            }
        }
        return result
    }

    /// "anna.petrova@example.org" → "Anna Petrova". Exactly two
    /// dot-separated parts of three or more letters each, so initials and
    /// nicknames stay addresses instead of turning into wrong names.
    static func derivedName(fromAddress address: String) -> String? {
        let parts = address.split(separator: "@")
        guard parts.count == 2 else { return nil }
        let words = parts[0].split(separator: ".")
        guard words.count == 2,
              words.allSatisfy({ $0.count >= 3 && $0.allSatisfy(\.isLetter) }) else { return nil }
        return words.map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }.joined(separator: " ")
    }

    /// The alias file named in defaults, read on every call so an edit
    /// applies to the next recording without a restart. Empty when unset or
    /// unreadable.
    static func aliasesFromDefaults(_ defaults: UserDefaults = .standard) -> [String: String] {
        guard let path = defaults.string(forKey: aliasesPathKey), !path.isEmpty,
              let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [:] }
        return parseAliases(text)
    }
}
