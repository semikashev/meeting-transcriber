import Foundation

/// Pure rule for the window-title shortcut through the browser consent gate
/// (`WatchLoop+Consent`): a browser meeting whose window title contains one of
/// the user's keywords records without asking.
///
/// For calls that never reach a calendar, such as a link pasted into a chat:
/// those always asked, and the prompt timed out unseen while the user was in
/// the call. The title is a weaker signal than the page address, since the
/// detector reads it from the browser window in front, which shows its active
/// tab, so a call in a tab the user is not looking at still asks. Reading the
/// address instead would need Automation access and a scripting dictionary per
/// browser, so the title is what the shortcut keys on.
///
/// Opt-in through the keyword list itself: an empty list vouches for nothing.
/// Matching ignores case and is a plain substring test, not a pattern, so a
/// keyword like "Jitsi Meet" needs no escaping.
enum BrowserTitleVouch {
    static func vouches(windowTitle: String, appName: String, keywords: [String]) -> Bool {
        // The placeholder is the app's own text, written when no window title
        // could be read, so it says nothing about the page. A keyword that
        // happens to match it ("Call") must not vouch for every page.
        guard windowTitle != PowerAssertionDetector.placeholderTitle(appName: appName) else { return false }
        return keywords.contains { windowTitle.range(of: $0, options: .caseInsensitive) != nil }
    }

    /// The setting is one free-text field, so the user can type a keyword
    /// with spaces in it; commas and line breaks separate keywords.
    static func keywords(from raw: String) -> [String] {
        raw.split { $0 == "," || $0.isNewline }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
