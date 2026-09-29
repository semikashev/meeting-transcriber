@preconcurrency import AVFoundation
import Foundation

/// What the user confirmed in the merge dialog.
struct SessionMergeRequest: Equatable {
    /// The recordings to join, in any order: `SessionMerge` sorts them.
    let entries: [ProtocolEntry]
    let title: String
    /// Move the originals to the Trash once the merged protocol exists.
    let deleteOriginals: Bool
}

/// Why a selected row cannot take part in a merge.
enum MergeSkipReason: Equatable {
    /// A pipeline job still reads its files.
    case busy
    /// Nothing under `recordings/` to join: the audio was deleted.
    case noAudio
}

enum SessionMergeError: LocalizedError, Equatable {
    case tooFewSessions
    case notMergeable(stem: String, reason: MergeSkipReason)
    case unreadableAudio(stem: String)
    /// One of the recordings is already being merged.
    case alreadyMerging

    var errorDescription: String? {
        switch self {
        case .tooFewSessions:
            "Pick at least two recordings to merge."

        case let .notMergeable(stem, .busy):
            "\(stem) is still being processed."

        case let .notMergeable(stem, .noAudio):
            "\(stem) has no saved audio."

        case let .unreadableAudio(stem):
            "The audio of \(stem) could not be read."

        case .alreadyMerging:
            "These recordings are already being merged."
        }
    }
}

/// Joins recordings that are really one call: a meeting that moved from one
/// app to another is captured as two sessions, each with its own protocol.
///
/// The join happens on the audio, not on the transcripts, so the merged job
/// runs the ordinary transcribe → diarize → protocol pipeline and speakers are
/// matched once across the whole call. Joining the finished transcripts would
/// leave "Speaker 1" of the first part and "Speaker 1" of the second
/// unrelated. The cost is one more transcription run.
enum SessionMerge {
    /// Silence between two sessions, so the last word of one and the first of
    /// the next never run together and diarization sees a clean boundary. The
    /// real gap between recordings is unknown and can be hours, so it is not
    /// reproduced.
    static let gapSeconds = 2

    enum Layout: Equatable {
        /// Every session kept both an app and a mic track: the merge writes
        /// them as separate tracks plus a mix, exactly as a live recording.
        case dualTrack
        /// At least one session has a single audio file: everything is joined
        /// as one mono mix.
        case mono
    }

    /// The audio files of one recording, sorted out by role.
    struct Source: Equatable {
        let entry: ProtocolEntry
        let mix: URL?
        let app: URL?
        let mic: URL?
        /// The 16 kHz mix kept for re-diarization; a last resort for mono.
        let mix16k: URL?

        var hasBothTracks: Bool {
            app != nil && mic != nil
        }

        var hasAudio: Bool {
            mix != nil || app != nil || mic != nil || mix16k != nil
        }
    }

    struct Plan: Equatable {
        let sources: [Source]
        let layout: Layout
    }

    /// The audio files a merge would read, by suffix.
    static func source(of entry: ProtocolEntry) -> Source {
        func url(_ suffix: String) -> URL? {
            entry.audioURLs.first { $0.lastPathComponent.hasSuffix(suffix) }
        }
        return Source(
            entry: entry,
            mix: url(RecordingFileSuffix.mix), app: url(RecordingFileSuffix.app),
            mic: url(RecordingFileSuffix.mic), mix16k: url("_16k.wav"),
        )
    }

    /// Chronological, ties broken by stem so the order never depends on the
    /// order the rows were clicked in.
    static func chronological(_ entries: [ProtocolEntry]) -> [ProtocolEntry] {
        entries.sorted { ($0.recordedAt, $0.stem) < ($1.recordedAt, $1.stem) }
    }

    static func skipReason(for entry: ProtocolEntry) -> MergeSkipReason? {
        if entry.isBusy { return .busy }
        return source(of: entry).hasAudio ? nil : .noAudio
    }

    /// Splits a selection into the rows a merge can use, oldest first, and the
    /// rest with the reason each was left out.
    static func partition(_ entries: [ProtocolEntry])
        -> (mergeable: [ProtocolEntry], skipped: [(entry: ProtocolEntry, reason: MergeSkipReason)]) {
        var mergeable: [ProtocolEntry] = []
        var skipped: [(entry: ProtocolEntry, reason: MergeSkipReason)] = []
        for entry in chronological(entries) {
            if let reason = skipReason(for: entry) {
                skipped.append((entry, reason))
            } else {
                mergeable.append(entry)
            }
        }
        return (mergeable, skipped)
    }

