#if os(macOS)
import Foundation
import FoundationModels
import WikiFSCore

/// The on-device Apple Intelligence summary service
/// (plans/apple-intelligence-summarizer.md).
///
/// Produces the same outputs as `MessageSummarizer`'s Model mode — a chat
/// title from the opening question and first reply, a one-sentence per-message
/// summary — through the in-process Foundation Models system model instead of
/// a one-shot ACP subprocess. No provider, credential, sandbox scratch world,
/// lease, or entitlement. Selected by pinning
/// `stageProviderIds["summarizer"]` to `ProviderID.appleIntelligence`; see
/// `MessageSummarizer.mode(for:)`.
///
/// Every failure path returns nil so the callers degrade exactly like the ACP
/// path (strict-tier contract, issue #1276): a nil summary falls back to the
/// truncation summary, a nil title falls back to the provisional title. An
/// unavailable system model is detected earlier, at preparation time in
/// `AgentProviderRuntime.prepareSummarization()`.
///
/// **Test seam:** the model call is an injected `Engine` closure. Tests pass
/// a scripted reply closure and a short timeout; they never touch the real
/// system model (which CI cannot provide).
public enum AppleIntelligenceSummarizer {

    /// One one-shot model turn: send `prompt` under `systemPrompt`, return the
    /// model's text. The production engine wraps a `LanguageModelSession`.
    /// Injectable so tests drive the AI path without Apple Intelligence.
    public struct Engine: Sendable {
        public let reply: @Sendable (_ systemPrompt: String, _ prompt: String) async throws -> String

        public init(
            reply: @escaping @Sendable (_ systemPrompt: String, _ prompt: String) async throws -> String
        ) {
            self.reply = reply
        }

        /// The production engine: one fresh `LanguageModelSession` per call
        /// (sessions are cheap; the system model is shared), the system prompt
        /// as session instructions, one `respond(to:)`, the response text.
        public static let system = Engine(
            reply: { systemPrompt, prompt in
                let session = LanguageModelSession(
                    instructions: Instructions(systemPrompt))
                let response = try await session.respond(to: prompt)
                return response.content
            })
    }

    /// Why Apple Intelligence cannot run right now, for the log. nil when the
    /// system model is available. PURE with respect to app state — it reads
    /// only `SystemLanguageModel.default.availability`.
    public static func unavailabilityReason() -> String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return "this Mac is not eligible for Apple Intelligence"
            case .appleIntelligenceNotEnabled:
                return "Apple Intelligence is not enabled"
            case .modelNotReady:
                return "the on-device model is not ready (still downloading)"
            @unknown default:
                return "an unknown availability reason"
            }
        }
    }

    /// The per-call wall-clock budget. A hung on-device call must not pin a
    /// summary task forever. Tuning value: one bounded sentence of output at
    /// on-device speeds fits well inside 60 seconds even under load.
    public static let timeout: Duration = .seconds(60)

    /// A timed-out turn.
    private struct TimedOut: Error {}

    /// One engine turn raced against the timeout. Returns the trimmed reply,
    /// or nil on empty output, a thrown error, or timeout — every nil consumer
    /// is a degradation path, never a crash or a hang.
    static func oneShot(
        systemPrompt: String,
        prompt: String,
        engine: Engine,
        timeout: Duration
    ) async -> String? {
        do {
            let raw = try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask { try await engine.reply(systemPrompt, prompt) }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw TimedOut()
                }
                guard let first = try await group.next() else { throw TimedOut() }
                group.cancelAll()
                return first
            }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                DebugLog.ingest("AppleIntelligenceSummarizer: model returned empty output")
                return nil
            }
            return trimmed
        } catch {
            DebugLog.agent("AppleIntelligenceSummarizer: model turn failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Generate a conversation title with the same prompt and cleanup as
    /// `MessageSummarizer.modelTitle` (the `chat-title-task` system prompt,
    /// `sanitizeTitle`). Returns the sanitized title, or nil when the model
    /// produced nothing usable — the caller leaves the existing title in place.
    public static func title(
        question: String,
        answer: String?,
        engine: Engine = .system,
        timeout: Duration = AppleIntelligenceSummarizer.timeout
    ) async -> String? {
        guard let prompt = MessageSummarizer.titlePrompt(question: question, answer: answer) else {
            return nil
        }
        let cleanQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        DebugLog.ingest("AppleIntelligenceSummarizer: starting title for q=\(cleanQuestion.prefix(40))...")
        guard let raw = await oneShot(
            systemPrompt: PublicPrompts.chatTitleTask,
            prompt: prompt,
            engine: engine,
            timeout: timeout) else { return nil }
        let title = MessageSummarizer.sanitizeTitle(raw)
        guard !title.isEmpty else {
            DebugLog.ingest("AppleIntelligenceSummarizer: title was unusable for q=\(cleanQuestion.prefix(40))...")
            return nil
        }
        DebugLog.ingest("AppleIntelligenceSummarizer: title for q=\(cleanQuestion.prefix(40))... → \(title)")
        return title
    }

    /// Generate a one-sentence summary with the same prompt as
    /// `MessageSummarizer.modelSummary`. Returns the summary, or nil if the
    /// model produced no non-whitespace output (the caller leaves
    /// `summary = NULL` so the message is retriable).
    public static func summary(
        text: String,
        engine: Engine = .system,
        timeout: Duration = AppleIntelligenceSummarizer.timeout
    ) async -> String? {
        guard let prompt = MessageSummarizer.summaryPrompt(text: text) else { return nil }
        DebugLog.ingest("AppleIntelligenceSummarizer: starting summary for seq=\(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))...")
        guard let summary = await oneShot(
            systemPrompt: MessageSummarizer.modelSystemPrompt,
            prompt: prompt,
            engine: engine,
            timeout: timeout) else { return nil }
        DebugLog.ingest("AppleIntelligenceSummarizer: summary for seq=\(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))... length=\(summary.count)")
        return summary
    }
}
#endif
