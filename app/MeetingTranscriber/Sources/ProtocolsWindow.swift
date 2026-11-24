import SwiftUI

/// Content of the Protocols window: the output folder as a list, with delete
/// and merge. Owns the rows; they are rescanned whenever the window opens or
/// acts, and when a job starts or finishes.
struct ProtocolsWindow: View {
    let appState: AppState
    @State private var protocolEntries: [ProtocolEntry] = []

    var body: some View {
        ProtocolsWindowView(
            entries: protocolEntries,
            busyStems: busyStems,
            onOpen: { entry in
                if let url = entry.protocolURL ?? entry.transcriptURL { NSWorkspace.shared.open(url) }
            },
            onReveal: { entry in
                let url = entry.protocolURL ?? entry.transcriptURL ?? entry.audioURLs.first
                if let url { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            },
            onDelete: { entry, scope in
                removeProtocolEntry(entry, scope: scope)
                rescanProtocols()
            },
            onRefresh: rescanProtocols,
            onMerge: mergeProtocolEntries,
            onGenerateNotes: generateNotes,
        )
    }

    private var busyStems: Set<String> {
        ProtocolLibrary.busyStems(of: appState.pipeline.queue.jobs, merging: appState.pipeline.mergingStems)
    }

    private func rescanProtocols() {
        let dir = appState.settings.effectiveOutputDir
        let accessing = dir.startAccessingSecurityScopedResource()
        defer { if accessing { dir.stopAccessingSecurityScopedResource() } }
        protocolEntries = ProtocolLibrary.scan(outputDir: dir, busyStems: busyStems)
    }

    private func mergeProtocolEntries(_ request: SessionMergeRequest) {
        let pipeline = appState.pipeline
        let settings = appState.settings
        Task {
            do {
                try await pipeline.mergeSessions(
                    request,
                    outputDir: settings.effectiveOutputDir,
                    calendar: settings.calendarTitlesEnabled
                        ? EventKitMeetingLookup(settings: settings)
                        : NoCalendarLookup(),
                )
            } catch {
                appState.notifier.notify(title: "Could not merge recordings", body: error.localizedDescription)
            }
            rescanProtocols()
        }
    }

    private func generateNotes(for entry: ProtocolEntry) {
        guard let transcript = entry.transcriptURL else { return }
        appState.pipeline.makeNotes(forTranscript: transcript)
        rescanProtocols()
    }

    private func removeProtocolEntry(_ entry: ProtocolEntry, scope: ProtocolRemovalScope) {
        let dir = appState.settings.effectiveOutputDir
        let accessing = dir.startAccessingSecurityScopedResource()
        defer { if accessing { dir.stopAccessingSecurityScopedResource() } }
        do {
            try ProtocolLibrary.remove(entry, scope: scope, using: TrashFileRemover())
        } catch {
            appState.notifier.notify(title: "Could not delete recording", body: error.localizedDescription)
        }
    }
}
