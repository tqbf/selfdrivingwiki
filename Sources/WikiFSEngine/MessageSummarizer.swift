#if os(macOS)
import Foundation
import WikiFSCore

/// The per-message summary service (chat-summary plan §4).
///
/// Produces a one-line cached summary for a single assistant chat message. Two
/// modes, selected by the user via the `"summarizer"` stage pin in
/// `AgentProvidersConfig`:
///
/// - **Default** (empty/absent `stageProviderIds["summarizer"]`): pure first-
///   sentence truncation via `ChatSummary.summaryExtract`. Zero model compute.
/// - **Model** (non-empty `stageProviderIds["summarizer"]`): a one-shot ACP
///   session that asks the pinned provider+model for a one-sentence summary.
///
/// **⚠ Mode encoding invariant (chat-summary plan §5.1):** the Default-vs-Model
/// decision gates STRICTLY on `config.stageProviderIds["summarizer"]`. NEVER
/// call `config.provider(forStage: "summarizer")` for the mode decision — it is
/// non-optional and falls back to the global default provider
/// (`AgentProvidersConfig.swift:239-246`), so it ALWAYS reports a provider and
/// would wrongly force every message through the model path.
///
/// **Test seam:** the model path's `AgentBackend` is INJECTED so the logic is
/// unit-testable end-to-end with `FakeAgentBackend` (chat-summary plan §4.3 +
/// AC.4). The production caller constructs the backend via
/// `AgentBackendFactory.makeBackend(policy: .bypass)` and the profile via
/// `resolveProfile`; tests pass a `FakeAgentBackend` + a simple `BackendProfile`.
public enum MessageSummarizer {

    /// The configured summarizer mode for a given provider config. Derived
    /// STRICTLY from `stageProviderIds["summarizer"]` (chat-summary plan §5.1).
    public enum Mode: Sendable, Equatable {
        /// First-sentence truncation via `ChatSummary.summaryExtract` — no model
        /// call. Selected when `stageProviderIds["summarizer"]` is empty/absent.
        case defaultTruncation
        /// LLM summarization via a pinned provider+model. Selected when
        /// `stageProviderIds["summarizer"]` is non-empty.
        case model
    }

    /// Derive the configured summarizer mode STRICTLY from the stage pin
    /// (chat-summary plan §5.1). This is the ONLY correct way to decide Default
    /// vs Model — never use `provider(forStage: "summarizer")` for this
    /// decision (see the invariant in this type's doc comment).
    public static func mode(for config: AgentProvidersConfig) -> Mode {
        let pin = config.stageProviderIds["summarizer"]?.rawValue ?? ""
        return pin.isEmpty ? .defaultTruncation : .model
    }

