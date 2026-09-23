import AppKit

/// ⌘X, ⌘C, ⌘V, ⌘A, ⌘Z and ⇧⌘Z in the app's text fields, without relying on
/// the main menu.
///
/// AppKit text views do not handle these keys themselves: the key goes to
/// the main menu as a key equivalent, and the Edit menu's item sends `paste:`
/// and friends to the first responder. This app is an `LSUIElement` agent,
/// so its main menu is never on screen, and pasting a URL into a Settings
/// field was reported not to work. A minimal SwiftUI agent with the same
/// scene types does get a working Edit menu, so the menu is not missing in
/// general; what loses the key in this app was not reproduced. Rather than
/// depend on the menu, a local key monitor sends the same actions down the
/// same responder chain the menu item would, so the shortcut works whether
/// or not a menu is there to catch it. It only acts while a text view has
/// focus and returns every other key untouched, so the app's own
/// `.keyboardShortcut`s keep working.
@MainActor
enum TextEditingShortcuts {
    private static var monitor: Any?

    /// ANSI virtual key codes (`kVK_ANSI_*`), used when the layout does not
    /// produce a Latin letter: with a Cyrillic layout ⌘V arrives as "м".
    nonisolated private static let keyCodes: [UInt16: Character] = [0x00: "a", 0x06: "z", 0x07: "x", 0x08: "c", 0x09: "v"]

    /// The standard edit action for a key press, nil when it is not one.
    nonisolated static func action(
        keyCode: UInt16, charactersIgnoringModifiers: String?, modifiers: NSEvent.ModifierFlags,
    ) -> Selector? {
        let flags = modifiers.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        guard flags == .command || flags == [.command, .shift] else { return nil }
        let typed = charactersIgnoringModifiers?.lowercased().first
        let letter = typed.flatMap { $0.isASCII && $0.isLetter ? $0 : nil } ?? keyCodes[keyCode]
        switch (letter, flags.contains(.shift)) {
        case ("x", false): return #selector(NSText.cut(_:))
        case ("c", false): return #selector(NSText.copy(_:))
        case ("v", false): return #selector(NSText.paste(_:))
        case ("a", false): return #selector(NSText.selectAll(_:))
        case ("z", false): return Selector(("undo:"))
        case ("z", true): return Selector(("redo:"))
        default: return nil
        }
    }

    /// Perform the edit action for `event` on its window's focused text
    /// view. Returns whether the event was consumed.
    static func handle(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              let responder = event.window?.firstResponder, responder is NSText,
              let action = action(
                  keyCode: event.keyCode,
                  charactersIgnoringModifiers: event.charactersIgnoringModifiers,
                  modifiers: event.modifierFlags,
              )
        else { return false }
        // Walks the responder chain from the field editor up to the window,
        // which is where `undo:` is answered.
        return responder.tryToPerform(action, with: nil)
    }

    /// Install once, at launch.
    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { handle(event) } ? nil : event
        }
    }
}
