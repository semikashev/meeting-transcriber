import SwiftUI

/// The output folder as a list: one row per recording with its protocol
/// title, when it was recorded and how much audio it keeps, and the two ways
/// to free that space. Rows a pipeline job still refers to are shown but
/// locked. The view owns no file access at all: every action is a callback,
/// so it can be tested without a folder and the app decides how files leave.
struct ProtocolsWindowView: View {
    let entries: [ProtocolEntry]
    /// Recordings a job is working on. The list is read again when they
    /// change, so finished notes show up and their row unlocks.
    let busyStems: Set<String>
    let onOpen: (ProtocolEntry) -> Void
    let onReveal: (ProtocolEntry) -> Void
    let onDelete: (ProtocolEntry, ProtocolRemovalScope) -> Void
    let onRefresh: () -> Void
    let onMerge: (SessionMergeRequest) -> Void
    /// Makes the notes of a recording that has only its transcript.
    let onGenerateNotes: (ProtocolEntry) -> Void
    @State private var merge: ProtocolsMergeState

    /// `merge` is only for tests that need to see the selection; the window
    /// keeps its own so a refresh (a new `entries` array) does not clear it.
    init(
        entries: [ProtocolEntry],
        busyStems: Set<String> = [],
        onOpen: @escaping (ProtocolEntry) -> Void,
        onReveal: @escaping (ProtocolEntry) -> Void,
        onDelete: @escaping (ProtocolEntry, ProtocolRemovalScope) -> Void,
        onRefresh: @escaping () -> Void,
        onMerge: @escaping (SessionMergeRequest) -> Void = { _ in },
        onGenerateNotes: @escaping (ProtocolEntry) -> Void = { _ in },
        merge: ProtocolsMergeState = ProtocolsMergeState(),
    ) {
        self.entries = entries
        self.busyStems = busyStems
        self.onOpen = onOpen
        self.onReveal = onReveal
        self.onDelete = onDelete
        self.onRefresh = onRefresh
        self.onMerge = onMerge
        self.onGenerateNotes = onGenerateNotes
        _merge = State(initialValue: merge)
    }

    private static let audioFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useMB, .useGB]
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            if entries.isEmpty {
                Text("No recordings yet")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(entries, selection: $merge.selectedStems) { entry in
                    row(entry)
                }
            }
            Divider()
            footer
        }
        .frame(minWidth: 640, minHeight: 360)
        .onAppear(perform: onRefresh)
        .onChange(of: busyStems) { onRefresh() }
        .sheet(isPresented: Binding(get: { merge.draft != nil }, set: { if !$0 { merge.draft = nil } })) {
            if let draft = merge.draft {
                MergeSessionsSheet(
                    draft: draft,
                    onConfirm: { request in
                        merge.draft = nil
                        merge.selectedStems = []
                        onMerge(request)
                    },
                    onCancel: { merge.draft = nil },
                )
            }
        }
    }

    private var canMerge: Bool {
        SessionMerge.canMerge(merge.selectedEntries(in: entries))
    }

    private func row(_ entry: ProtocolEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text(entry.recordedAt, format: .dateTime.day().month().year().hour().minute())
                    if entry.protocolURL == nil {
                        Text(entry.transcriptURL == nil ? "audio only" : "transcript only")
                    }
                    if entry.audioBytes > 0 {
                        Text(Self.audioFormatter.string(fromByteCount: entry.audioBytes))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if entry.isBusy {
                Text("In progress")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                actions(entry)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { onOpen(entry) }
        .contextMenu {
            Button("Merge selected recordings…") { merge.beginMerge(in: entries) }
                .disabled(!canMerge)
        }
    }

    private func actions(_ entry: ProtocolEntry) -> some View {
        HStack(spacing: 6) {
            if entry.protocolURL != nil || entry.transcriptURL != nil {
                Button("Open") { onOpen(entry) }
            }
            // Not in the App Store build, like the menu's Generate Meeting Notes
            // from Transcript: the sandbox holds no grant for the folder when
            // the job saves them.
            #if !APPSTORE
                if entry.protocolURL == nil, entry.transcriptURL != nil {
                    Button("Generate notes") { onGenerateNotes(entry) }
                        .help("Make the meeting notes from the saved transcript")
                        .accessibilityIdentifier(A11yID.protocolsGenerateNotes(entry.stem))
                }
            #endif
            Button {
                onReveal(entry)
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
                    .labelStyle(.iconOnly)
            }
            .help("Reveal in Finder")
            if entry.audioBytes > 0 {
                Button("Delete audio") { onDelete(entry, .audioOnly) }
                    .help("Move the recordings to the Trash, keep the protocol and transcript")
                    .accessibilityIdentifier(A11yID.protocolsDeleteAudio(entry.stem))
            }
            Button("Delete", role: .destructive) { onDelete(entry, .everything) }
                .help("Move everything for this recording to the Trash")
                .accessibilityIdentifier(A11yID.protocolsDelete(entry.stem))
        }
        .buttonStyle(.borderless)
    }

    private var footer: some View {
        let total = entries.reduce(Int64(0)) { $0 + $1.audioBytes }
        return HStack {
            Text("\(entries.count) recording\(entries.count == 1 ? "" : "s") · \(Self.audioFormatter.string(fromByteCount: total)) of audio")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier(A11yID.protocolsFooter)
            Spacer()
            Button("Merge…") { merge.beginMerge(in: entries) }
                .controlSize(.small)
                .disabled(!canMerge)
                .help("Join the selected recordings of one call into a single protocol (select two or more with ⌘-click)")
                .accessibilityIdentifier(A11yID.protocolsMerge)
            Button("Refresh", action: onRefresh)
                .controlSize(.small)
        }
        .padding(8)
    }
}
