@testable import MeetingTranscriber
import XCTest

/// Merging two sessions of one call: order, tracks, metadata, and which rows
/// may take part. The audio join itself runs on small generated WAVs.
@MainActor
final class SessionMergeTests: XCTestCase {
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var dir: URL!
    private let rate = AudioConstants.targetSampleRate

    override func setUp() async throws {
        try await super.setUp()
        dir = try makeTempDirectory(prefix: "SessionMergeTests")
    }

    override func tearDown() async throws {
        if let dir { try? FileManager.default.removeItem(at: dir) }
        try await super.tearDown()
    }

    // MARK: - Fixtures

    private func date(_ hour: Int, _ minute: Int = 0) -> Date {
        var comps = DateComponents()
        comps.year = 2026
        comps.month = 9
        comps.day = 29
        comps.hour = hour
        comps.minute = minute
        return Calendar.current.date(from: comps) ?? Date()
    }

    private func wav(_ name: String, seconds: Double, value: Float) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try AudioMixer.saveWAV(samples: [Float](repeating: value, count: Int(seconds * Double(rate))), sampleRate: rate, url: url)
        return url
    }

    private func entry(
        _ stem: String, title: String, at start: Date, audio: [URL] = [], busy: Bool = false,
    ) -> ProtocolEntry {
        ProtocolEntry(
            stem: stem, recordedAt: start, title: title, protocolURL: nil, transcriptURL: nil,
            audioURLs: audio, audioBytes: audio.isEmpty ? 0 : 1, isBusy: busy,
        )
    }

    /// A dual-track session: `_app`, `_mic` and their mix.
    private func dualSession(
        _ stem: String,
        title: String,
        at start: Date,
        appSeconds: Double,
        micSeconds: Double,
        app: Float = 0.2,
        mic: Float = 0.1,
    ) throws -> ProtocolEntry {
        let files = try [
            wav("\(stem)_app.wav", seconds: appSeconds, value: app),
            wav("\(stem)_mic.wav", seconds: micSeconds, value: mic),
            wav("\(stem)_mix.wav", seconds: max(appSeconds, micSeconds), value: 0.3),
        ]
        return entry(stem, title: title, at: start, audio: files)
    }

    private func monoSession(_ stem: String, title: String, at start: Date, seconds: Double, value: Float) throws -> ProtocolEntry {
        try entry(stem, title: title, at: start, audio: [wav("\(stem)_mix.wav", seconds: seconds, value: value)])
    }

    private func samples(_ url: URL) throws -> [Float] {
        try AudioMixer.loadAudioFileAsFloat32(url: url)
    }

    // MARK: - Order and metadata

    func testSessionsAreJoinedByStartTimeWhateverTheSelectionOrder() throws {
        let late = try monoSession("20260929_1100_B_aaaaaaaa", title: "Zoom part", at: date(11), seconds: 1, value: 0.5)
        let early = try monoSession("20260929_1000_A_bbbbbbbb", title: "Telemost part", at: date(10), seconds: 1, value: 0.25)

        let plan = try SessionMerge.plan(for: [late, early])

        XCTAssertEqual(plan.sources.map(\.entry.stem), [early.stem, late.stem])
        XCTAssertEqual(SessionMerge.defaultTitle(for: [late, early]), "Telemost part")
    }

    func testEqualStartTimesFallBackToStemOrder() throws {
        let b = try monoSession("20260929_1000_X_bbbbbbbb", title: "b", at: date(10), seconds: 1, value: 0.1)
        let a = try monoSession("20260929_1000_X_aaaaaaaa", title: "a", at: date(10), seconds: 1, value: 0.1)
        XCTAssertEqual(SessionMerge.chronological([b, a]).map(\.stem), [a.stem, b.stem])
    }

    func testJobCarriesTitleStartAndParticipantsOfTheMerge() throws {
        let first = try dualSession("20260929_1000_A_aaaaaaaa", title: "Sync", at: date(10), appSeconds: 1, micSeconds: 1)
        let second = try dualSession("20260929_1100_B_bbbbbbbb", title: "Sync 2", at: date(11), appSeconds: 1, micSeconds: 1)
        let request = SessionMergeRequest(entries: [second, first], title: "Whole call", deleteOriginals: false)
        let plan = try SessionMerge.plan(for: request.entries)
        let audio = try SessionMerge.render(plan, into: dir.appendingPathComponent("out"), basename: "base")

        let job = SessionMerge.makeJob(
            request: request, plan: plan, audio: audio,
            participants: ["Anna", "Boris"], emails: ["a@example.com"],
        )

        XCTAssertEqual(job.meetingTitle, "Whole call")
        XCTAssertEqual(job.meetingStartTime, date(10))
        XCTAssertEqual(job.participants, ["Anna", "Boris"])
        XCTAssertEqual(job.participantEmails, ["a@example.com"])
        XCTAssertEqual(job.mixPath, audio.mix)
        XCTAssertEqual(job.appPath, audio.app)
        XCTAssertEqual(job.micPath, audio.mic)
        XCTAssertEqual(job.micDelay, 0)
    }

    func testUnionKeepsFirstSpellingAndDropsDuplicatesAndBlanks() {
        XCTAssertEqual(
            SessionMerge.union([["Anna", " boris "], ["ANNA", "", "Carl"]]),
            ["Anna", "boris", "Carl"],
        )
    }

    // MARK: - Layout

    func testTwoDualTrackSessionsMergeAsDualTrack() throws {
        let a = try dualSession("20260929_1000_A_aaaaaaaa", title: "A", at: date(10), appSeconds: 1, micSeconds: 1)
        let b = try dualSession("20260929_1100_B_bbbbbbbb", title: "B", at: date(11), appSeconds: 1, micSeconds: 1)
        XCTAssertEqual(try SessionMerge.plan(for: [a, b]).layout, .dualTrack)
    }

    func testOneSingleFileSessionMakesTheWholeMergeMono() throws {
        let a = try dualSession("20260929_1000_A_aaaaaaaa", title: "A", at: date(10), appSeconds: 1, micSeconds: 1)
        let b = try monoSession("20260929_1100_B_bbbbbbbb", title: "B", at: date(11), seconds: 1, value: 0.2)
        XCTAssertEqual(try SessionMerge.plan(for: [a, b]).layout, .mono)
    }

    // MARK: - Which rows take part

    func testBusyRowIsNotMergeable() {
        let busy = entry("20260929_1000_A_aaaaaaaa", title: "A", at: date(10), audio: [dir.appendingPathComponent("x_mix.wav")], busy: true)
        XCTAssertEqual(SessionMerge.skipReason(for: busy), .busy)
    }

    func testRowWithoutAudioIsNotMergeable() {
        let bare = entry("20260929_1000_A_aaaaaaaa", title: "A", at: date(10))
        XCTAssertEqual(SessionMerge.skipReason(for: bare), .noAudio)
    }

    func testCanMergeNeedsTwoUsableRecordings() throws {
        let ok1 = try monoSession("20260929_1000_A_aaaaaaaa", title: "A", at: date(10), seconds: 1, value: 0.1)
        let ok2 = try monoSession("20260929_1100_B_bbbbbbbb", title: "B", at: date(11), seconds: 1, value: 0.1)
        let busy = entry("20260929_1200_C_cccccccc", title: "C", at: date(12), audio: ok1.audioURLs, busy: true)
        let noAudio = entry("20260929_1300_D_dddddddd", title: "D", at: date(13))

        XCTAssertFalse(SessionMerge.canMerge([]))
        XCTAssertFalse(SessionMerge.canMerge([ok1]))
        XCTAssertFalse(SessionMerge.canMerge([ok1, busy]), "a busy row does not count towards the two")
        XCTAssertFalse(SessionMerge.canMerge([ok1, noAudio]), "a row without audio does not count either")
        XCTAssertTrue(SessionMerge.canMerge([ok1, ok2]))
        XCTAssertTrue(SessionMerge.canMerge([ok1, ok2, busy, noAudio]))
    }

    func testPartitionListsWhatWasLeftOutAndWhy() throws {
        let ok1 = try monoSession("20260929_1000_A_aaaaaaaa", title: "A", at: date(10), seconds: 1, value: 0.1)
        let ok2 = try monoSession("20260929_1100_B_bbbbbbbb", title: "B", at: date(11), seconds: 1, value: 0.1)
        let busy = entry("20260929_1200_C_cccccccc", title: "C", at: date(12), audio: ok1.audioURLs, busy: true)
        let noAudio = entry("20260929_1300_D_dddddddd", title: "D", at: date(13))

        let parts = SessionMerge.partition([noAudio, ok2, busy, ok1])

        XCTAssertEqual(parts.mergeable.map(\.stem), [ok1.stem, ok2.stem])
        XCTAssertEqual(parts.skipped.map(\.entry.stem), [busy.stem, noAudio.stem])
        XCTAssertEqual(parts.skipped.map(\.reason), [.busy, .noAudio])
    }

    func testPlanRefusesABusyRowAndTooFewRows() throws {
        let ok = try monoSession("20260929_1000_A_aaaaaaaa", title: "A", at: date(10), seconds: 1, value: 0.1)
        let busy = entry("20260929_1200_C_cccccccc", title: "C", at: date(12), audio: ok.audioURLs, busy: true)

        XCTAssertThrowsError(try SessionMerge.plan(for: [ok])) { error in
            XCTAssertEqual(error as? SessionMergeError, .tooFewSessions)
        }
        XCTAssertThrowsError(try SessionMerge.plan(for: [ok, busy])) { error in
            XCTAssertEqual(error as? SessionMergeError, .notMergeable(stem: busy.stem, reason: .busy))
        }
    }

    // MARK: - Audio

    func testMonoRenderJoinsSessionsInOrderWithASilentGap() throws {
        let first = try monoSession("20260929_1000_A_aaaaaaaa", title: "A", at: date(10), seconds: 1, value: 0.5)
        let second = try monoSession("20260929_1100_B_bbbbbbbb", title: "B", at: date(11), seconds: 2, value: -0.5)
        let plan = try SessionMerge.plan(for: [second, first])

        let out = dir.appendingPathComponent("out")
        let audio = try SessionMerge.render(plan, into: out, basename: "merged")

        XCTAssertNil(audio.app)
        XCTAssertNil(audio.mic)
        let joined = try samples(audio.mix)
        XCTAssertEqual(joined.count, rate * (1 + SessionMerge.gapSeconds + 2), accuracy: 2)
        XCTAssertEqual(joined[rate / 2], 0.5, accuracy: 0.01, "the earlier session comes first")
        XCTAssertEqual(joined[rate + rate], 0, accuracy: 0.001, "silence between the sessions")
        XCTAssertEqual(joined[rate * (1 + SessionMerge.gapSeconds) + rate], -0.5, accuracy: 0.01)
        XCTAssertEqual(audio.mix.lastPathComponent, "merged_mix.wav")
    }

    func testDualTrackRenderKeepsTracksSeparateAndOnOneClock() throws {
        // First session: mic runs 1 s, app only 0.5 s; the app track has to be
        // padded so the second session starts at the same offset on both.
        let first = try dualSession("20260929_1000_A_aaaaaaaa", title: "A", at: date(10), appSeconds: 0.5, micSeconds: 1, app: 0.4, mic: 0.2)
        let second = try dualSession("20260929_1100_B_bbbbbbbb", title: "B", at: date(11), appSeconds: 1, micSeconds: 1, app: -0.4, mic: -0.2)
        let plan = try SessionMerge.plan(for: [first, second])

        let audio = try SessionMerge.render(plan, into: dir.appendingPathComponent("out"), basename: "merged")

        let app = try samples(XCTUnwrap(audio.app))
        let mic = try samples(XCTUnwrap(audio.mic))
        let expected = rate * (1 + SessionMerge.gapSeconds + 1)
        XCTAssertEqual(app.count, expected, accuracy: 2)
        XCTAssertEqual(mic.count, expected, accuracy: 2)
        XCTAssertEqual(app[rate / 4], 0.4, accuracy: 0.01)
        XCTAssertEqual(app[rate * 3 / 4], 0, accuracy: 0.001, "padding after the short app track")
        let secondStart = rate * (1 + SessionMerge.gapSeconds)
        XCTAssertEqual(app[secondStart + rate / 2], -0.4, accuracy: 0.01)
        XCTAssertEqual(mic[secondStart + rate / 2], -0.2, accuracy: 0.01)
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.mix.path))
        XCTAssertEqual(try samples(audio.mix).count, expected, accuracy: 2)
    }

    /// The mix is the file orphan recovery keys on: it must only appear once
    /// the whole merge is written, and nothing may stay behind on failure.
    func testFailedRenderLeavesNothingBehind() throws {
        let good = try monoSession("20260929_1000_A_aaaaaaaa", title: "A", at: date(10), seconds: 1, value: 0.1)
        let brokenURL = dir.appendingPathComponent("20260929_1100_B_bbbbbbbb_mix.wav")
        try Data("not audio".utf8).write(to: brokenURL)
        let broken = entry("20260929_1100_B_bbbbbbbb", title: "B", at: date(11), audio: [brokenURL])
        let plan = try SessionMerge.plan(for: [good, broken])
        let out = dir.appendingPathComponent("out")

        XCTAssertThrowsError(try SessionMerge.render(plan, into: out, basename: "merged")) { error in
            XCTAssertEqual(error as? SessionMergeError, .unreadableAudio(stem: broken.stem))
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: out.path), [])
    }

    func testBasenameIsUniqueAndStartsWithTheFirstSessionStamp() {
        let a = SessionMerge.basename(firstStart: date(10))
        let b = SessionMerge.basename(firstStart: date(10))
        XCTAssertNotEqual(a, b)
        XCTAssertTrue(a.hasPrefix("20260929_100000_merged_"), a)
    }
}
