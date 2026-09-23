import FluidAudio
import Foundation

/// Writes the CTC vocabulary rescorer's verdicts into the token timings.
///
/// Segments are grouped from token timings, not from `ASRResult.text`, so a
/// replacement that only rewrites the text never reaches the transcript.
/// `VocabularyRescorer.RescoreOutput` carries no positions; the candidate
/// evidence of the same evaluation does (token range per applied candidate),
/// so the replacement lands exactly on the tokens it was decided for.
enum ParakeetVocabularyRescoring {
    private static let wordBoundary: Set<Character> = [" ", "▁"]

    /// The characters a CTC model can spell: everything its tokens are made of.
    static func alphabet(ofTokens tokens: some Sequence<String>) -> Set<Character> {
        Set(tokens.joined())
    }

    /// - Parameter alphabet: characters the CTC model can spell. FluidAudio's
    ///   CTC models are English-only; for a phrase or term with letters
    ///   outside that alphabet the acoustic comparison has nothing to score,
    ///   yet can still "pass". Such candidates are left out.
    static func applying(
        _ evidence: VocabularyRescorer.CandidateEvidenceOutput,
        to result: ASRResult,
        alphabet: Set<Character>,
    ) -> ASRResult {
        guard var timings = result.tokenTimings else { return result }
        let applied = evidence.candidates
            .filter { $0.legacyOutcome == .applied }
            .filter { canSpell($0.basePhrase, in: alphabet) && canSpell($0.canonicalTerm, in: alphabet) }
            .compactMap { candidate in
                candidate.tokenRange.map { (range: $0, candidate: candidate) }
            }
            .filter { $0.range.lowerBound >= 0 && $0.range.upperBound <= timings.count && !$0.range.isEmpty }
            // Back to front, so earlier ranges stay valid while later spans shrink.
            .sorted { $0.range.lowerBound > $1.range.lowerBound }
        guard !applied.isEmpty else { return result }

        var terms: [String] = []
        var writtenFrom = Int.max
        // Overlapping spans are not expected; a second write into a span
        // already shrunk would index past it.
        for (range, candidate) in applied where range.upperBound <= writtenFrom {
            timings.replaceSubrange(range, with: replacementTokens(for: candidate, replacing: Array(timings[range])))
            terms.append(candidate.canonicalTerm)
            writtenFrom = range.lowerBound
        }
        terms.reverse()
        return ASRResult(
            text: timings.map(\.token).joined().trimmingCharacters(in: .whitespaces),
            confidence: result.confidence,
            duration: result.duration,
            processingTime: result.processingTime,
            tokenTimings: timings,
            performanceMetrics: result.performanceMetrics,
            ctcDetectedTerms: terms,
            ctcAppliedTerms: terms,
        )
    }

    /// One token for the term, spanning the replaced words, followed by the
    /// punctuation tokens that closed the span. The rescorer's own text drops
    /// that punctuation; keeping it keeps a sentence end a segment end.
    private static func replacementTokens(
        for candidate: VocabularyRescorer.CandidateEvidence,
        replacing span: [TokenTiming],
    ) -> [TokenTiming] {
        var words = span
        var closingPunctuation: [TokenTiming] = []
        while let last = words.last, words.count > 1, isPunctuation(last.token) {
            closingPunctuation.insert(words.removeLast(), at: 0)
        }
        guard let first = words.first, let last = words.last else { return span }
        let boundary = String(first.token.prefix { wordBoundary.contains($0) })
        let term = TokenTiming(
            token: boundary + capitalized(candidate.canonicalTerm, like: candidate.basePhrase),
            tokenId: first.tokenId,
            startTime: first.startTime,
            endTime: last.endTime,
            confidence: words.map(\.confidence).min() ?? first.confidence,
        )
        return [term] + closingPunctuation
    }

    /// Same rule as the rescorer's text output: a capitalized original word
    /// capitalizes a term spelled lowercase, nothing else changes.
    private static func capitalized(_ term: String, like original: String) -> String {
        guard original.first?.isUppercase == true, term.first?.isLowercase == true else { return term }
        return term.prefix(1).uppercased() + term.dropFirst()
    }

    private static func canSpell(_ text: String, in alphabet: Set<Character>) -> Bool {
        text.allSatisfy { !$0.isLetter || alphabet.contains($0) }
    }

    private static func isPunctuation(_ token: String) -> Bool {
        let scalars = token.trimmingCharacters(in: .whitespaces).unicodeScalars
        return !scalars.isEmpty && scalars.allSatisfy(CharacterSet.punctuationCharacters.contains)
    }
}
