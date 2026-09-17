@testable import MeetingTranscriber
import XCTest

/// Scanning the output folder into one entry per recording and removing an
/// entry's files. Everything runs on a throwaway folder; removal goes through
/// an injected remover so nothing reaches the real Trash.
final class ProtocolLibraryTests: XCTestCase {
    private let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("protocol-library-\(getpid())-\(UUID().uuidString)", isDirectory: true)

    override func setUpWithError() throws {
        try super.setUpWithError()
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("recordings"), withIntermediateDirectories: true,
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
        try super.tearDownWithError()
    }

    private func write(_ relative: String, bytes: Int = 1) throws {
        let url = dir.appendingPathComponent(relative)
        try Data(repeating: 0x41, count: bytes).write(to: url)
    }

    // MARK: - Scanning

    func testGroupsProtocolTranscriptAndAudioByStem() throws {
        try write("20260914_1240_arc_736a368c.md", bytes: 10)
        try write("20260914_1240_arc_736a368c.txt", bytes: 20)
        try write("recordings/20260914_1240_arc_736a368c_mix.wav", bytes: 1000)
        try write("recordings/20260914_1240_arc_736a368c_mic.wav", bytes: 1000)
        try write("recordings/20260914_1240_arc_736a368c_app.wav", bytes: 1000)

        let entries = ProtocolLibrary.scan(outputDir: dir)

        XCTAssertEqual(entries.count, 1)
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.stem, "20260914_1240_arc_736a368c")
        XCTAssertNotNil(entry.protocolURL)
        XCTAssertNotNil(entry.transcriptURL)
        XCTAssertEqual(entry.audioURLs.count, 3)
        XCTAssertEqual(entry.audioBytes, 3000)
    }

    func testTranscriptOnlyEntryHasNoProtocol() throws {
        try write("20260914_1240_arc_736a368c.txt")

        let entry = try XCTUnwrap(ProtocolLibrary.scan(outputDir: dir).first)

        XCTAssertNil(entry.protocolURL)
        XCTAssertNotNil(entry.transcriptURL)
        XCTAssertTrue(entry.audioURLs.isEmpty)
    }

    func testTitleComesFromTheProtocolHeadingAndDateFromTheStem() throws {
        let url = dir.appendingPathComponent("20260914_1240_arc_736a368c.md")
        try "# Meeting Protocol - Weekly sync\n**Date:** 2026-09-14\n".write(to: url, atomically: true, encoding: .utf8)

        let entry = try XCTUnwrap(ProtocolLibrary.scan(outputDir: dir).first)

        XCTAssertEqual(entry.title, "Weekly sync")
        var comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: entry.recordedAt)
        comps.calendar = nil
        XCTAssertEqual([comps.year, comps.month, comps.day, comps.hour, comps.minute], [2026, 9, 14, 12, 40])
    }

    func testTitleFallsBackToTheSlugWhenThereIsNoProtocol() throws {
        try write("20260914_1240_zoom_meeting_736a368c.txt")

        let entry = try XCTUnwrap(ProtocolLibrary.scan(outputDir: dir).first)

        XCTAssertEqual(entry.title, "zoom meeting")
    }

    func testNewestFirstAndForeignFilesIgnored() throws {
        try write("20260913_0900_a_00000001.md")
        try write("20260915_0900_b_00000002.md")
        try write("notes.md")
        try write("recordings/stray.wav")

        let entries = ProtocolLibrary.scan(outputDir: dir)

        XCTAssertEqual(entries.map(\.stem), ["20260915_0900_b_00000002", "20260913_0900_a_00000001"])
    }

    /// Audio-only leftovers (a recording whose transcription failed) still
    /// deserve a row: they are the files taking up the space.
    func testAudioWithoutTextStillListed() throws {
        try write("recordings/20260914_1240_arc_736a368c_mix.wav", bytes: 5)

        let entry = try XCTUnwrap(ProtocolLibrary.scan(outputDir: dir).first)

        XCTAssertNil(entry.protocolURL)
        XCTAssertNil(entry.transcriptURL)
        XCTAssertEqual(entry.audioBytes, 5)
    }

    // MARK: - Removal

    private final class RecordingRemover: FileRemoving {
        var removed: [URL] = []
        func remove(_ url: URL) {
            removed.append(url)
        }
    }

    func testRemoveAllHandsEveryFileToTheRemover() throws {
        try write("20260914_1240_arc_736a368c.md")
        try write("20260914_1240_arc_736a368c.txt")
        try write("recordings/20260914_1240_arc_736a368c_mix.wav")
        try write("recordings/20260914_1240_arc_736a368c_naming.json")
        let entry = try XCTUnwrap(ProtocolLibrary.scan(outputDir: dir).first)
        let remover = RecordingRemover()

        try ProtocolLibrary.remove(entry, scope: .everything, using: remover)

        XCTAssertEqual(Set(remover.removed.map(\.lastPathComponent)), [
            "20260914_1240_arc_736a368c.md", "20260914_1240_arc_736a368c.txt",
            "20260914_1240_arc_736a368c_mix.wav", "20260914_1240_arc_736a368c_naming.json",
        ])
    }

    func testRemoveAudioOnlyKeepsTheText() throws {
        try write("20260914_1240_arc_736a368c.md")
        try write("20260914_1240_arc_736a368c.txt")
        try write("recordings/20260914_1240_arc_736a368c_mix.wav")
        try write("recordings/20260914_1240_arc_736a368c_mic.wav")
        let entry = try XCTUnwrap(ProtocolLibrary.scan(outputDir: dir).first)
        let remover = RecordingRemover()

        try ProtocolLibrary.remove(entry, scope: .audioOnly, using: remover)

        XCTAssertEqual(Set(remover.removed.map(\.lastPathComponent)), [
            "20260914_1240_arc_736a368c_mix.wav", "20260914_1240_arc_736a368c_mic.wav",
        ])
    }

    // MARK: - Busy entries

    func testEntriesOfJobsStillInThePipelineAreBusy() throws {
        try write("20260914_1240_arc_736a368c.md")
        try write("20260915_0900_b_00000002.md")

        let entries = ProtocolLibrary.scan(outputDir: dir, busyStems: ["20260914_1240_arc_736a368c"])

        XCTAssertEqual(entries.map(\.isBusy), [false, true])
    }
}
