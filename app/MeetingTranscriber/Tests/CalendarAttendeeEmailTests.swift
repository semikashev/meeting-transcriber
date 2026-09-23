@testable import MeetingTranscriber
import XCTest

/// How an EventKit attendee URL becomes the address the protocol webhook sends.
final class CalendarAttendeeEmailTests: XCTestCase {
    private func address(_ string: String) -> String? {
        URL(string: string).flatMap(CalendarAttendeeEmail.address(from:))
    }

    func testMailtoURLGivesTheLowercasedAddress() {
        XCTAssertEqual(address("mailto:Anna.Smith@Example.com"), "anna.smith@example.com")
        XCTAssertEqual(address("MAILTO:ben@example.org"), "ben@example.org")
    }

    func testPercentEncodingAndQueryAreStripped() {
        XCTAssertEqual(address("mailto:anna%2Bteam@example.com?subject=x"), "anna+team@example.com")
    }

    func testURLsWithoutAnAddressGiveNothing() {
        XCTAssertNil(address("urn:uuid:11111111-2222-3333-4444-555555555555"))
        XCTAssertNil(address("https://calendar.example/principals/42"))
        XCTAssertNil(address("mailto:"))
        XCTAssertNil(address("mailto:nobody"))
        XCTAssertNil(address("mailto:@example.com"))
    }

    func testUniqueKeepsTheFirstOccurrenceInOrder() {
        XCTAssertEqual(
            CalendarAttendeeEmail.unique(["b@example.com", "a@example.com", "b@example.com"]),
            ["b@example.com", "a@example.com"],
        )
    }
}
