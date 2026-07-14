import Testing
import Foundation
import WikiFSCore

/// Pure-input tests for `ChatTranscriptRenderer.render(summary:messages:)` —
/// the bytes the File Provider projects at `chats/by-id/<ULID>.md`. Each
/// persistable `AgentEvent` becomes a `## Role` section; events with empty
/// `plainText` (`.messageStop`, `.assistantTextDelta`) are skipped. The header
/// is always `# Title` + a metadata blockquote + `---`.
@Suite struct ChatTranscriptRendererTests {

    /// A fixed date so the metadata-blockquote assertions are deterministic.
    private let created = Date(timeIntervalSince1970: 1_700_000_000)
    private let updated = Date(timeIntervalSince1970: 1_700_000_100)

    private func summary(
        title: String = "Test Chat", kind: ChatKind = .edit, messageCount: Int = 1
    ) -> ChatSummary {
        ChatSummary(
            id: PageID(rawValue: "01H8H000000000000000000AAA"),
            kind: kind, title: title,
            createdAt: created, updatedAt: updated, messageCount: messageCount)
    }

    private func message(_ event: AgentEvent, seq: Int = 0) -> ChatMessage {
        ChatMessage(
            id: PageID(rawValue: "01H8H000000000000000000BB\(seq)"),
            chatID: PageID(rawValue: "01H8H000000000000000000AAA"),
            seq: seq, event: event, createdAt: created)
    }

    // MARK: - Header

    @Test func rendersTitleAsH1() {
        let rendered = ChatTranscriptRenderer.render(summary: summary(title: "My Title"), messages: [])
        #expect(rendered.hasPrefix("# My Title\n"))
    }

    @Test func rendersMetadataBlockquote() {
        let rendered = ChatTranscriptRenderer.render(summary: summary(), messages: [])
        // Message count and created/updated dates appear in a `>` blockquote.
        // (The Kind line was removed when the read-only Ask mode was deleted —
        // all chats are the same kind now.)
        #expect(rendered.contains("**Messages:** 1") == true)
        #expect(rendered.contains("**Created:**") == true)
        #expect(rendered.contains("**Updated:**") == true)
        // The two metadata lines are both blockquote lines.
        let blockquoteLines = rendered.split(separator: "\n").filter { $0.hasPrefix(">") }
        #expect(blockquoteLines.count >= 2)
    }

    @Test func emptyMessagesProducesHeaderOnly() {
        let rendered = ChatTranscriptRenderer.render(summary: summary(), messages: [])
        // Title + metadata + `---`, and NO `## ` section headers.
        #expect(rendered.contains("---\n\n") == true)
        #expect(rendered.contains("## ") == false)
    }

    // MARK: - Per-event sections

    @Test func rendersUserMessageSection() {
        let rendered = ChatTranscriptRenderer.render(
            summary: summary(), messages: [message(.userText("hello"))])
        #expect(rendered.contains("## User\n\nhello") == true)
    }

    @Test func rendersAssistantMessageSection() {
        let rendered = ChatTranscriptRenderer.render(
            summary: summary(), messages: [message(.assistantText("response"))])
        #expect(rendered.contains("## Assistant\n\nresponse") == true)
    }

    @Test func rendersToolUseSection() {
        let rendered = ChatTranscriptRenderer.render(
            summary: summary(),
            messages: [message(.toolUse(name: "Bash", inputSummary: "echo hi"))])
        #expect(rendered.contains("## Tool Use") == true)
        #expect(rendered.contains("Bash") == true)
        #expect(rendered.contains("echo hi") == true)
    }

    @Test func rendersToolResultSection() {
        let rendered = ChatTranscriptRenderer.render(
            summary: summary(),
            messages: [message(.toolResult(isError: false, summary: "done"))])
        #expect(rendered.contains("## Tool Result") == true)
        #expect(rendered.contains("done") == true)
    }

    @Test func rendersResultSection() {
        let rendered = ChatTranscriptRenderer.render(
            summary: summary(),
            messages: [message(.result(isError: false, text: "final answer"))])
        #expect(rendered.contains("## Result") == true)
        #expect(rendered.contains("final answer") == true)
    }

    // MARK: - Skipped events

    @Test func skipsEventsWithEmptyPlainText() {
        // `.assistantTextDelta("")` and `.messageStop` have empty plainText and
        // must NOT produce any section. Interleave them with a real message to
        // confirm only the real message renders.
        let rendered = ChatTranscriptRenderer.render(
            summary: summary(messageCount: 3),
            messages: [
                message(.assistantTextDelta(""), seq: 0),
                message(.messageStop, seq: 1),
                message(.userText("real"), seq: 2),
            ])
        #expect(rendered.contains("## User\n\nreal") == true)
        // No empty-header sections are emitted for the skipped events.
        let sectionHeaders = rendered.split(separator: "\n").filter { $0.hasPrefix("## ") }
        #expect(sectionHeaders.count == 1)
        #expect(sectionHeaders.first == "## User")
    }

    @Test func thinkingRendersAsThinkingSection() {
        let rendered = ChatTranscriptRenderer.render(
            summary: summary(messageCount: 1),
            messages: [
                message(.thinking("Let me reason about this"), seq: 0),
            ])
        #expect(rendered.contains("## Thinking\n\nLet me reason about this") == true)
    }

    @Test func thinkingDeltaIsSkipped() {
        let rendered = ChatTranscriptRenderer.render(
            summary: summary(messageCount: 1),
            messages: [
                message(.thinkingDelta("partial"), seq: 0),
            ])
        let sectionHeaders = rendered.split(separator: "\n").filter { $0.hasPrefix("## ") }
        #expect(sectionHeaders.count == 0)
    }
}