    /// The system prompt for the one-shot summarization session (model mode).
    /// Kept short — the user turn carries the content to summarize.
    static let modelSystemPrompt = """
    You are a concise summarizer. Summarize the user's content in a single clear sentence. \
    Output ONLY the summary sentence — no preamble, no quotes, no code fences.
    """

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
    /// assistant's first reply (chat identity plan: the summary provider names
    /// an untouched empty-title chat). One-shot summarizer-stage session with
    /// the `chat-title-task` system prompt; same mechanics as `modelSummary`.
    ///
    /// - Returns: the sanitized title, or nil when the model produced nothing
    ///   usable — the caller leaves the existing title in place.
    public static func modelTitle(
        question: String,
        answer: String?,
        backend: any AgentBackend,
        profile: BackendProfile
    ) async -> String? {
        let cleanQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanQuestion.isEmpty else { return nil }
        let excerpt = String(
            (answer ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(1_200))
        let prompt: String
        if excerpt.isEmpty {
            prompt = "Question:\n\(cleanQuestion)\n\nTitle:"
        } else {
            prompt = "Question:\n\(cleanQuestion)\n\nAssistant reply (may be truncated):\n\(excerpt)\n\nTitle:"
        }
        DebugLog.ingest("MessageSummarizer: starting model title for q=\(cleanQuestion.prefix(40))...")
        guard let raw = await oneShotReply(
            systemPrompt: PublicPrompts.chatTitleTask,
            prompt: prompt,
            backend: backend,
            profile: profile) else { return nil }
        let title = sanitizeTitle(raw)
        guard !title.isEmpty else {
            DebugLog.ingest("MessageSummarizer: model title was unusable for q=\(cleanQuestion.prefix(40))...")
            return nil
        }
        DebugLog.ingest("MessageSummarizer: model title for q=\(cleanQuestion.prefix(40))... → \(title)")
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
        return trimmed
    }

    /// Extract the summarizable text from an `AgentEvent` (the source for a
    /// per-message summary). Returns the text for `.assistantText` and
    /// `.result`; nil for everything else (tool/thinking/user events have no
    /// assistant summary surface). PURE.
    ///
    /// ACP backends open replies with meta preambles — a skills-budget
    /// `Warning:` line, a `Thinking:` dump — which are not content. Leading
    /// preamble lines are stripped; a message that is ONLY preamble yields nil
    /// so it is never summarized and never becomes `chats.summary` or a title
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

    /// Drop leading blank / `Warning:` / `Thinking:` lines from assistant
    /// text. PURE. Returns nil when nothing substantive remains.
    static func summarizableAssistantText(_ text: String) -> String? {
        var lines = text.components(separatedBy: .newlines)
        while !lines.isEmpty {
            let line = lines[0].trimmingCharacters(in: .whitespaces)
            if line.isEmpty
                || line.hasPrefix("Warning:")
                || line.hasPrefix("Thinking:") {
                lines.removeFirst()
            } else {
                break
            }
        }
        let rest = lines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return rest.isEmpty ? nil : rest
    }

    /// The message whose summary doubles as the CHAT-level summary
    /// (`chats.summary`, issue #411): the FIRST summarizable message in the
    /// chat. PURE — `messages` must be in store order.
    ///
    /// `chats.summary` is not a summary of the whole conversation; it is the
    /// gist of the opening answer, shown as the chats-list row subtitle. Rather
    /// than compute it separately (the pre-#411-unification design, which always
    /// truncated regardless of the summarizer mode), both hosts now MIRROR the
    /// first message's cached summary into the chat row. That gives one writer,
    /// one condensing policy, and — in Model mode — zero extra model calls: the
    /// chat summary is a copy of a per-message summary that was computed anyway.
    ///
    /// Returns nil when no message has summarizable text.
    public static func chatSummaryMessageID(in messages: [ChatMessage]) -> PageID? {
        messages.first { msg in
            guard let text = textToSummarize(from: msg.event) else { return false }
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }?.id
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
        guard !cleanText.isEmpty else { return nil }

        DebugLog.ingest("MessageSummarizer: starting model mode for seq=\(cleanText.prefix(40))...")
        guard let summary = await oneShotReply(
            systemPrompt: modelSystemPrompt,
            prompt: "Summarize this in one sentence:\n\n\(cleanText)",
            backend: backend,
            profile: profile) else { return nil }
        DebugLog.ingest("MessageSummarizer: model summary for seq=\(cleanText.prefix(40))... length=\(summary.count)")
        return summary
    }

    /// Build the `BackendProfile` for the summarizer stage from the user's
    /// `AgentProvidersConfig` (chat-summary plan §4.3, mirroring
    /// `ACPExtractionClient.resolveProvider`). Resolves the pinned summarizer
    /// provider + its PATH-resolved command + Keychain API key + the stage's
    /// model id, then builds the provider hints via
    /// `AgentBackendFactory.providerHints`.
    ///
    /// Returns nil when:
    /// - the stage pin is empty/absent (caller should not enter model mode),
    /// - the pinned provider is missing/disabled,
    /// - the command can't be PATH-resolved.
    ///
    /// PURE w.r.t. config + credential state (the `resolveCommand` closure is
    /// injectable for tests; the default mirrors `ACPExtractionClient`).
    public static func resolveProfile(
        config: AgentProvidersConfig,
        credentialStore: any ACPCredentialStore,
        searchPath: String? = nil,
        resolveCommand: ((AgentProvider) -> [String]?)? = nil
    ) -> BackendProfile? {
        let commandResolver = resolveCommand ?? { provider in
            AgentLauncher.resolveCommand(for: provider, searchPath: searchPath)
        }
        // Read the pin DIRECTLY — never `provider(forStage:)` (chat-summary
        // plan §5.1 invariant). This method is only called after the caller has
        // confirmed model mode, but the guard is here too for defense in depth.
        guard let pinnedId = config.stageProviderIds["summarizer"],
              !pinnedId.rawValue.isEmpty,
              let provider = config.provider(id: pinnedId),
              provider.enabled else {
            return nil
        }

        guard let resolvedCommand = commandResolver(provider) else {
            DebugLog.agent("MessageSummarizer.resolveProfile: command not resolved for provider=\(provider.id)")
            return nil
        }

        let apiKey = credentialStore.apiKey(forProvider: provider.id.rawValue)
        // Read the stage's model id via modelId(forStage:) — this is safe now
        // because we already confirmed the pin is non-empty above. The fallback
        // is the provider's selectedModelId.
        let selectedModelId = config.modelId(forStage: "summarizer")

        let hints = AgentBackendFactory.providerHints(
            provider: provider,
            resolvedCommand: resolvedCommand,
            apiKey: apiKey,
            selectedModelId: selectedModelId?.rawValue)

        return BackendProfile(
            providerHints: hints,
            scratchDirectory: FileManager.default.temporaryDirectory,
            isReadOnly: true)
    }
}
#endif
