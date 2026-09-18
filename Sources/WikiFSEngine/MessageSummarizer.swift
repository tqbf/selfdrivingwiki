#if os(macOS)
import Foundation
import WikiFSCore

/// The per-message summary service (chat-summary plan §4).
///
/// Produces a one-line cached summary for a single assistant chat message. Three
/// modes, selected by the user via the `"summarizer"` stage pin in
/// `AgentProvidersConfig`:
///
/// - **Default** (empty/absent `stageProviderIds["summarizer"]`): pure first-
///   sentence truncation via `ChatSummary.summaryExtract`. Zero model compute.
/// - **Model** (non-empty pin other than the reserved Apple Intelligence id):
///   a one-shot ACP session that asks the pinned provider+model for a
///   one-sentence summary.
/// - **Apple Intelligence** (pin == `ProviderID.appleIntelligence`): a one-shot
///   in-process Foundation Models call (`AppleIntelligenceSummarizer`) with the
///   same prompts and cleanup as the Model mode. No subprocess, scratch world,
///   lease, or credential.
///
/// **⚠ Mode encoding invariant (chat-summary plan §5.1):** the mode decision
/// gates STRICTLY on `config.stageProviderIds["summarizer"]`. NEVER
/// call `config.provider(forStage: "summarizer")` for the mode decision — it is
/// non-optional and falls back to the global default provider
/// (`AgentProvidersConfig.swift:239-246`), so it ALWAYS reports a provider and
/// would wrongly force every message through the model path. The Apple
/// Intelligence pin is worse than most there: it names no configured provider,
/// so `provider(forStage:)` would silently return the global default and the
/// mode would be misread as Model-with-wrong-backend.
///
/// **Test seam:** the model path's `AgentBackend` is INJECTED so the logic is
/// unit-testable end-to-end with `FakeAgentBackend` (chat-summary plan §4.3 +
/// AC.4). The production caller is `AgentProviderRuntime.modelSummary` /
/// `modelTitle`, which builds the read-only sandboxed profile from the
/// snapshot's own scratch (`LLMSandboxScratch`, issue #1276); tests pass a
/// `FakeAgentBackend` + a simple `BackendProfile`.
public enum MessageSummarizer {

    /// The configured summarizer mode for a given provider config. Derived
    /// STRICTLY from `stageProviderIds["summarizer"]` (chat-summary plan §5.1).
    public enum Mode: Sendable, Equatable {
        /// First-sentence truncation via `ChatSummary.summaryExtract` — no model
        /// call. Selected when `stageProviderIds["summarizer"]` is empty/absent.
        case defaultTruncation
        /// LLM summarization via a pinned provider+model. Selected when
        /// `stageProviderIds["summarizer"]` is non-empty and is not the
        /// reserved Apple Intelligence id.
        case model
        /// On-device Apple Intelligence (Foundation Models) via
        /// `AppleIntelligenceSummarizer`. Selected when the pin equals
        /// `ProviderID.appleIntelligence` — a reserved built-in that names no
        /// configured provider.
        case appleIntelligence
    }

    /// Derive the configured summarizer mode STRICTLY from the stage pin
    /// (chat-summary plan §5.1). This is the ONLY correct way to decide Default
    /// vs Model vs Apple Intelligence — never use
    /// `provider(forStage: "summarizer")` for this decision (see the invariant
    /// in this type's doc comment).
    public static func mode(for config: AgentProvidersConfig) -> Mode {
        guard let pin = config.stageProviderIds["summarizer"], !pin.rawValue.isEmpty else {
            return .defaultTruncation
        }
        return pin == ProviderID.appleIntelligence ? .appleIntelligence : .model
    }

    /// The system prompt for the one-shot summarization session (model mode).
    /// Kept short — the user turn carries the content to summarize.
    static let modelSystemPrompt = """
    You are a concise summarizer. Summarize the user's content in a single clear sentence. \
    Output ONLY the summary sentence — no preamble, no quotes, no code fences.
    """

