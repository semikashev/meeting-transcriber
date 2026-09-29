import Observation
import SwiftUI

/// What the merge dialog edits. One reference object, so a test (and the
/// window) reads what the fields wrote.
@Observable
@MainActor
final class MergeDraft {
    var title: String
    var deleteOriginals = false
    /// Oldest first, as they will be joined.
    let mergeable: [ProtocolEntry]
    let skipped: [(entry: ProtocolEntry, reason: MergeSkipReason)]

    init(selection: [ProtocolEntry]) {
        let parts = SessionMerge.partition(selection)
        mergeable = parts.mergeable
        skipped = parts.skipped
        title = SessionMerge.defaultTitle(for: parts.mergeable)
    }

    var request: SessionMergeRequest {
        SessionMergeRequest(entries: mergeable, title: title, deleteOriginals: deleteOriginals)
    }
}

/// The Protocols window's selection and the merge dialog it can open.
@Observable
@MainActor
final class ProtocolsMergeState {
    var selectedStems: Set<String> = []
    var draft: MergeDraft?

    func selectedEntries(in entries: [ProtocolEntry]) -> [ProtocolEntry] {
        entries.filter { selectedStems.contains($0.stem) }
    }

    /// Opens the dialog when the selection has two usable recordings.
    func beginMerge(in entries: [ProtocolEntry]) {
        let selected = selectedEntries(in: entries)
        guard SessionMerge.canMerge(selected) else { return }
        draft = MergeDraft(selection: selected)
    }
}

/// Confirmation for a merge: the order the recordings will be joined in, the
/// title of the result, and whether the originals go to the Trash afterwards.
struct MergeSessionsSheet: View {
    @Bindable var draft: MergeDraft
    let onConfirm: (SessionMergeRequest) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Merge recordings")
                .font(.headline)
            Text("The recordings are joined in this order and processed again as one call.")
                .font(.caption)
                .foregroundStyle(.secondary)
            orderedList
            skippedList
            TextField("Title", text: $draft.title)
                .accessibilityIdentifier(A11yID.protocolsMergeTitle)
            Toggle("Move the originals to the Trash once the merged protocol is ready", isOn: $draft.deleteOriginals)
                .accessibilityIdentifier(A11yID.protocolsMergeDeleteOriginals)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Merge") { onConfirm(draft.request) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.mergeable.count < 2)
                    .accessibilityIdentifier(A11yID.protocolsMergeConfirm)
            }
        }
        .padding(16)
        .frame(width: 460)
    }

    private var orderedList: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(draft.mergeable.enumerated()), id: \.element.id) { index, entry in
                HStack(spacing: 8) {
                    Text("\(index + 1).")
                        .foregroundStyle(.secondary)
                    Text(entry.title).lineLimit(1)
                    Spacer()
                    Text(entry.recordedAt, format: .dateTime.day().month().hour().minute())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityIdentifier(A11yID.protocolsMergeList)
    }

    @ViewBuilder private var skippedList: some View {
        if !draft.skipped.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(draft.skipped, id: \.entry.id) { item in
                    Text("Left out: \(item.entry.title) (\(Self.reasonText(item.reason)))")
                }
            }
            .font(.caption)
            .foregroundStyle(.orange)
        }
    }

    static func reasonText(_ reason: MergeSkipReason) -> String {
        switch reason {
        case .busy: "still in progress"
        case .noAudio: "no saved audio"
        }
    }
}
