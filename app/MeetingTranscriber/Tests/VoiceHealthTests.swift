@testable import MeetingTranscriber
import XCTest

/// A clean-up removes data, so these tests pin what it leaves alone as
/// carefully as what it flags: a similar but distinct voice, a duplicate
/// profile (the user merges it), and a pinned reference sample.
final class VoiceHealthTests: XCTestCase {
    private func speaker(
        _ name: String, samples: [[Float]],
        centroid: [Float]? = nil, // swiftlint:disable:this discouraged_optional_collection
        weight: Int = 1, pinned: Set<Int> = [],
    ) -> StoredSpeaker {
        var history: [VoiceSample] = []
        if let centroid {
            history.append(VoiceSample(embedding: centroid, origin: .migratedCentroid, centroidWeight: weight))
        }
        history += samples.enumerated().map { index, embedding in
            VoiceSample(
                embedding: embedding, origin: .meeting, centroidWeight: centroid == nil ? 1 : 0,
                duration: 30, pinned: pinned.contains(index),
            )
        }
        return StoredSpeaker(name: name, samples: history)
    }

    func testASampleOfAnotherPersonIsFlaggedAndPlannedForRemoval() throws {
        let a = speaker("A", samples: [[1, 0, 0]], centroid: [1, 0, 0])
        let b = speaker("B", samples: [[0, 1, 0], [0.99, 0.05, 0]], centroid: [0, 1, 0], weight: 6)
        let stray = try XCTUnwrap(b.samples.last?.id)

        let issues = VoiceHealth.issues(in: [a, b])
        XCTAssertEqual(issues["B"], [.sharedSample(stray, with: "A")])
        XCTAssertNil(issues["A"], "The rightful owner of the voice is not flagged")
        XCTAssertEqual(VoiceHealth.cleanUpPlan(for: [a, b]), ["B": [stray]])
    }

    func testASimilarButDistinctVoiceIsNotFlagged() {
        // Centroids 0.3 apart: two people, not a duplicate and not shared samples.
        let a = speaker("A", samples: [[1, 0, 0]], centroid: [1, 0, 0])
        let b = speaker("B", samples: [[0.7, 0.71, 0]], centroid: [0.7, 0.71, 0])
        XCTAssertTrue(VoiceHealth.issues(in: [a, b]).isEmpty)
    }

    func testDuplicateProfilesAreFlaggedButNotCleanedUp() {
        let a = speaker("Person", samples: [[1, 0, 0]], centroid: [1, 0, 0])
        let b = speaker("person@example.com", samples: [[0.99, 0.03, 0]], centroid: [0.99, 0.03, 0])
        let issues = VoiceHealth.issues(in: [a, b])
        XCTAssertEqual(issues["Person"], [.possibleDuplicate(of: "person@example.com")])
        XCTAssertEqual(issues["person@example.com"], [.possibleDuplicate(of: "Person")])
        XCTAssertTrue(
            VoiceHealth.cleanUpPlan(for: [a, b]).isEmpty,
            "Judging a duplicate's samples against each other would empty both profiles",
        )
    }

    func testAnOutlierNeedsAnEstablishedCentroid() throws {
        let established = speaker("A", samples: [[1, 0, 0], [0, 1, 0]], centroid: [1, 0, 0], weight: 8)
        let outlier = try XCTUnwrap(established.samples.last?.id)
        XCTAssertEqual(VoiceHealth.issues(in: [established])["A"], [.outlierSample(outlier)])

        let young = speaker("B", samples: [[1, 0, 0], [0, 1, 0]], centroid: [1, 0, 0], weight: 2)
        XCTAssertNil(VoiceHealth.issues(in: [young])["B"], "Two confirmations do not say which voice is the stray")
    }

    func testPinnedSamplesAreReportedButNeverCleanedUp() {
        let established = speaker("A", samples: [[1, 0, 0], [0, 1, 0]], centroid: [1, 0, 0], weight: 8, pinned: [1])
        XCTAssertEqual(VoiceHealth.issues(in: [established])["A"]?.count, 1)
        XCTAssertTrue(VoiceHealth.cleanUpPlan(for: [established]).isEmpty)
    }

    func testSyntheticSpeakersAreIgnored() {
        let real = speaker("A", samples: [[1, 0, 0]], centroid: [1, 0, 0])
        let seeded = StoredSpeaker(name: "Seeded", embeddings: [[1, 0, 0]], centroid: [1, 0, 0], isSynthetic: true)
        XCTAssertTrue(VoiceHealth.issues(in: [real, seeded]).isEmpty)
    }

    func testSummaryAndDetails() {
        let id = UUID()
        XCTAssertEqual(VoiceHealth.summary([]), "OK")
        XCTAssertEqual(
            VoiceHealth.summary([.possibleDuplicate(of: "B"), .sharedSample(id, with: "C"), .outlierSample(UUID())]),
            "duplicate?, 2 suspect samples",
        )
        XCTAssertTrue(VoiceHealth.details([.sharedSample(id, with: "C")]).contains("C"))
    }
}