    /// The merge button's rule: two usable recordings, not counting the ones a
    /// merge would leave out.
    static func canMerge(_ selection: [ProtocolEntry]) -> Bool {
        partition(selection).mergeable.count >= 2
    }

    /// Default title of the merged recording: the first session's.
    static func defaultTitle(for entries: [ProtocolEntry]) -> String {
        chronological(entries).first?.title ?? ""
    }

    /// Strict: every entry must be usable. The caller filters with `partition`
    /// first, so a row that went busy while the dialog was open fails the
    /// merge instead of being joined half-written.
    static func plan(for entries: [ProtocolEntry]) throws -> Plan {
        guard entries.count >= 2 else { throw SessionMergeError.tooFewSessions }
        let ordered = chronological(entries)
        for entry in ordered {
            if let reason = skipReason(for: entry) {
                throw SessionMergeError.notMergeable(stem: entry.stem, reason: reason)
            }
        }
        let sources = ordered.map(source(of:))
        return Plan(sources: sources, layout: sources.allSatisfy(\.hasBothTracks) ? .dualTrack : .mono)
    }

    // MARK: - Audio

    struct RenderedAudio: Equatable {
        let mix: URL
        let app: URL?
        let mic: URL?

        var all: [URL] {
            [mix, app, mic].compactMap(\.self)
        }
    }

    /// Writes the merged audio as `<basename>_mix.wav` (plus `_app.wav` and
    /// `_mic.wav` for a dual-track merge) in `directory`. Nothing is left
    /// behind when it throws.
    ///
    /// The mix is the file orphan recovery and the paired-import resolver key
    /// on, so it is written under a temporary name and renamed last: a crash
    /// mid-merge leaves no `_mix.wav` for either to pick up half-written.
    static func render(_ plan: Plan, into directory: URL, basename: String) throws -> RenderedAudio {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let mixURL = directory.appendingPathComponent(basename + RecordingFileSuffix.mix)
        let mixTemp = directory.appendingPathComponent(basename + "_mixpartial.wav")
        let appURL = directory.appendingPathComponent(basename + RecordingFileSuffix.app)
        let micURL = directory.appendingPathComponent(basename + RecordingFileSuffix.mic)
        do {
            switch plan.layout {
            case .dualTrack:
                try renderTracks(plan, app: appURL, mic: micURL)
                try AudioMixer.mix(appAudioPath: appURL, micAudioPath: micURL, outputPath: mixTemp, micDelay: 0)
                try fm.moveItem(at: mixTemp, to: mixURL)
                return RenderedAudio(mix: mixURL, app: appURL, mic: micURL)

            case .mono:
                try renderMono(plan, to: mixTemp)
                try fm.moveItem(at: mixTemp, to: mixURL)
                return RenderedAudio(mix: mixURL, app: nil, mic: nil)
            }
        } catch {
            for url in [mixURL, mixTemp, appURL, micURL] {
                try? fm.removeItem(at: url)
            }
            throw error
        }
    }

    /// Both tracks of every session, each padded to the session's length so
    /// the two stay on one clock across the join.
    private static func renderTracks(_ plan: Plan, app: URL, mic: URL) throws {
        let appWriter = try MonoWAVWriter(url: app)
        let micWriter = try MonoWAVWriter(url: mic)
        for (index, source) in plan.sources.enumerated() {
            guard let appURL = source.app, let micURL = source.mic else {
                throw SessionMergeError.unreadableAudio(stem: source.entry.stem)
            }
            let appSamples = try load(appURL, stem: source.entry.stem)
            let micSamples = try load(micURL, stem: source.entry.stem)
            let length = max(appSamples.count, micSamples.count)
            try appWriter.append(appSamples, paddedTo: length)
            try micWriter.append(micSamples, paddedTo: length)
            if index < plan.sources.count - 1 {
                try appWriter.appendSilence(frames: gapFrames)
                try micWriter.appendSilence(frames: gapFrames)
            }
        }
        try appWriter.finish()
        try micWriter.finish()
    }

    private static func renderMono(_ plan: Plan, to url: URL) throws {
        let writer = try MonoWAVWriter(url: url)
        for (index, source) in plan.sources.enumerated() {
            try writer.append(monoSamples(of: source), paddedTo: nil)
            if index < plan.sources.count - 1 {
                try writer.appendSilence(frames: gapFrames)
            }
        }
        try writer.finish()
    }

