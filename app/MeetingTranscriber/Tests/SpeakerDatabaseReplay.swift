@testable import MeetingTranscriber
import XCTest

/// Replays labelled meetings through the production matcher and write path:
/// each meeting is matched against the database learned so far, scored against
/// the names the user confirmed, and then taught to the database the way a
/// confirmed naming dialog would (`CrossTrackEmbeddingFilter`, then
/// `SpeakerMatcher.updateDB`). The echo quarantine is not replayed, since the
/// corpus carries no echo verdicts.
///
/// The corpus is a JSONL file of diarized labels, one per line:
/// `{"stem", "label" (R_/M_ prefixed), "duration", "embedding", "truth"}` where
/// `truth` is the confirmed name or null. Embeddings come from
/// `SpeakerEmbeddingCorpusExtract`; the names are the user's and never belong
/// in the repository, so the file stays local.
///
/// Skipped unless `MT_REPLAY_CORPUS` names the file:
///   MT_REPLAY_CORPUS=/tmp/replay.jsonl swift test --filter SpeakerDatabaseReplay
final class SpeakerDatabaseReplay: XCTestCase {
    private struct Row: Decodable {
        let stem: String
        let label: String
        let duration: TimeInterval
        let embedding: [Float]
        let truth: String?
    }

    func testReplayCorpus() throws {
        guard let path = ProcessInfo.processInfo.environment["MT_REPLAY_CORPUS"] else {
            throw XCTSkip("set MT_REPLAY_CORPUS to replay a labelled corpus")
        }
        let rows = try String(contentsOfFile: path, encoding: .utf8)
            .split(separator: "\n")
            .map { try JSONDecoder().decode(Row.self, from: Data($0.utf8)) }
        let meetings = Dictionary(grouping: rows, by: \.stem).sorted { $0.key < $1.key }

        let dbPath = try makeTempDirectory(prefix: "SpeakerDatabaseReplay").appendingPathComponent("speakers.json")
        let matcher = SpeakerMatcher(dbPath: dbPath)
        var correct = 0, wrong = 0, known = 0, missed = 0

        for (stem, labels) in meetings {
            let embeddings = Dictionary(uniqueKeysWithValues: labels.map { ($0.label, $0.embedding) })
            let times = Dictionary(uniqueKeysWithValues: labels.map { ($0.label, $0.duration) })
            let assigned = matcher.match(embeddings: embeddings, speakingTimes: times)
            let learned = Set(matcher.loadDB().filter { $0.centroid != nil || !$0.anchorEmbeddings.isEmpty }.map(\.name))
            for row in labels {
                guard let truth = row.truth else { continue }
                let name = assigned[row.label].flatMap { $0 == row.label ? nil : $0 }
                let isKnown = learned.contains(truth)
                known += isKnown ? 1 : 0
                if name == truth {
                    correct += 1
                } else if let name, name != truth {
                    wrong += 1
                } else if isKnown {
                    missed += 1
                }
            }
            let mapping = Dictionary(uniqueKeysWithValues: labels.compactMap { row in row.truth.map { (row.label, $0) } })
            let admissible = CrossTrackEmbeddingFilter.admissible(embeddings, mapping: mapping, speakingTimes: times)
            matcher.updateDB(
                mapping: mapping, embeddings: admissible, speakingTimes: times,
                provenance: SampleProvenance(meetingTitle: stem),
            )
        }

        let precision = Double(correct) / Double(max(correct + wrong, 1))
        let recall = Double(correct) / Double(max(known, 1))
        print(String(
            format: "replay: %d meetings, precision %.0f%% (%d/%d), recall %.0f%% (%d/%d), wrong %d, missed %d",
            meetings.count, precision * 100, correct, correct + wrong, recall * 100, correct, known, wrong, missed,
        ))
    }
}
