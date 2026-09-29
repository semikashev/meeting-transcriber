@testable import MeetingTranscriber
import XCTest

/// Dumps the per-speaker diarization output of real local recordings to a
/// JSONL corpus, so speaker-database policies can be replayed offline against
/// the same embeddings production computes.
///
/// Each line is one diarized speaker of one track: recording stem, track,
/// label, speaking time, segments and the embedding. The app and microphone
/// tracks are diarized separately, as production does; the raw `_mic.wav` is
/// read, so echo cancellation (which production applies to the 16 kHz copy)
/// is not reflected here.
///
/// Skipped unless `MT_EMBEDDING_CORPUS_OUT` names the output file. Recordings
/// are read from `MT_RECORDINGS_DIR` (default
/// `~/Documents/MeetingTranscriber/recordings`). Stems already present in the
/// output are skipped, so an interrupted run resumes where it stopped.
///
///   MT_EMBEDDING_CORPUS_OUT=/tmp/corpus.jsonl \
///     swift test --filter SpeakerEmbeddingCorpusExtract
final class SpeakerEmbeddingCorpusExtract: XCTestCase {
    private struct Line: Codable {
        let stem: String
        let track: String
        let label: String
        let speakingTime: TimeInterval
        let segments: [[TimeInterval]]
        let embedding: [Float]
    }

    func testExtractCorpus() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let outPath = env["MT_EMBEDDING_CORPUS_OUT"] else {
            throw XCTSkip("set MT_EMBEDDING_CORPUS_OUT to extract a corpus")
        }
        let recordingsDir = env["MT_RECORDINGS_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Documents/MeetingTranscriber/recordings")
        let out = URL(fileURLWithPath: outPath)

        var done: Set<String> = []
        if let existing = try? String(contentsOf: out, encoding: .utf8) {
            for row in existing.split(separator: "\n") {
                if let line = try? JSONDecoder().decode(Line.self, from: Data(row.utf8)) {
                    done.insert(line.stem)
                }
            }
        } else {
            FileManager.default.createFile(atPath: out.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: out)
        defer { try? handle.close() }
        try handle.seekToEnd()

        let wavs = try FileManager.default
            .contentsOfDirectory(at: recordingsDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "wav" }
        let groups = PairedRecordingResolver.resolve(urls: wavs).paired
            .filter { $0.app != nil && $0.mic != nil && !done.contains($0.stem) }
            .sorted { $0.stem < $1.stem }
        print("corpus: \(groups.count) recording(s) to diarize, \(done.count) already done")

        let diarizer = FluidDiarizer(mode: .offline)
        for group in groups {
            guard let app = group.app, let mic = group.mic else { continue }
            let started = Date()
            var lines: [Line] = []
            for (track, url) in [("app", app), ("mic", mic)] {
                do {
                    let result = try await diarizer.run(audioPath: url, numSpeakers: nil, meetingTitle: "")
                    for (label, embedding) in result.embeddings ?? [:] {
                        let segs = result.segments.filter { $0.speaker == label }.map { [$0.start, $0.end] }
                        lines.append(Line(
                            stem: group.stem, track: track, label: label,
                            speakingTime: result.speakingTimes[label] ?? 0,
                            segments: segs, embedding: embedding,
                        ))
                    }
                } catch {
                    print("corpus: \(group.stem) \(track) failed: \(error.localizedDescription)")
                }
            }
            let encoder = JSONEncoder()
            for line in lines {
                try handle.write(contentsOf: encoder.encode(line) + Data("\n".utf8))
            }
            let secs = Int(Date().timeIntervalSince(started))
            print("corpus: \(group.stem) → \(lines.count) speaker(s) in \(secs)s")
        }
    }
}