    /// The user-turn prompt for a chat title. Shared by the ACP model path and
    /// the Apple Intelligence path so both send byte-identical turns. PURE.
    /// Returns nil when the question has no non-whitespace content — the
    /// caller skips the model call entirely.
    static func titlePrompt(question: String, answer: String?) -> String? {
        let cleanQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanQuestion.isEmpty else { return nil }
        let excerpt = String(
            (answer ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(1_200))
        if excerpt.isEmpty {
            return "Question:\n\(cleanQuestion)\n\nTitle:"
        }
        return "Question:\n\(cleanQuestion)\n\nAssistant reply (may be truncated):\n\(excerpt)\n\nTitle:"
    }

    /// The user-turn prompt for a one-sentence summary. Shared by the ACP
    /// model path and the Apple Intelligence path. PURE. Returns nil for
    /// empty/whitespace input.
    static func summaryPrompt(text: String) -> String? {
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanText.isEmpty else { return nil }
        return "Summarize this in one sentence:\n\n\(cleanText)"
    }

    /// Produce a default-truncation summary (no model call). Reuses
    /// `ChatSummary.summaryExtract(from:maxLength:)` verbatim so the Default
    /// summarizer is byte-identical to the existing on-the-fly outline
    /// extraction (chat-summary plan §4.2). Pure + cheap; safe to run inline.
    ///
    /// Returns the empty string for empty/whitespace input; callers skip the
    /// write-back when the extract is empty.
    public static func defaultSummary(for text: String) -> String {
        ChatSummary.summaryExtract(from: text, maxLength: 200)
    }

    // MARK: - Chat titles (summarizer-stage model)

    /// Sanitize a model-produced chat title into sidebar-safe text: keep the
    /// first non-empty line, strip wrapping quotes / code fences / a "Title:"
    /// label / trailing periods (repeatedly, so `".`-style stacks unwind), and
    /// cap the length. PURE. Returns the empty string when nothing usable
    /// remains.
    public static func sanitizeTitle(_ raw: String, maxLength: Int = 80) -> String {
        var title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let firstLine = title.split(whereSeparator: \.isNewline).first {
            title = firstLine.trimmingCharacters(in: .whitespaces)
        }
        let opening = ["```", "\"", "'", "\u{201C}", "\u{2018}"]
        let closing = ["```", "\"", "'", "\u{201D}", "\u{2019}"]
        // Bounded fixpoint: `"...".` needs quote-then-period-then-quote strips.
        for _ in 0..<4 {
            var changed = false
            if title.lowercased().hasPrefix("title:") {
                title = String(title.dropFirst("title:".count))
                changed = true
            }
            for fence in opening where title.hasPrefix(fence) {
                title.removeFirst(fence.count)
                changed = true
            }
            for fence in closing where title.hasSuffix(fence) {
                title.removeLast(fence.count)
                changed = true
            }
            if title.hasSuffix(".") {
                title.removeLast()
                changed = true
            }
            title = title.trimmingCharacters(in: .whitespaces)
            if !changed { break }
        }
        guard title.count > maxLength else { return title }
        return String(title.prefix(maxLength)).trimmingCharacters(in: .whitespaces)
    }

    /// Generate a conversation title from the opening question and the
    /// assistant's first reply (the summary provider refines an untouched
    /// provisional title; empty-title rows are legacy recovery). One-shot
    /// summarizer-stage session with the `chat-title-task` system prompt;
    /// same mechanics as `modelSummary`.
    ///
    /// - Returns: the sanitized title, or nil when the model produced nothing
    ///   usable — the caller leaves the existing title in place.
    public static func modelTitle(
        question: String,
        answer: String?,
        backend: any AgentBackend,
        profile: BackendProfile
    ) async -> String? {
        guard let prompt = titlePrompt(question: question, answer: answer) else { return nil }
        DebugLog.ingest("MessageSummarizer: starting model title for q=\(question.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))...")
        guard let raw = await oneShotReply(
            systemPrompt: PublicPrompts.chatTitleTask,
            prompt: prompt,
            backend: backend,
            profile: profile) else { return nil }
        let title = sanitizeTitle(raw)
        guard !title.isEmpty else {
            DebugLog.ingest("MessageSummarizer: model title was unusable for q=\(question.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))...")
            return nil
        }
        DebugLog.ingest("MessageSummarizer: model title for q=\(question.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))... → \(title)")
        return title
    }

    /// One backend session, ONE turn, collected assistant text (`.result`
    /// fallback), session always cancelled. The shared core of `modelSummary`
    /// and `modelTitle`. Returns nil on start/turn failure or empty output.
    private static func oneShotReply(
        systemPrompt: String,
        prompt: String,
        backend: any AgentBackend,
        profile: BackendProfile
    ) async -> String? {
        let session: SessionHandle
        do {
            session = try await backend.start(
                profile: profile,
                systemPrompt: systemPrompt,
                onExit: { _ in })
        } catch {
            DebugLog.agent("MessageSummarizer.oneShotReply: start failed: \(error.localizedDescription)")
            return nil
        }

        var collected = ""
        var turnError: String?
        let stream = await backend.send(TurnInput(userText: prompt), into: session)
        for await event in stream {
            switch event {
            case .assistantText(let chunk):
                collected += chunk
            case .assistantTextDelta(let chunk):
                collected += chunk
            case .result(let isError, let resultText):
                if isError {
                    turnError = resultText
                } else if collected.isEmpty {
                    collected = resultText
                }
            case .turnFailed(let reason):
                turnError = reason.description
            default:
                break
            }
        }

        // Always cancel — it was a one-shot session (mirrors extraction).
        await backend.cancel(session)

        if let turnError {
            DebugLog.agent("MessageSummarizer.oneShotReply: turn failed: \(turnError)")
            return nil
        }

        let trimmed = collected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            DebugLog.ingest("MessageSummarizer: model returned empty output for prompt=\(prompt.prefix(40))...")
            return nil
        }

        // The summarizer-stage backend is itself an ACP agent and may prepend
        // the known skills-budget warning to its own reply. Strip it so the
        // banner never lands in a cached summary or title; a reply that is
        // only the warning yields nothing usable.
        guard let visible = AgentPresentationPreamble.visibleText(trimmed, policy: .completeOnly) else {
            DebugLog.ingest("MessageSummarizer.oneShotReply: reply was only the known preamble")
            return nil
        }
        return visible
    }

