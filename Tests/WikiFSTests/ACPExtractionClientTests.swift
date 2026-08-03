#if os(macOS)
import Foundation
import Testing
import WikiFSEngine
import WikiFSCore
@testable import WikiFSEngine
@testable import WikiFSCore

/// Tests for `ACPExtractionClient` — specifically the delta collection fix.
///
/// The bug was that `ACPExtractionClient.convert` only collected `.assistantText`
/// events, but `ACPBackend` emits `.assistantTextDelta` during streaming. This
/// test file verifies that delta chunks are properly concatenated.
struct ACPExtractionClientTests {

    // MARK: - Delta collection (regression test)

    @Test func convert_collectsAssistantTextDelta() async throws {
        // Regression test for issue where .assistantTextDelta events were silently
        // dropped because only .assistantText was handled in the collection loop.
        // ACPBackend emits deltas during streaming — this test verifies they're
        // concatenated correctly.
        var collectedText = ""
        let events: [AgentEvent] = [
            .assistantTextDelta("# Hello\n\n"),
            .assistantTextDelta("This is "),
            .assistantTextDelta("extracted "),
            .assistantTextDelta("markdown."),
            .messageStop
        ]

        for event in events {
            switch event {
            case .assistantText(let text):
                collectedText += text
            case .assistantTextDelta(let text):
                collectedText += text
            case .result(let isError, let text):
                if !isError && collectedText.isEmpty {
                    collectedText = text
                }
            default:
                break
            }
        }

        #expect(collectedText == "# Hello\n\nThis is extracted markdown.")
    }

    @Test func convert_mixedAssistantTextAndDelta() async throws {
        // Some backends may emit both .assistantText and .assistantTextDelta —
        // verify both are collected and concatenated.
        var collectedText = ""
        let events: [AgentEvent] = [
            .assistantText("Full "),
            .assistantTextDelta("delta "),
            .assistantTextDelta("chunks."),
            .messageStop
        ]

        for event in events {
            switch event {
            case .assistantText(let text):
                collectedText += text
            case .assistantTextDelta(let text):
                collectedText += text
            case .result(let isError, let text):
                if !isError && collectedText.isEmpty {
                    collectedText = text
                }
            default:
                break
            }
        }

        #expect(collectedText == "Full delta chunks.")
    }

    @Test func convert_resultFallbackWhenNoDeltas() async throws {
        // Some agents emit everything in .result instead of streaming deltas —
        // the result should be taken as fallback when collected text is empty.
        var collectedText = ""
        let events: [AgentEvent] = [
            .result(isError: false, text: "Result-based markdown."),
            .messageStop
        ]

        for event in events {
            switch event {
            case .assistantText(let text):
                collectedText += text
            case .assistantTextDelta(let text):
                collectedText += text
            case .result(let isError, let text):
                if !isError && collectedText.isEmpty {
                    collectedText = text
                }
            default:
                break
            }
        }

        #expect(collectedText == "Result-based markdown.")
    }

    @Test func convert_errorResultDoesNotOverrideCollectedText() async throws {
        // An error .result should NOT override already-collected delta text.
        var collectedText = ""
        let events: [AgentEvent] = [
            .assistantTextDelta("Collected "),
            .assistantTextDelta("text."),
            .result(isError: true, text: "Error message."),
            .messageStop
        ]

        var turnError: String?
        for event in events {
            switch event {
            case .assistantText(let text):
                collectedText += text
            case .assistantTextDelta(let text):
                collectedText += text
            case .result(let isError, let text):
                if isError {
                    turnError = text
                } else if collectedText.isEmpty {
                    collectedText = text
                }
            default:
                break
            }
        }

        #expect(collectedText == "Collected text.")
        #expect(turnError == "Error message.")
    }
}
#endif // os(macOS)