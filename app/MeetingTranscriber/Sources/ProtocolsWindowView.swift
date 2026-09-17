import SwiftUI

/// The output folder as a list: one row per recording with its protocol
/// title, when it was recorded and how much audio it keeps, and the two ways
/// to free that space. Rows a pipeline job still refers to are shown but
/// locked. The view owns no file access at all: every action is a callback,
/// so it can be tested without a folder and the app decides how files leave.
struct ProtocolsWindowView: View {
    let entries: [ProtocolEntry]
    let onOpen: (ProtocolEntry) -> Void
    let onReveal: (ProtocolEntry) -> Void
    let onDelete: (ProtocolEntry, ProtocolRemovalScope) -> Void
    let onRefresh: () -> Void

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
                List(entries) { entry in
                    row(entry)
                }
            }
            Divider()
            footer
        }
        .frame(minWidth: 640, minHeight: 360)
        .onAppear(perform: onRefresh)
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
    }

    private func actions(_ entry: ProtocolEntry) -> some View {
        HStack(spacing: 6) {
            if entry.protocolURL != nil || entry.transcriptURL != nil {
                Button("Open") { onOpen(entry) }
            }
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
            Button("Refresh", action: onRefresh)
                .controlSize(.small)
        }
        .padding(8)
    }
}
