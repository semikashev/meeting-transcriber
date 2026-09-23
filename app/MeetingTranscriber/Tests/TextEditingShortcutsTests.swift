import AppKit
@testable import MeetingTranscriber
import XCTest

/// The edit shortcuts that must work in text fields without the main menu.
@MainActor
final class TextEditingShortcutsTests: XCTestCase {
    private func action(_ characters: String?, keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags) -> Selector? {
        TextEditingShortcuts.action(keyCode: keyCode, charactersIgnoringModifiers: characters, modifiers: modifiers)
    }

    func testStandardEditKeysMapToTheirActions() {
        XCTAssertEqual(action("x", keyCode: 0x07, .command), #selector(NSText.cut(_:)))
        XCTAssertEqual(action("c", keyCode: 0x08, .command), #selector(NSText.copy(_:)))
        XCTAssertEqual(action("v", keyCode: 0x09, .command), #selector(NSText.paste(_:)))
        XCTAssertEqual(action("a", keyCode: 0x00, .command), #selector(NSText.selectAll(_:)))
        XCTAssertEqual(action("z", keyCode: 0x06, .command), Selector(("undo:")))
        XCTAssertEqual(action("Z", keyCode: 0x06, [.command, .shift]), Selector(("redo:")))
    }

    func testCyrillicLayoutFallsBackToTheKeyPosition() {
        XCTAssertEqual(action("м", keyCode: 0x09, .command), #selector(NSText.paste(_:)))
        XCTAssertEqual(action("ф", keyCode: 0x00, .command), #selector(NSText.selectAll(_:)))
    }

    func testCapsLockDoesNotMatter() {
        XCTAssertEqual(action("v", keyCode: 0x09, [.command, .capsLock]), #selector(NSText.paste(_:)))
    }

    func testOtherKeysAndModifiersAreLeftAlone() {
        XCTAssertNil(action("v", keyCode: 0x09, []), "a plain v is typing")
        XCTAssertNil(action("v", keyCode: 0x09, [.command, .option]))
        XCTAssertNil(action("v", keyCode: 0x09, [.command, .control]))
        XCTAssertNil(action("v", keyCode: 0x09, [.command, .shift]), "⇧⌘V is not paste")
        XCTAssertNil(action("q", keyCode: 0x0C, .command))
        XCTAssertNil(action(",", keyCode: 0x2B, .command))
    }

    /// The whole path on a real field editor, with no main menu involved:
    /// ⌘A selects the field's text.
    func testCommandASelectsTheFocusedFieldsText() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 60),
            styleMask: [.titled], backing: .buffered, defer: false,
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let field = NSTextField(string: "hello")
        field.frame = NSRect(x: 10, y: 10, width: 180, height: 24)
        window.contentView?.addSubview(field)
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        editor.setSelectedRange(NSRange(location: 5, length: 0))

        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: window.windowNumber, context: nil,
            characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0x00,
        ))

        XCTAssertTrue(TextEditingShortcuts.handle(event))
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: 5))
    }

    func testKeysOutsideATextFieldPassThrough() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 60),
            styleMask: [.titled], backing: .buffered, defer: false,
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: window.windowNumber, context: nil,
            characters: "v", charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 0x09,
        ))
        XCTAssertFalse(TextEditingShortcuts.handle(event))
    }
}
