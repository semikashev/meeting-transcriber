@testable import MeetingTranscriber
import XCTest

/// Two local tools over a real speaker database, both skipped unless their
/// environment variables are set. They exist for hand-run maintenance and
/// measurement; neither touches the live database unless pointed at it.
///
/// Edit plan: applies a JSON list of operations through the production
/// mutators, so derived centroids and recent samples are recomputed exactly
/// as the app would:
///   MT_DB_PATH=/path/speakers.json MT_DB_EDIT_PLAN=/path/plan.json \
///     swift test --filter SpeakerDatabaseLocalTools/testApplyEditPlan
/// `plan.json` is `[{"op":"removeSamples","name":…,"ids":[…]},
/// {"op":"delete","name":…}, {"op":"rename","from":…,"to":…}]`.
///
/// Fixed-database evaluation: matches each meeting of a labelled corpus
/// (the `SpeakerDatabaseReplay` format) against a copy of a given database
/// from which that meeting's own contributions were removed first, so a
/// meeting is never scored against what it taught. Nothing is learned
/// between meetings; this measures the database, not the write policy:
///   MT_EVAL_DB=/path/speakers.json MT_REPLAY_CORPUS=/path/replay.jsonl \
///     swift test --filter SpeakerDatabaseLocalTools/testFixedDatabaseEval
final class SpeakerDatabaseLocalTools: XCTestCase {
    private struct Operation: Decodable {
        let op: String
        let name: String?
        // swiftlint:disable:next discouraged_optional_collection
        let ids: [UUID]?
        let from: String?
        let to: String?
    }

    private struct Row: Decodable {
        let stem: String
        let label: String
        let duration: TimeInterval
        let embedding: [Float]
        let truth: String?
    }

    func testApplyEditPlan() throws {
        let env = ProcessInfo.processInfo.environment
        guard let dbPath = env["MT_DB_PATH"], let planPath = env["MT_DB_EDIT_PLAN"] else {
            throw XCTSkip("set MT_DB_PATH and MT_DB_EDIT_PLAN to apply an edit plan")
        }
        let plan = try JSONDecoder().decode([Operation].self, from: Data(contentsOf: URL(fileURLWithPath: planPath)))
        let matcher = SpeakerMatcher(dbPath: URL(fileURLWithPath: dbPath))
        for operation in plan {
            switch operation.op {
            case "removeSamples":
                let name = try XCTUnwrap(operation.name)
                let removed = matcher.removeSamples(Set(operation.ids ?? []), from: name)
                print("edit: removeSamples \(name): \(removed) of \(operation.ids?.count ?? 0)")

            case "delete":
                let name = try XCTUnwrap(operation.name)
                print("edit: delete \(name): \(matcher.deleteSpeaker(name: name))")

            case "rename":
                let from = try XCTUnwrap(operation.from), to = try XCTUnwrap(operation.to)
                print("edit: rename \(from) -> \(to): \(matcher.renameSpeaker(from: from, to: to))")

            default:
                XCTFail("unknown op \(operation.op)")
            }
        }
    }

    func testFixedDatabaseEval() throws {
        let env = ProcessInfo.processInfo.environment
        guard let dbSource = env["MT_EVAL_DB"], let corpusPath = env["MT_REPLAY_CORPUS"] else {
            throw XCTSkip("set MT_EVAL_DB and MT_REPLAY_CORPUS to evaluate a fixed database")
        }
        let rows = try String(contentsOfFile: corpusPath, encoding: .utf8)
            .split(separator: "\n")
            .map { try JSONDecoder().decode(Row.self, from: Data($0.utf8)) }
        let meetings = Dictionary(grouping: rows, by: \.stem).sorted { $0.key < $1.key }
        let source = URL(fileURLWithPath: dbSource)
        let dir = try makeTempDirectory(prefix: "SpeakerDatabaseFixedEval")
        var correct = 0, wrong = 0, known = 0, missed = 0
        var missedByName: [String: Int] = [:], wrongPairs: [String: Int] = [:]

        for (stem, labels) in meetings {
            let dbPath = dir.appendingPathComponent("speakers.json")
            try? FileManager.default.removeItem(at: dbPath)
            try FileManager.default.copyItem(at: source, to: dbPath)
            let matcher = SpeakerMatcher(dbPath: dbPath)
            // Stems end in the first 8 hex digits of the job ID.
            let jobPrefix = String(stem.suffix(8)).lowercased()
            let jobs = Set(matcher.loadDB().flatMap(\.samples).compactMap(\.jobID)
                .filter { $0.uuidString.lowercased().hasPrefix(jobPrefix) })
            for job in jobs {
                matcher.removeContributions(ofJob: job)
            }
            let learned = Set(matcher.loadDB().filter { $0.centroid != nil || !$0.anchorEmbeddings.isEmpty }.map(\.name))
            let embeddings = Dictionary(uniqueKeysWithValues: labels.map { ($0.label, $0.embedding) })
            let times = Dictionary(uniqueKeysWithValues: labels.map { ($0.label, $0.duration) })
            let assigned = matcher.match(embeddings: embeddings, speakingTimes: times)
            for row in labels {
                guard let truth = row.truth else { continue }
                let name = assigned[row.label].flatMap { $0 == row.label ? nil : $0 }
                let isKnown = learned.contains(truth)
                known += isKnown ? 1 : 0
                if name == truth {
                    correct += 1
                } else if let name {
                    wrong += 1
                    wrongPairs["\(truth) as \(name)", default: 0] += 1
                } else if isKnown {
                    missed += 1
                    missedByName[truth, default: 0] += 1
                }
            }
        }

        let precision = Double(correct) / Double(max(correct + wrong, 1))
        let recall = Double(correct) / Double(max(known, 1))
        print(String(
            format: "fixed-db: %d meetings, precision %.0f%% (%d/%d), recall %.0f%% (%d/%d), wrong %d, missed %d",
            meetings.count, precision * 100, correct, correct + wrong, recall * 100, correct, known, wrong, missed,
        ))
        let top = missedByName.sorted { $0.value > $1.value }.prefix(8).map { "\($0.key)=\($0.value)" }
        print("fixed-db missed: \(top.joined(separator: ", "))")
        let pairs = wrongPairs.sorted { $0.value > $1.value }.prefix(8).map { "\($0.key)=\($0.value)" }
        print("fixed-db wrong: \(pairs.joined(separator: ", "))")
    }
}
