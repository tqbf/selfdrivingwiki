#if os(macOS)
import Testing
import Foundation
import Synchronization
@testable import WikiFSEngine
@testable import WikiFSCore

/// Tests for the on-device Apple Intelligence summarizer
/// (plans/apple-intelligence-summarizer.md).
///
/// The model turn is an injected `AppleIntelligenceSummarizer.Engine`
/// closure, so every case here runs without Apple Intelligence hardware:
/// prompt parity with the ACP path, `sanitizeTitle` reuse, the nil contracts
/// (empty input, empty reply, thrown error, timeout). Availability gating at
/// the preparation level is covered in `AgentProviderRuntimeTests`.
@Suite
struct AppleIntelligenceSummarizerTests {

    /// A recording engine: captures every (systemPrompt, prompt) turn and
    /// replies with the scripted value. `Sendable` — the only mutable state is
    /// the `Mutex`-guarded call log.
    private final class RecordingEngine: Sendable {
        let calls = Mutex<[(system: String, prompt: String)]>([])
        let reply: String

        init(reply: String) {
            self.reply = reply
        }

        var engine: AppleIntelligenceSummarizer.Engine {
            AppleIntelligenceSummarizer.Engine { systemPrompt, prompt in
                self.calls.withLock { $0.append((systemPrompt, prompt)) }
                return self.reply
            }
        }

        var recorded: [(system: String, prompt: String)] {
            calls.withLock { $0 }
        }
    }

    // MARK: - Prompt parity with the ACP path

    @Test func summary_sendsTheAcpParityPrompt() async {
        let recorder = RecordingEngine(reply: "  A crisp one-liner.  ")
        let summary = await AppleIntelligenceSummarizer.summary(
            text: "Hello world. This is longer.",
            engine: recorder.engine)

        #expect(summary == "A crisp one-liner.")
        #expect(recorder.recorded.count == 1)
        #expect(recorder.recorded[0].system == MessageSummarizer.modelSystemPrompt)
        #expect(recorder.recorded[0].prompt == "Summarize this in one sentence:\n\nHello world. This is longer.")
    }

    @Test func title_sendsTheChatTitleTaskPrompt() async {
        let recorder = RecordingEngine(reply: "whatever")
        _ = await AppleIntelligenceSummarizer.title(
            question: "What is origami?",
            answer: "Folded paper art.",
            engine: recorder.engine)

        #expect(recorder.recorded.count == 1)
        #expect(recorder.recorded[0].system == PublicPrompts.chatTitleTask)
        #expect(recorder.recorded[0].prompt ==
            "Question:\nWhat is origami?\n\nAssistant reply (may be truncated):\nFolded paper art.\n\nTitle:")
    }

    @Test func title_withoutAnswer_omitsTheReplyBlock() async {
        let recorder = RecordingEngine(reply: "T")
        _ = await AppleIntelligenceSummarizer.title(
            question: "What is origami?",
            answer: nil,
            engine: recorder.engine)
        #expect(recorder.recorded[0].prompt == "Question:\nWhat is origami?\n\nTitle:")
    }

    // MARK: - Title cleanup

    @Test func title_sanitizesLikeTheAcpPath() async {
        let recorder = RecordingEngine(reply: "  \"Title: Paper Folding\".\nsecond line  ")
        let title = await AppleIntelligenceSummarizer.title(
            question: "What is origami?",
            answer: nil,
            engine: recorder.engine)
        #expect(title == "Paper Folding")
    }

    @Test func title_unusableReply_returnsNil() async {
        let recorder = RecordingEngine(reply: "   \n  ")
        let title = await AppleIntelligenceSummarizer.title(
            question: "What is origami?",
            answer: nil,
            engine: recorder.engine)
        #expect(title == nil)
    }

    // MARK: - Nil contracts

    @Test func title_emptyQuestion_skipsTheEngine() async {
        let recorder = RecordingEngine(reply: "T")
        let title = await AppleIntelligenceSummarizer.title(
            question: "   \n ",
            answer: nil,
            engine: recorder.engine)
        #expect(title == nil)
        #expect(recorder.recorded.isEmpty)
    }

    @Test func summary_emptyText_skipsTheEngine() async {
        let recorder = RecordingEngine(reply: "S")
        let summary = await AppleIntelligenceSummarizer.summary(
            text: "  ",
            engine: recorder.engine)
        #expect(summary == nil)
        #expect(recorder.recorded.isEmpty)
    }

    @Test func oneShot_thrownEngineError_returnsNil() async {
        let engine = AppleIntelligenceSummarizer.Engine { _, _ in
            throw URLError(.timedOut)
        }
        let summary = await AppleIntelligenceSummarizer.summary(
            text: "Hello.",
            engine: engine)
        #expect(summary == nil)
    }

    @Test func oneShot_timeout_returnsNil() async {
        // The engine stalls past a short timeout; the race must cancel it and
        // return nil, never hang the cooperative pool.
        let engine = AppleIntelligenceSummarizer.Engine { _, _ in
            try await Task.sleep(for: .seconds(5))
            return "late"
        }
        let summary = await AppleIntelligenceSummarizer.summary(
            text: "Hello.",
            engine: engine,
            timeout: .milliseconds(50))
        #expect(summary == nil)
    }
}
#endif
