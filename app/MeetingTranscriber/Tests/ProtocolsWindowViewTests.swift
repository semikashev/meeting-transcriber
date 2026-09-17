@testable import MeetingTranscriber
import SwiftUI
import ViewInspector
import XCTest

/// The Protocols window: one row per recording, delete through callbacks so
/// the view never touches the file system, busy rows locked.
@MainActor
final class ProtocolsWindowViewTests: XCTestCase {
    private func entry(_ stem: String, title: String, bytes: Int64 = 0, busy: Bool = false) -> ProtocolEntry {
        ProtocolEntry(
            stem: stem, recordedAt: Date(timeIntervalSince1970: 1_800_000_000), title: title,
            protocolURL: nil, transcriptURL: nil, audioURLs: [], audioBytes: bytes, isBusy: busy,
        )
    }

    func testListsEveryEntryWithItsTitle() throws {
        let view = ProtocolsWindowView(
            entries: [entry("a", title: "Weekly sync"), entry("b", title: "Design review")],
            onOpen: { _ in }, onReveal: { _ in }, onDelete: { _, _ in }, onRefresh: {},
        )
        let body = try view.inspect()
        XCTAssertNoThrow(try body.find(text: "Weekly sync"))
        XCTAssertNoThrow(try body.find(text: "Design review"))
    }

    func testFooterSumsRecordingsAndAudio() throws {
        let view = ProtocolsWindowView(
            entries: [entry("a", title: "A", bytes: 600_000_000), entry("b", title: "B", bytes: 400_000_000)],
            onOpen: { _ in }, onReveal: { _ in }, onDelete: { _, _ in }, onRefresh: {},
        )
        XCTAssertNoThrow(try view.inspect().find(text: "2 recordings · 1 GB of audio"))
    }

    func testEmptyFolderSaysSo() throws {
        let view = ProtocolsWindowView(entries: [], onOpen: { _ in }, onReveal: { _ in }, onDelete: { _, _ in }, onRefresh: {})
        XCTAssertNoThrow(try view.inspect().find(text: "No recordings yet"))
    }

    func testDeleteButtonsPassTheEntryAndScope() throws {
        var deleted: [(String, ProtocolRemovalScope)] = []
        let view = ProtocolsWindowView(
            entries: [entry("a", title: "A", bytes: 10)],
            onOpen: { _ in }, onReveal: { _ in },
            onDelete: { deleted.append(($0.stem, $1)) }, onRefresh: {},
        )

        try view.inspect().find(button: "Delete audio").tap()
        try view.inspect().find(button: "Delete").tap()

        XCTAssertEqual(deleted.map(\.0), ["a", "a"])
        XCTAssertEqual(deleted.map(\.1), [.audioOnly, .everything])
    }

    /// A job in the pipeline still reads these files; the row shows why
    /// instead of offering a delete that would break it.
    func testBusyRowsHaveNoDeleteButtons() throws {
        let view = ProtocolsWindowView(
            entries: [entry("a", title: "A", bytes: 10, busy: true)],
            onOpen: { _ in }, onReveal: { _ in }, onDelete: { _, _ in }, onRefresh: {},
        )
        let body = try view.inspect()
        XCTAssertThrowsError(try body.find(button: "Delete"))
        XCTAssertNoThrow(try body.find(text: "In progress"))
    }

    /// Nothing to trash when the audio is already gone: the button would be
    /// a no-op with a scary label.
    func testDeleteAudioAbsentWhenThereIsNoAudio() throws {
        let view = ProtocolsWindowView(
            entries: [entry("a", title: "A", bytes: 0)],
            onOpen: { _ in }, onReveal: { _ in }, onDelete: { _, _ in }, onRefresh: {},
        )
        XCTAssertThrowsError(try view.inspect().find(button: "Delete audio"))
        XCTAssertNoThrow(try view.inspect().find(button: "Delete"))
    }
}