    /// Extract the summarizable text from an `AgentEvent` (the source for a
    /// per-message summary). Returns the text for `.assistantText` and
    /// `.result`; nil for everything else (tool/thinking/user events have no
    /// assistant summary surface). PURE.
    ///
    /// ACP backends open replies with meta preambles — a skills-budget
    /// `Warning:` line, a `Thinking:` dump — which are not content. Leading
    /// preamble lines are stripped; a message that is ONLY preamble yields nil
    /// so it is never summarized and never becomes a title
    /// input.
    public static func textToSummarize(from event: AgentEvent) -> String? {
        switch event {
        case .assistantText(let text):
            return summarizableAssistantText(text)
        case .result(_, let text):
            return summarizableAssistantText(text)
        default:
            return nil
        }
    }

    /// Extract the summarizable text from a durable transcript item (v54,
    /// issue #1266 — the summarizer scans `chat_transcript_items`, not the
    /// compatibility `chat_messages` projection). Only assistant messages
    /// carry a summary surface; user/tool/notice/failure items yield nil.
    /// PURE. Mirrors `textToSummarize(from: AgentEvent)` — through the v46
    /// persistence projection an assistant transcript message IS an
    /// `.assistantText` event.
    public static func textToSummarize(from item: ChatTranscriptItem) -> String? {
        guard case .message(let message) = item, message.role == .assistant else {
            return nil
        }
        return summarizableAssistantText(message.text)
    }

