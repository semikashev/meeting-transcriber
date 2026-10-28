import SwiftUI

struct MenuBarView: View {
    let status: TranscriberStatus?
    let isWatching: Bool
    let pipelineQueue: PipelineQueue
    var updateChecker: UpdateChecker?
    let onStartStop: () -> Void
    let onRecordApp: () -> Void
    let onRecordMicrophone: () -> Void
    /// Whether the user set "No Microphone (app audio only)". Only reaches the
    /// microphone item, which it disables with a reason.
    let noMic: Bool
    /// The *wide* predicate: a manual recording that is running, or a start that
    /// has registered and not yet built its loop. `state == .recording` misses
    /// that second window, and the microphone item would sit enabled through it
    /// handing back a dead click, which is what `AppPickerStartState` was built
    /// to avoid on the picker.
    let manualRecordingPendingOrActive: Bool
    let onStopManualRecording: (() -> Void)?
    let onOpenLastProtocol: () -> Void
    let onOpenProtocol: (URL) -> Void
    let onOpenProtocolsFolder: () -> Void
    /// Opens the Protocols window: the folder as a list, with delete.
    let onOpenProtocols: () -> Void
    let onOpenSettings: () -> Void
    let onNameSpeakers: (() -> Void)?
    let onProcessFiles: () -> Void
    /// The "Show Captions" item is the same switch as Settings → Transcription
    /// → "Show caption overlay", one click from the menu bar for a bar that is
    /// in the way mid-call; transcription keeps running either way.
    let captionOverlay: CaptionOverlayItem
    let onToggleCaptionOverlay: () -> Void
    let onDismissJob: (UUID) -> Void
    let onQuit: () -> Void

    private var state: TranscriberState {
        status?.state ?? .idle
    }

    private var microphoneAvailability: MicrophoneRecordingAvailability {
        .resolve(
            isRecording: manualRecordingPendingOrActive || state == .recording,
            noMic: noMic,
        )
    }

    /// Hoisted out of the `ViewBuilder`: an `Optional.map` returning an
    /// interpolated string, coalesced with `??`, inside an overloaded `Text`
    /// initializer is the exact shape that blew the 300 ms type-check budget in
    /// this file before (see the note on `body`).
    private func meetingLabel(_ meeting: MeetingInfo) -> String {
        guard let pid = meeting.pid else { return meeting.app }
        return "\(meeting.app) (PID \(pid))"
    }

    // The sections below are hoisted out of `body` into separate computed
    // properties so each is type-checked independently. Inlined as one
    // expression, the `body` getter crossed the 300 ms type-check budget that
    // the analyze build enforces (-warn-long-expression-type-checking=300 with
    // -warnings-as-errors), failing the build on slower CI hardware. The view
    // order, dividers, and conditionals are unchanged.
    var body: some View {
        statusHeader
        meetingInfo
        errorInfo

        Divider()

        watchControls
        processingQueue

        Divider()

        protocolActions
        updateSection

        Divider()

        settingsButton

        Divider()

        quitButton
    }

    // MARK: - Body sections

    private var statusHeader: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(state.label, systemImage: state.icon)
                .font(.headline)

