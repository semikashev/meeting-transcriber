import FluidAudio
@testable import MeetingTranscriber
import XCTest

/// The rescorer's verdicts must reach the segments the transcript is built
/// from. Segments are grouped from token timings, so a replacement that only
/// rewrites `ASRResult.text` is silently dropped.
final class ParakeetVocabularyRescoringTests: XCTestCase {
    /// What an English-only CTC tokenizer can spell.
    private let english = ParakeetVocabularyRescoring.alphabet(
        ofTokens: ["<unk>", "▁the", "abcdefghijklmnopqrstuvwxyz", "ABCDEFGHIJKLMNOPQRSTUVWXYZ"],
    )

    func testAppliedTermsReachTheSegmentText() throws {
        let result = asrResult([
            timing("We", 0.0, 0.3),
            timing(" moved", 0.3, 0.7),
            timing(" to", 0.7, 0.8),
            timing(" kuber", 0.8, 1.0),
            timing("netis", 1.0, 1.2),
            timing(".", 1.2, 1.3),
            timing(" Then", 2.0, 2.4),
            timing(" gi", 2.4, 2.6),
            timing("ra", 2.6, 2.8),
        ])
        let evidence = evidenceOutput([
            candidate(tokens: 3 ..< 6, base: "kubernetis.", term: "Kubernetes"),
            candidate(tokens: 7 ..< 9, base: "gira", term: "Jira"),
        ])

        let rescored = ParakeetVocabularyRescoring.applying(evidence, to: result, alphabet: english)

        let segments = try ParakeetTokenGrouping.groupIntoSegments(XCTUnwrap(rescored.tokenTimings))
        XCTAssertEqual(segments.map(\.text), ["We moved to Kubernetes.", "Then Jira"])
        XCTAssertEqual(segments.map(\.start), [0.0, 2.0])
        XCTAssertEqual(segments.map(\.end), [1.3, 2.8])
    }

    func testMultiWordTermTakesTheWholeSpanTiming() throws {
        let result = asrResult([
            timing(" get", 0.0, 0.2),
            timing(" h", 0.2, 0.4),
            timing("ub", 0.4, 0.6),
            timing(" works", 0.7, 1.1),
        ])
        let evidence = evidenceOutput([
            candidate(tokens: 0 ..< 3, base: "get hub", term: "GitHub"),
        ])

        let timings = try XCTUnwrap(
            ParakeetVocabularyRescoring.applying(evidence, to: result, alphabet: english).tokenTimings,
        )

        XCTAssertEqual(timings.map(\.token), [" GitHub", " works"])
        XCTAssertEqual(timings[0].startTime, 0.0)
        XCTAssertEqual(timings[0].endTime, 0.6)
    }

    func testCandidatesTheRescorerDidNotApplyLeaveTheTranscriptAlone() throws {
        let tokens = [timing(" gi", 0.0, 0.2), timing("ra", 0.2, 0.4), timing(" post", 0.5, 0.7), timing("gress", 0.7, 0.9)]
        let evidence = evidenceOutput([
            candidate(tokens: 0 ..< 2, base: "gira", term: "Jira", outcome: .rejectedByComparison),
            candidate(tokens: 0 ..< 2, base: "gira", term: "Gitea", outcome: .supersededByOverlap),
            candidate(tokens: 2 ..< 4, base: "postgress", term: "Postgres", outcome: .unavailableEvidence),
            // Applied, but without contiguous token provenance there is no
            // span to put it in.
            candidate(tokens: nil, base: "postgress", term: "Postgres"),
        ])

        let timings = try XCTUnwrap(
            ParakeetVocabularyRescoring.applying(evidence, to: asrResult(tokens), alphabet: english).tokenTimings,
        )

        XCTAssertEqual(timings.map(\.token), [" gi", "ra", " post", "gress"])
    }

    func testCandidatesTheCtcModelCannotSpellAreSkipped() throws {
        // FluidAudio's CTC models are English-only: a phrase or term in
        // another script tokenizes to nothing, and the comparison that
        // "passes" is noise. Measured on a Russian meeting it turned
        // "как" into "калк" and "например" into a product term.
        let tokens = [
            timing(" как", 0.0, 0.2), timing(" кофе", 0.3, 0.6), timing(" sport", 0.6, 0.7),
            timing(" red", 0.7, 0.9), timing("dis", 0.9, 1.1),
        ]
        let evidence = evidenceOutput([
            candidate(tokens: 0 ..< 1, base: "как", term: "калк"),
            candidate(tokens: 1 ..< 2, base: "кофе", term: "Coffee"),
            candidate(tokens: 2 ..< 3, base: "sport", term: "Спорт"),
            candidate(tokens: 3 ..< 5, base: "reddis", term: "Redis"),
        ])

        let timings = try XCTUnwrap(
            ParakeetVocabularyRescoring.applying(evidence, to: asrResult(tokens), alphabet: english).tokenTimings,
        )

        XCTAssertEqual(timings.map(\.token), [" как", " кофе", " sport", " Redis"])
    }

    func testOverlappingAppliedSpansWriteOnlyOneTerm() throws {
        // The rescorer's arbitration never applies overlapping spans. If a
        // future version did, the second write must not index past a span
        // the first one already shrank and take the whole job down.
        let tokens = [timing(" get", 0.0, 0.2), timing(" h", 0.2, 0.4), timing("ub", 0.4, 0.6), timing(" ac", 0.6, 0.8)]
        let evidence = evidenceOutput([
            candidate(tokens: 0 ..< 4, base: "get hub ac", term: "GitHub Actions"),
            candidate(tokens: 1 ..< 3, base: "hub", term: "Hub"),
        ])

        let timings = try XCTUnwrap(
            ParakeetVocabularyRescoring.applying(evidence, to: asrResult(tokens), alphabet: english).tokenTimings,
        )

        XCTAssertEqual(timings.map(\.token), [" get", " Hub", " ac"])
    }

    func testCapitalizedWordCapitalizesLowercaseTerm() throws {
        // Mirrors the rescorer's own text output: a sentence-initial word keeps
        // its capital when the term is spelled lowercase.
        let result = asrResult([timing("Ay", 0.0, 0.2), timing("pee", 0.2, 0.4), timing("eye", 0.4, 0.6)])
        let evidence = evidenceOutput([candidate(tokens: 0 ..< 3, base: "Aypeeeye", term: "api")])

        let timings = try XCTUnwrap(
            ParakeetVocabularyRescoring.applying(evidence, to: result, alphabet: english).tokenTimings,
        )

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