    /// The summarizer's pending set: transcript items with no cached summary
    /// plus their summarizable text, paired with the durable cursor the write
    /// back targets (`updateMessageSummary`). Compute-once (AC.6) falls out of
    /// the `summary == nil` filter. PURE.
    public static func pendingSummaryTargets(
        from items: [PersistedChatTranscriptItem]
    ) -> [(cursor: ChatTranscriptCursor, text: String)] {
        var pending: [(cursor: ChatTranscriptCursor, text: String)] = []
        for persisted in items {
            guard persisted.summary == nil,
                  let text = textToSummarize(from: persisted.item),
                  !text.isEmpty else { continue }
            pending.append((cursor: persisted.cursor, text: text))
        }
        return pending
    }

    /// Drop the known skills-budget warning (via the shared
    /// `completeOnly` filter) plus leading blank / `Thinking:` lines from
    /// assistant text. PURE. Returns nil when nothing substantive remains.
    ///
    /// The `Warning:` removal is deliberately NARROWER than it used to be:
    /// only the exact known skill-description warning family is dropped.
    /// Any other `Warning:` line is content and is preserved. `Thinking:`
    /// preambles keep their separate treatment.
    static func summarizableAssistantText(_ text: String) -> String? {
        guard let withoutKnownWarning = AgentPresentationPreamble.visibleText(text, policy: .completeOnly)
        else { return nil }
        var lines = withoutKnownWarning.components(separatedBy: .newlines)
        while !lines.isEmpty {
            let line = lines[0].trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("Thinking:") {
                lines.removeFirst()
            } else {
                break
            }
        }
        let rest = lines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return rest.isEmpty ? nil : rest
    }

    /// Run a one-shot model summarization via the injected `AgentBackend`
    /// (chat-summary plan §4.3). Mirrors `ACPExtractionClient.convert`: start a
    /// session with `modelSystemPrompt`, send ONE turn, collect `.assistantText`
    /// / `.result` text, cancel the session, return the trimmed result.
    ///
    /// **Test seam:** `backend` and `profile` are both parameters so a Swift
    /// Testing case can inject a `FakeAgentBackend` with a scripted
    /// `[.assistantText("…"), .messageStop]` behavior and a simple
    /// `BackendProfile`. This drives the model path end-to-end without a real
    /// subprocess (AC.4 model half).
    ///
    /// - Returns: the summarized text, or nil if the backend produced no
    ///   non-whitespace output (the caller leaves `summary = NULL` so the
    ///   message is retriable).
    public static func modelSummary(
        text: String,
        backend: any AgentBackend,
        profile: BackendProfile
    ) async -> String? {
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanText.isEmpty, let prompt = summaryPrompt(text: text) else { return nil }

        DebugLog.ingest("MessageSummarizer: starting model mode for seq=\(cleanText.prefix(40))...")
        guard let summary = await oneShotReply(
            systemPrompt: modelSystemPrompt,
            prompt: prompt,
            backend: backend,
            profile: profile) else { return nil }
        DebugLog.ingest("MessageSummarizer: model summary for seq=\(cleanText.prefix(40))... length=\(summary.count)")
        return summary
    }

    // NOTE (issue #1276): the former `resolveProfile` helper is REMOVED. It had
    // no production caller (the active path is
    // `AgentProviderRuntime.prepareSummarization` → `backend(from:stage:)`,
    // which builds the read-only sandboxed profile from the snapshot's own
    // `LLMSandboxScratch`), and its shared-tempDirectory, unsandboxed profile
    // is exactly the shape the source audit now rejects. Tests drive the model
    // path through the runtime boundary or a fake backend + explicit profile.
}
#endif
