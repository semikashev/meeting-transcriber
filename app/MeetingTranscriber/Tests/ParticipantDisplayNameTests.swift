@testable import MeetingTranscriber
import XCTest

final class ParticipantDisplayNameTests: XCTestCase {
    func testAliasWinsAndIgnoresCase() {
        let aliases = ParticipantDisplayName.parseAliases("John Smith => jsmith@example.com | Jon Smith")
        XCTAssertEqual(ParticipantDisplayName.resolve("JSmith@Example.com", aliases: aliases), "John Smith")
        XCTAssertEqual(ParticipantDisplayName.resolve("Jon Smith", aliases: aliases), "John Smith")
    }

    func testFirstDotLastAddressBecomesName() {
        XCTAssertEqual(
            ParticipantDisplayName.resolve("anna.petrova@example.org", aliases: [:]),
            "Anna Petrova",
        )
    }

    func testIrregularAddressStaysAsIs() {
        for address in ["jsmith@example.com", "petrov.av@example.org", "a.petrov@example.org", "ivanov.a.b@example.org"] {
            XCTAssertEqual(ParticipantDisplayName.resolve(address, aliases: [:]), address)
        }
    }

    func testPlainNameWithoutAliasIsUnchanged() {
        XCTAssertEqual(ParticipantDisplayName.resolve("Maria Lopez", aliases: [:]), "Maria Lopez")
    }

    func testParseSkipsCommentsBlankAndMalformedLines() {
        let aliases = ParticipantDisplayName.parseAliases("""
        # comment
        Team Lead => lead@example.com

        no arrow here
         => orphan@example.com
        """)
        XCTAssertEqual(aliases, ["lead@example.com": "Team Lead"])
    }

    func testAliasesFromDefaultsReadsTheFileNamedThere() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("aliases-\(UUID().uuidString).txt")
        try "Bob Stone => robert.stone@example.com".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let defaults = try scratchDefaults()
        defaults.set(file.path, forKey: ParticipantDisplayName.aliasesPathKey)

        XCTAssertEqual(ParticipantDisplayName.aliasesFromDefaults(defaults), ["robert.stone@example.com": "Bob Stone"])
    }

    func testAliasesFromDefaultsIsEmptyWhenUnset() throws {
        let defaults = try scratchDefaults()
        XCTAssertTrue(ParticipantDisplayName.aliasesFromDefaults(defaults).isEmpty)
    }

    private func scratchDefaults() throws -> UserDefaults {
        let name = "ParticipantDisplayNameTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { DefaultsSuite.remove(name) }
        return defaults
    }
}
