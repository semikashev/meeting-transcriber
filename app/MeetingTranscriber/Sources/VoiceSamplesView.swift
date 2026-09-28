import SwiftUI

/// Formatting for one row of the voice-sample list. Pure, so the wording is
/// testable without hosting the sheet.
@MainActor
enum VoiceSampleFormatting {
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    static func added(_ sample: VoiceSample) -> String {
        sample.addedAt.map { dateFormatter.string(from: $0) } ?? "Before history"
    }

    static func source(_ sample: VoiceSample) -> String {
        switch sample.origin {
        case .meeting: sample.meetingTitle ?? "Meeting"
        case .enrollment: "Enrolled: \(sample.meetingTitle ?? "recording")"
        case .migratedCentroid: "Earlier average of \(sample.centroidWeight)"
        case .migratedSample: "Earlier sample"
        }
    }

    static func track(_ sample: VoiceSample) -> String {
        switch sample.track {
        case .app: "Remote"
        case .mic: "Microphone"
        case .single: "Single"
        case nil: "—"
        }
    }

    static func speech(_ sample: VoiceSample) -> String {
        sample.duration.map { String(format: "%.0f s", $0) } ?? "—"
    }

    static func flag(_ sample: VoiceSample, issues: [VoiceHealth.Issue]) -> String {
        var parts: [String] = []
        if sample.pinned { parts.append("Reference") }
        for issue in issues where issue.sampleID == sample.id {
            switch issue {
            case let .sharedSample(_, other): parts.append("Also matches \(other)")
            case .outlierSample: parts.append("Far from average")
            case .possibleDuplicate: break
            }
        }
        return parts.joined(separator: ", ")
    }
}

/// The voice history of one known speaker: where each sample came from, and
/// the edits the history makes possible (remove a sample, pin it as a
/// reference voice, undo everything one meeting taught).
struct VoiceSamplesView: View {
    let matcher: SpeakerMatcher
    let name: String
    /// Fires after every edit so the caller can reload and refresh caches.
    let onChange: () -> Void

    @State private var speaker: StoredSpeaker?
    @State private var issues: [VoiceHealth.Issue] = []
    @State private var selection: UUID?
    @State private var undoCandidate: UndoCandidate?
    @Environment(\.dismiss)
    private var dismiss

    struct UndoCandidate: Identifiable {
        let jobID: UUID
        let title: String
        let speakers: [String]
        var id: UUID {
            jobID
        }
    }

    init(matcher: SpeakerMatcher, name: String, onChange: @escaping () -> Void = {}) {
        self.matcher = matcher
        self.name = name
        self.onChange = onChange
        let all = matcher.loadDB()
        _speaker = State(initialValue: all.first { $0.name == name })
        _issues = State(initialValue: VoiceHealth.issues(in: all)[name] ?? [])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Voice samples: \(name)").font(.title3).bold()
                Spacer()
                Text("\(samples.count) sample\(samples.count == 1 ? "" : "s")").foregroundStyle(.secondary)
            }
            Table(samples, selection: $selection) {
                TableColumn("Added") { Text(VoiceSampleFormatting.added($0)) }
                TableColumn("Source") { Text(VoiceSampleFormatting.source($0)) }
                TableColumn("Track") { Text(VoiceSampleFormatting.track($0)) }
                TableColumn("Speech") { Text(VoiceSampleFormatting.speech($0)) }
                TableColumn("Notes") { sample in
                    Text(VoiceSampleFormatting.flag(sample, issues: issues))
                        .foregroundStyle(sample.pinned ? Color.secondary : Color.orange)
                }
            }
            .frame(minHeight: 220)
            Text(
                "Samples marked “Also matches” or “Far from average” are probably another voice. "
                    + "Removing one recomputes this voice from the rest.",
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            buttons
        }
        .padding(20)
        .frame(minWidth: 640, minHeight: 380)
        .alert(item: $undoCandidate) { candidate in
            Alert(
                title: Text("Undo what “\(candidate.title)” taught?"),
                message: Text(
                    "Every sample this recording contributed is removed from: "
                        + candidate.speakers.joined(separator: ", ") + ".",
                ),
                primaryButton: .destructive(Text("Undo Meeting")) { performUndoMeeting(candidate.jobID) },
                secondaryButton: .cancel(),
            )
        }
    }

    private var samples: [VoiceSample] {
        speaker?.samples ?? []
    }

    private var selectedSample: VoiceSample? {
        samples.first { $0.id == selection }
    }

    private var buttons: some View {
        HStack {
            Button("Remove Sample", role: .destructive) {
                if let selection { performRemove([selection]) }
            }
            .disabled(selectedSample == nil)
            .accessibilityIdentifier(A11yID.voiceSampleRemoveButton)
            Button(selectedSample?.pinned == true ? "Unpin" : "Pin as Reference") {
                if let sample = selectedSample { performSetPinned(!sample.pinned, sample: sample.id) }
            }
            .disabled(selectedSample == nil)
            .accessibilityIdentifier(A11yID.voiceSamplePinButton)
            Button("Undo Meeting…") {
                if let jobID = selectedSample?.jobID { undoCandidate = undoCandidate(for: jobID) }
            }
            .disabled(selectedSample?.jobID == nil)
            .accessibilityIdentifier(A11yID.voiceUndoMeetingButton)
            .help("Remove every sample the selected sample's recording taught, from every voice.")
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
    }

    private func undoCandidate(for jobID: UUID) -> UndoCandidate {
        let all = matcher.loadDB()
        let touched = all.filter { $0.samples.contains { $0.jobID == jobID } }.map(\.name)
        let title = selectedSample?.meetingTitle ?? "this recording"
        return UndoCandidate(jobID: jobID, title: title, speakers: touched)
    }

    // MARK: - Actions (internal for tests)

    func performRemove(_ ids: Set<UUID>) {
        matcher.removeSamples(ids, from: name)
        selection = nil
        reload()
    }

    func performSetPinned(_ pinned: Bool, sample id: UUID) {
        matcher.setPinned(pinned, sample: id, of: name)
        reload()
    }

    func performUndoMeeting(_ jobID: UUID) {
        matcher.removeContributions(ofJob: jobID)
        selection = nil
        reload()
    }

    private func reload() {
        let all = matcher.loadDB()
        speaker = all.first { $0.name == name }
        issues = VoiceHealth.issues(in: all)[name] ?? []
        onChange()
    }
}
