import FluidAudio
@testable import MeetingTranscriber
import XCTest

/// The rescorer's verdicts must reach the segments the transcript is built
/// from. Segments are grouped from token timings, so a replacement that only
/// rewrites `ASRResult.text` is silently dropped.
final class ParakeetVocabularyRescoringTests: XCTestCase {
    func testAppliedTermsReachTheSegmentText() throws {
        let result = asrResult([
            timing("Мы", 0.0, 0.3),
            timing(" подня", 0.3, 0.5),
            timing("ли", 0.5, 0.7),
            timing(" кубер", 0.8, 1.0),
            timing("нетис", 1.0, 1.2),
            timing(".", 1.2, 1.3),
            timing(" Потом", 2.0, 2.4),
            timing(" джи", 2.4, 2.6),
            timing("ра", 2.6, 2.8),
        ])
        let evidence = evidenceOutput([
            candidate(tokens: 3 ..< 6, base: "кубернетис.", term: "Kubernetes"),
            candidate(tokens: 7 ..< 9, base: "джира", term: "Jira"),
        ])

        let rescored = ParakeetVocabularyRescoring.applying(evidence, to: result)

        let segments = try ParakeetTokenGrouping.groupIntoSegments(XCTUnwrap(rescored.tokenTimings))
        XCTAssertEqual(segments.map(\.text), ["Мы подняли Kubernetes.", "Потом Jira"])
        XCTAssertEqual(segments.map(\.start), [0.0, 2.0])
        XCTAssertEqual(segments.map(\.end), [1.3, 2.8])
    }

    func testMultiWordTermTakesTheWholeSpanTiming() throws {
        let result = asrResult([
            timing(" гит", 0.0, 0.2),
            timing("х", 0.2, 0.4),
            timing(" аб", 0.4, 0.6),
            timing("ом", 0.6, 0.8),
            timing(" пользуемся", 0.9, 1.3),
        ])
        let evidence = evidenceOutput([
            candidate(tokens: 0 ..< 4, base: "гитх абом", term: "GitHub"),
        ])

        let timings = try XCTUnwrap(ParakeetVocabularyRescoring.applying(evidence, to: result).tokenTimings)

        XCTAssertEqual(timings.map(\.token), [" GitHub", " пользуемся"])
        XCTAssertEqual(timings[0].startTime, 0.0)
        XCTAssertEqual(timings[0].endTime, 0.8)
    }

    func testCandidatesTheRescorerDidNotApplyLeaveTheTranscriptAlone() throws {
        let tokens = [timing(" джи", 0.0, 0.2), timing("ра", 0.2, 0.4), timing(" пост", 0.5, 0.7), timing("грес", 0.7, 0.9)]
        let evidence = evidenceOutput([
            candidate(tokens: 0 ..< 2, base: "джира", term: "Jira", outcome: .rejectedByComparison),
            candidate(tokens: 0 ..< 2, base: "джира", term: "Gira", outcome: .supersededByOverlap),
            candidate(tokens: 2 ..< 4, base: "постгрес", term: "Postgres", outcome: .unavailableEvidence),
            // Applied, but without contiguous token provenance there is no
            // span to put it in.
            candidate(tokens: nil, base: "постгрес", term: "Postgres"),
        ])

        let timings = try XCTUnwrap(ParakeetVocabularyRescoring.applying(evidence, to: asrResult(tokens)).tokenTimings)

        XCTAssertEqual(timings.map(\.token), [" джи", "ра", " пост", "грес"])
    }

    func testOverlappingAppliedSpansWriteOnlyOneTerm() throws {
        // The rescorer's arbitration never applies overlapping spans. If a
        // future version did, the second write must not index past a span
        // the first one already shrank and take the whole job down.
        let tokens = [timing(" гит", 0.0, 0.2), timing("х", 0.2, 0.4), timing(" аб", 0.4, 0.6), timing("ом", 0.6, 0.8)]
        let evidence = evidenceOutput([
            candidate(tokens: 0 ..< 4, base: "гитх абом", term: "GitHub"),
            candidate(tokens: 1 ..< 3, base: "х аб", term: "Hub"),
        ])

        let timings = try XCTUnwrap(ParakeetVocabularyRescoring.applying(evidence, to: asrResult(tokens)).tokenTimings)

        XCTAssertEqual(timings.map(\.token), [" гит", "Hub", "ом"])
    }

    func testCapitalizedWordCapitalizesLowercaseTerm() throws {
        // Mirrors the rescorer's own text output: a sentence-initial word keeps
        // its capital when the term is spelled lowercase.
        let result = asrResult([timing("Эй", 0.0, 0.2), timing("пи", 0.2, 0.4), timing("ай", 0.4, 0.6)])
        let evidence = evidenceOutput([candidate(tokens: 0 ..< 3, base: "Эйпиай", term: "api")])

        let timings = try XCTUnwrap(ParakeetVocabularyRescoring.applying(evidence, to: result).tokenTimings)

        XCTAssertEqual(timings.map(\.token), ["Api"])
    }

    // MARK: - Helpers

    private func timing(_ token: String, _ start: TimeInterval, _ end: TimeInterval) -> TokenTiming {
        TokenTiming(token: token, tokenId: 0, startTime: start, endTime: end, confidence: 0.9)
    }

    private func asrResult(_ timings: [TokenTiming]) -> ASRResult {
        ASRResult(
            text: timings.map(\.token).joined(),
            confidence: 0.9,
            duration: timings.last?.endTime ?? 0,
            processingTime: 0,
            tokenTimings: timings,
        )
    }

    private func evidenceOutput(_ candidates: [VocabularyRescorer.CandidateEvidence]) -> VocabularyRescorer.CandidateEvidenceOutput {
        VocabularyRescorer.CandidateEvidenceOutput(baseText: "", baseWords: [], candidates: candidates)
    }

    private func candidate(
        tokens: Range<Int>?,
        base: String,
        term: String,
        outcome: VocabularyRescorer.LegacyApplicationOutcome = .applied,
    ) -> VocabularyRescorer.CandidateEvidence {
        VocabularyRescorer.CandidateEvidence(
            candidateID: 0,
            origin: .termCentricSingleWord,
            basePhrase: base,
            canonicalTerm: term,
            matchedAlias: nil,
            similarity: 0.8,
            rawVocabularyCTCScore: nil,
            rawOriginalCTCScore: nil,
            effectiveBoost: nil,
            wordRange: 0 ..< 0,
            tokenRange: tokens,
            baseTextUTF8Range: nil,
            startTime: nil,
            endTime: nil,
            comparisonPassed: outcome == .applied || outcome == .supersededByOverlap,
            legacyOutcome: outcome,
            reason: "",
        )
    }
}
