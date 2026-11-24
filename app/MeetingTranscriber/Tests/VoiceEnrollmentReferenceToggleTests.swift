@testable import MeetingTranscriber
import ViewInspector
import XCTest

@MainActor
final class VoiceEnrollmentReferenceToggleTests: XCTestCase {
    func testReferenceToggleIsOnByDefault() throws {
        let dir = try makeTempDirectory(prefix: "VoiceEnrollmentReferenceToggleTests")
        let view = VoiceEnrollmentView(
            matcher: SpeakerMatcher(dbPath: dir.appendingPathComponent("speakers.json")),
            diarizerFactory: { MockDiarization() },
            onClose: {},
            initialStage: .pickFile,
        )
        let toggle = try view.inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.enrollAsReferenceToggle)
            .find(ViewType.Toggle.self)
        XCTAssertTrue(
            try toggle.isOn(),
            "A recording picked on purpose is the cleanest evidence of a voice; keep it by default",
        )
    }
}
