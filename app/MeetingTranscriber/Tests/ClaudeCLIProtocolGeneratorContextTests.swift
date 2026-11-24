@testable import MeetingTranscriber
import XCTest

#if !APPSTORE

    /// The glossary a protocol run gets: how it is composed and how it reaches
    /// the CLI.
    final class ClaudeCLIProtocolGeneratorContextTests: XCTestCase {
        func testBuildSubprocessArgsAppendsProtocolContext() {
            let args = ClaudeCLIProtocolGenerator.buildSubprocessArgs(
                claudeBin: "claude",
                resolvedBin: "/opt/homebrew/bin/claude", noSessionPersistence: false,
                protocolContext: "Glossary: Acme",
            )
            XCTAssertEqual(Array(args.suffix(2)), ["--append-system-prompt", "Glossary: Acme"])
        }

        func testBuildSubprocessArgsSkipsEmptyProtocolContext() {
            let args = ClaudeCLIProtocolGenerator.buildSubprocessArgs(
                claudeBin: "claude",
                resolvedBin: "/opt/homebrew/bin/claude", noSessionPersistence: false,
                protocolContext: "",
            )
            XCTAssertFalse(args.contains("--append-system-prompt"))
        }

        func testComposeProtocolContextReplacesVocabularyPlaceholder() {
            let text = ClaudeCLIProtocolGenerator.composeProtocolContext(
                template: "Terms: {{vocabulary}}.",
                vocabularyTerms: ["Acme", "Widget Pro"],
            )
            XCTAssertEqual(text, "Terms: Acme, Widget Pro.")
        }

        func testComposeProtocolContextWithoutPlaceholderKeepsTemplate() {
            let text = ClaudeCLIProtocolGenerator.composeProtocolContext(
                template: "No terms here.",
                vocabularyTerms: ["Acme"],
            )
            XCTAssertEqual(text, "No terms here.")
        }
    }

#endif
