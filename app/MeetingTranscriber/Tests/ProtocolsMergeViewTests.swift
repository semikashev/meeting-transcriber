@testable import MeetingTranscriber
import SwiftUI
import ViewInspector
import XCTest

/// Selecting rows in the Protocols window and merging them: the button's
/// enable rule, the dialog it opens, and what the dialog hands back.
@MainActor
final class ProtocolsMergeViewTests: XCTestCase {
    private func entry(_ stem: String, title: String, hour: Int = 10, audio: Bool = true, busy: Bool = false) -> ProtocolEntry {
        var comps = DateComponents()
        comps.year = 2026
        comps.month = 9
        comps.day = 29
        comps.hour = hour
        return ProtocolEntry(
            stem: stem, recordedAt: Calendar.current.date(from: comps) ?? Date(), title: title,
            protocolURL: nil, transcriptURL: nil,
            audioURLs: audio ? [URL(fileURLWithPath: "/tmp/\(stem)_mix.wav")] : [],
            audioBytes: audio ? 10 : 0, isBusy: busy,
        )
    }

    private func window(
        _ entries: [ProtocolEntry], selected: Set<String>, onMerge: @escaping (SessionMergeRequest) -> Void = { _ in },
    ) -> (ProtocolsWindowView, ProtocolsMergeState) {
        let state = ProtocolsMergeState()
        state.selectedStems = selected
        let view = ProtocolsWindowView(
            entries: entries,
            onOpen: { _ in }, onReveal: { _ in }, onDelete: { _, _ in }, onRefresh: {},
            onMerge: onMerge, merge: state,
        )
        return (view, state)
    }

    private func mergeButton(_ view: ProtocolsWindowView) throws -> InspectableView<ViewType.Button> {
        try view.inspect().find(viewWithAccessibilityIdentifier: A11yID.protocolsMerge).find(ViewType.Button.self)
    }

    // MARK: - Button enable rule

    func testMergeButtonIsDisabledWithoutASelection() throws {
        let (view, _) = window([entry("a", title: "A"), entry("b", title: "B", hour: 11)], selected: [])
        XCTAssertTrue(try mergeButton(view).isDisabled())
    }

    func testMergeButtonIsDisabledForOneRecording() throws {
        let (view, _) = window([entry("a", title: "A"), entry("b", title: "B", hour: 11)], selected: ["a"])
        XCTAssertTrue(try mergeButton(view).isDisabled())
    }

    func testMergeButtonIsEnabledForTwoRecordingsWithAudio() throws {
        let (view, _) = window([entry("a", title: "A"), entry("b", title: "B", hour: 11)], selected: ["a", "b"])
        XCTAssertFalse(try mergeButton(view).isDisabled())
    }

    func testBusyAndAudiolessRowsDoNotCountTowardsTheTwo() throws {
        let rows = [
            entry("a", title: "A"), entry("busy", title: "Busy", hour: 11, busy: true),
            entry("bare", title: "Bare", hour: 12, audio: false), entry("b", title: "B", hour: 13),
        ]
        let (oneUsable, _) = window(rows, selected: ["a", "busy", "bare"])
        XCTAssertTrue(try mergeButton(oneUsable).isDisabled())

        let (twoUsable, _) = window(rows, selected: ["a", "busy", "bare", "b"])
        XCTAssertFalse(try mergeButton(twoUsable).isDisabled())
    }

    // MARK: - Opening the dialog

    func testTappingMergeOpensTheDialogWithTheSelectionOldestFirst() throws {
        let (view, state) = window(
            [entry("late", title: "Zoom part", hour: 11), entry("early", title: "Telemost part", hour: 10), entry("other", title: "Other", hour: 12)],
            selected: ["late", "early"],
        )

        try mergeButton(view).tap()

        let draft = try XCTUnwrap(state.draft)
        XCTAssertEqual(draft.mergeable.map(\.stem), ["early", "late"])
        XCTAssertEqual(draft.title, "Telemost part")
        XCTAssertFalse(draft.deleteOriginals, "originals are kept unless the user opts in")
        XCTAssertTrue(draft.skipped.isEmpty)
    }