            if let detail = status?.detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 4)
    }

    @ViewBuilder private var meetingInfo: some View {
        if let meeting = status?.meeting {
            Divider()
            VStack(alignment: .leading, spacing: 2) {
                Text(meeting.title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                // A microphone-only recording owns no process, so there is no
                // PID to show and a placeholder would only read as a real one.
                Text(meetingLabel(meeting))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
        }
    }

    @ViewBuilder private var errorInfo: some View {
        if let error = status?.error, state == .error {
            Divider()
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
                .padding(.horizontal, 4)
        }
    }

    @ViewBuilder private var watchControls: some View {
        Button {
            onStartStop()
        } label: {
            if isWatching {
                Label("Stop Watching", systemImage: "stop.fill")
            } else {
                Label("Start Watching", systemImage: "play.fill")
            }
        }
        .keyboardShortcut("s")

        if let onStopManualRecording {
            Button {
                onStopManualRecording()
            } label: {
                Label("Stop Recording", systemImage: "stop.circle.fill")
            }
            .keyboardShortcut(".")
        } else if state != .recording {
            Button {
                onRecordMicrophone()
            } label: {
                Label("Record Microphone", systemImage: "mic.circle")
            }
            .keyboardShortcut("m")
            .disabled(!microphoneAvailability.allowsStart)
            .help(microphoneAvailability.disabledReason ?? "Record the system microphone, with no app audio")

            Button {
                onRecordApp()
            } label: {
                Label("Record App...", systemImage: "record.circle")
            }
            .keyboardShortcut("r")
        }

        if captionOverlay != .unavailable {
            // A Toggle in a menu renders as a checkmark item. The binding's
            // setter ignores the value: the source of truth is the setting the
            // callback flips, and the next render reads it back.
            Toggle("Show Captions", isOn: Binding(
                get: { captionOverlay == .shown },
                set: { _ in onToggleCaptionOverlay() },
            ))
            .keyboardShortcut("l")
        }

        if let onNameSpeakers {
            Button {
                onNameSpeakers()
            } label: {
                Label("Name Speakers...", systemImage: "person.2.fill")
            }
            .keyboardShortcut("n")
        }

        Button {
            onProcessFiles()
        } label: {
            Label("Process Audio/Video Files...", systemImage: "doc.badge.plus")
        }
        .keyboardShortcut("p")
    }

    private var queueHeader: QueueHeader {
        QueueHeader.compute(jobStates: pipelineQueue.jobs.map(\.state), isProcessing: pipelineQueue.isProcessing)
    }

    @ViewBuilder private var processingQueue: some View {
        if !pipelineQueue.jobs.isEmpty {
            Divider()
            Label(queueHeader.title, systemImage: queueHeader.systemImage)

            ForEach(Array(pipelineQueue.jobs.enumerated()), id: \.element.id) { index, job in
                // A native separator, not a grouping view: each job is a run of
                // flat menu items, and without one the repeated Cancel / Retry /
                // Dismiss rows of neighbouring jobs read as one list.
                if index > 0 { Divider() }
                jobRow(job, index: index)
            }
        }
    }

    @ViewBuilder private var protocolActions: some View {
        if let protocolPath = status?.protocolPath {
            Button {
                onOpenLastProtocol()
            } label: {
                Label("Open Last Protocol", systemImage: "doc.text")
            }
            .keyboardShortcut("o")
            .disabled(protocolPath.isEmpty)
        }

        Button {
            onOpenProtocols()
        } label: {
            Label("Protocols...", systemImage: "list.bullet.rectangle")
        }
        .keyboardShortcut("d")

        Button {
            onOpenProtocolsFolder()
        } label: {
            Label("Open Protocols Folder", systemImage: "folder")
        }
    }

    @ViewBuilder private var updateSection: some View {
        if let update = updateChecker?.availableUpdate {
            Divider()
            Button {
                NSWorkspace.shared.open(update.dmgURL ?? update.htmlURL)
            } label: {
                Label(
                    "Update Available: \(update.tagName)",
                    systemImage: "arrow.down.circle.fill",
                )
            }
        }
    }

    private var settingsButton: some View {
        Button {
            onOpenSettings()
        } label: {
            Label("Settings...", systemImage: "gear")
        }
        .keyboardShortcut(",")
    }

    private var quitButton: some View {
        Button {
            onQuit()
        } label: {
            Text("Quit")
        }
        .keyboardShortcut("q")
    }

    // MARK: - Helpers

    /// Each job is a run of flat rows: a title, then a state row, then its
    /// actions. `MenuStageProgressUpdater` finds a job's state row by that order
    /// (below the queue heading, jobs in queue order), so a disabled row put
    /// between the title and the state row, or a changed order, breaks the
    /// live progress text without any compile error. Keep the order, or change
    /// the updater and its tests with it.
    @ViewBuilder
    private func jobRow(_ job: PipelineJob, index: Int) -> some View {
        Text(job.meetingTitle)
        jobStateLabel(job)

        if job.state == .done, let path = job.protocolPath ?? job.transcriptPath {
            Button("Open") { onOpenProtocol(path) }
        }
        if job.state == .speakerNamingPending {
            Button("Name Speakers") { onNameSpeakers?() }
        }
        if job.state == .waiting || job.state == .transcribing
            || job.state == .diarizing || job.state == .generatingProtocol {
            Button("Cancel") { pipelineQueue.cancelJob(id: job.id) }
        }
        retryButton(job, index: index)
        if job.state == .done || job.state == .error || job.state == .speakerNamingPending {
            Button("Dismiss") { onDismissJob(job.id) }
        }
    }

    /// Runs a failed job again from its audio, instead of the user having to
    /// find the staged recording and import it by hand.
    @ViewBuilder
    private func retryButton(_ job: PipelineJob, index: Int) -> some View {
        if pipelineQueue.canRetryJob(id: job.id) {
            Button("Retry") { pipelineQueue.retryJob(id: job.id) }
                .accessibilityIdentifier(A11yID.jobRetryButton(index))
        }
    }

    @ViewBuilder
    private func jobStateLabel(_ job: PipelineJob) -> some View {
        if StageKind(jobState: job.state) != nil {
            MenuStageProgressLabel(text: MenuStageProgressUpdater.progressText(job: job, queue: pipelineQueue))
        } else if job.state == .error, let msg = job.error {
            Text(msg)
        } else if job.state == .done, !job.warnings.isEmpty {
            Text(job.warnings.joined(separator: "; "))
        } else {
            Text(job.state.label)
        }
    }
}

/// What the menu's "Show Captions" item has to say about the caption bar.
enum CaptionOverlayItem: Equatable {
    /// Live transcription is off, so there is no bar and no item: shown, it
    /// would only raise the question of what it does.
    case unavailable
    case shown
    case hidden

    init(liveTranscriptionEnabled: Bool, overlayEnabled: Bool) {
        guard liveTranscriptionEnabled else {
            self = .unavailable
            return
        }
        self = overlayEnabled ? .shown : .hidden
    }
}

/// Keep SwiftUI's text stable for the active row's lifetime. The native updater
/// owns subsequent stage and timer changes so Cancel keeps its hover highlight.
private struct MenuStageProgressLabel: View {
    @State private var text: String

    init(text: String) {
        _text = State(initialValue: text)
    }

    var body: some View {
        Text(text)
    }
}