    /// One session as a single track: its mix, else its tracks mixed here,
    /// else whatever single file it kept.
    private static func monoSamples(of source: Source) throws -> [Float] {
        let stem = source.entry.stem
        if let mix = source.mix { return try load(mix, stem: stem) }
        if let app = source.app, let mic = source.mic {
            return try AudioMixer.mixTracks(load(app, stem: stem), load(mic, stem: stem))
        }
        if let single = source.app ?? source.mic ?? source.mix16k { return try load(single, stem: stem) }
        throw SessionMergeError.unreadableAudio(stem: stem)
    }

    private static var gapFrames: Int {
        gapSeconds * AudioConstants.targetSampleRate
    }

    /// Mono samples at the pipeline rate. Recordings are written at 16 kHz;
    /// the resample covers a file that was not.
    private static func load(_ url: URL, stem: String) throws -> [Float] {
        do {
            let file = try AVAudioFile(forReading: url)
            let rate = Int(file.processingFormat.sampleRate)
            let samples = try AudioMixer.loadAudioFileAsFloat32(url: url)
            return rate == AudioConstants.targetSampleRate
                ? samples
                : AudioMixer.resample(samples, from: rate, to: AudioConstants.targetSampleRate)
        } catch {
            throw SessionMergeError.unreadableAudio(stem: stem)
        }
    }

    // MARK: - Job

    /// The pipeline job for a merged recording. `participants` and `emails`
    /// come from the calendar (the originals' own are not kept once their jobs
    /// finish), so the caller passes them in.
    static func makeJob(
        request: SessionMergeRequest, plan: Plan, audio: RenderedAudio,
        participants: [String], emails: [String],
    ) -> PipelineJob {
        PipelineJob(
            meetingTitle: request.title,
            appName: "Merged recording",
            mixPath: audio.mix, appPath: audio.app, micPath: audio.mic,
            micDelay: 0,
            participants: participants,
            participantEmails: emails.isEmpty ? nil : emails,
            meetingStartTime: plan.sources.first?.entry.recordedAt,
        )
    }

    /// Union in first-seen order, ignoring case and blanks.
    static func union(_ lists: [[String]]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for name in lists.joined() {
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted { result.append(trimmed) }
        }
        return result
    }

    /// Unique per merge, and shaped like a live recording's basename (start
    /// stamp first) so it sorts among them in the staging folder.
    static func basename(firstStart: Date, id: UUID = UUID()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return "\(formatter.string(from: firstStart))_merged_\(id.uuidString.prefix(6).lowercased())"
    }
}

/// Appends mono 16 kHz samples to a 16-bit WAV in chunks, so a merge holds one
/// session in memory rather than the whole call.
private final class MonoWAVWriter {
    private var file: AVAudioFile?
    private let format: AVAudioFormat
    private let url: URL
    private static let chunkFrames = 65536

    init(url: URL) throws {
        let rate = AudioConstants.targetSampleRate
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: Double(rate), channels: 1, interleaved: false,
        ) else { throw AudioMixerError.formatCreationFailed }
        self.format = format
        self.url = url
        file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
        ])
    }

    /// `paddedTo`: total frames the block must occupy, zeros after the samples.
    func append(_ samples: [Float], paddedTo total: Int?) throws {
        var offset = 0
        while offset < samples.count {
            let count = min(Self.chunkFrames, samples.count - offset)
            let buffer = try makeBuffer(frames: count)
            samples.withUnsafeBufferPointer { src in
                // swiftlint:disable:next force_unwrapping
                buffer.floatChannelData![0].update(from: src.baseAddress! + offset, count: count)
            }
            try file?.write(from: buffer)
            offset += count
        }
        if let total, total > samples.count { try appendSilence(frames: total - samples.count) }
    }

    func appendSilence(frames: Int) throws {
        var remaining = frames
        while remaining > 0 {
            let count = min(Self.chunkFrames, remaining)
            let buffer = try makeBuffer(frames: count)
            buffer.floatChannelData![0].initialize(repeating: 0, count: count) // swiftlint:disable:this force_unwrapping
            try file?.write(from: buffer)
            remaining -= count
        }
    }

    /// Closes the file and restricts it to the owner, like every audio file
    /// the app writes.
    func finish() throws {
        file = nil
        try FileManager.default.restrictToOwner(url)
    }

    private func makeBuffer(frames: Int) throws -> AVAudioPCMBuffer {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else {
            throw AudioMixerError.bufferCreationFailed
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        return buffer
    }
}