    func testBeginMergeDoesNothingWhenTheSelectionIsNotMergeable() {
        let state = ProtocolsMergeState()
        state.selectedStems = ["a", "busy"]
        state.beginMerge(in: [entry("a", title: "A"), entry("busy", title: "Busy", hour: 11, busy: true)])
        XCTAssertNil(state.draft)
    }

    func testDraftNamesWhatWasLeftOut() {
        let draft = MergeDraft(selection: [
            entry("a", title: "A"), entry("b", title: "B", hour: 11), entry("busy", title: "Busy", hour: 12, busy: true),
        ])
        XCTAssertEqual(draft.mergeable.map(\.stem), ["a", "b"])
        XCTAssertEqual(draft.skipped.map(\.entry.stem), ["busy"])
        XCTAssertEqual(draft.skipped.map(\.reason), [.busy])
    }

    // MARK: - The dialog

    func testDialogListsTheRecordingsAndShowsWhatIsLeftOut() throws {
        let draft = MergeDraft(selection: [
            entry("b", title: "Zoom part", hour: 11), entry("a", title: "Telemost part"), entry("bare", title: "Notes", hour: 12, audio: false),
        ])
        let view = MergeSessionsSheet(draft: draft, onConfirm: { _ in }, onCancel: {})

        let body = try view.inspect()
        XCTAssertNoThrow(try body.find(text: "Telemost part"))
        XCTAssertNoThrow(try body.find(text: "Zoom part"))
        XCTAssertNoThrow(try body.find(text: "Left out: Notes (no saved audio)"))
        XCTAssertNoThrow(try body.find(text: "Move the originals to the Trash once the merged protocol is ready"))
    }

    func testConfirmHandsBackTheRequestWithTheEditedFields() throws {
        let draft = MergeDraft(selection: [entry("b", title: "Zoom part", hour: 11), entry("a", title: "Telemost part")])
        draft.title = "Whole call"
        draft.deleteOriginals = true
        var received: SessionMergeRequest?
        let view = MergeSessionsSheet(draft: draft, onConfirm: { received = $0 }, onCancel: {})

        try view.inspect().find(viewWithAccessibilityIdentifier: A11yID.protocolsMergeConfirm).find(ViewType.Button.self).tap()

        let request = try XCTUnwrap(received)
        XCTAssertEqual(request.entries.map(\.stem), ["a", "b"])
        XCTAssertEqual(request.title, "Whole call")
        XCTAssertTrue(request.deleteOriginals)
    }

    func testDeleteOriginalsToggleWritesToTheDraft() throws {
        let draft = MergeDraft(selection: [entry("a", title: "A"), entry("b", title: "B", hour: 11)])
        let view = MergeSessionsSheet(draft: draft, onConfirm: { _ in }, onCancel: {})

        try view.inspect().find(viewWithAccessibilityIdentifier: A11yID.protocolsMergeDeleteOriginals).find(ViewType.Toggle.self).tap()

        XCTAssertTrue(draft.deleteOriginals)
    }

    func testTitleFieldWritesToTheDraft() throws {
        let draft = MergeDraft(selection: [entry("a", title: "A"), entry("b", title: "B", hour: 11)])
        let view = MergeSessionsSheet(draft: draft, onConfirm: { _ in }, onCancel: {})

        try view.inspect().find(viewWithAccessibilityIdentifier: A11yID.protocolsMergeTitle).find(ViewType.TextField.self).setInput("Renamed")

        XCTAssertEqual(draft.title, "Renamed")
    }

    func testCancelDoesNotConfirm() throws {
        let draft = MergeDraft(selection: [entry("a", title: "A"), entry("b", title: "B", hour: 11)])
        var confirmed = false
        var cancelled = false
        let view = MergeSessionsSheet(draft: draft, onConfirm: { _ in confirmed = true }, onCancel: { cancelled = true })

        try view.inspect().find(button: "Cancel").tap()

        XCTAssertTrue(cancelled)
        XCTAssertFalse(confirmed)
    }
}
