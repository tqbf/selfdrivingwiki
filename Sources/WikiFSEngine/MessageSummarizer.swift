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
        let pin = config.stageProviderIds["summarizer"] ?? ""
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

    /// Extract the summarizable text from an `AgentEvent` (the source for a
    /// per-message summary). Returns the text for `.assistantText` and
    /// `.result`; nil for everything else (tool/thinking/user events have no
    /// assistant summary surface). PURE.
    public static func textToSummarize(from event: AgentEvent) -> String? {
        switch event {
        case .assistantText(let text):
            return text
        case .result(_, let text):
            return text
        default:
            return nil
        }
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

        let session: SessionHandle
        do {
            session = try await backend.start(
                profile: profile,
                systemPrompt: modelSystemPrompt,
                onExit: { _ in })
        } catch {
            DebugLog.agent("MessageSummarizer.modelSummary: start failed: \(error.localizedDescription)")
            return nil
        }

        // Send one turn + collect assistant text. Mirror ACPExtractionClient's
        // collection: append .assistantText, take .result as fallback.
        let prompt = "Summarize this in one sentence:\n\n\(cleanText)"
        var collected = ""
        var turnError: String?
        let stream = await backend.send(TurnInput(userText: prompt), into: session)
        for await event in stream {
            switch event {
            case .assistantText(let chunk):
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
            DebugLog.agent("MessageSummarizer.modelSummary: turn failed: \(turnError)")
            return nil
        }

        let trimmed = collected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            DebugLog.ingest("MessageSummarizer: model returned empty output for seq=\(cleanText.prefix(40))...")
            return nil
        }
        DebugLog.ingest("MessageSummarizer: model summary for seq=\(cleanText.prefix(40))... length=\(trimmed.count)")
        return trimmed
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
        resolveCommand: (AgentProvider) -> [String]? = { provider in
            guard let command = provider.command, let exe = command.first else {
                return nil
            }
            if exe == "bun", let bundled = AgentLauncher.bundledHelperPath("bun") {
                return [bundled] + Array(command.dropFirst())
            }
            switch PathPreflight.resolveOnLoginShell(executable: ShellArgv.expandTilde(exe)) {
            case .found(let path):
                return [path] + Array(command.dropFirst())
            case .missing:
                return nil
            }
        }
    ) -> BackendProfile? {
        // Read the pin DIRECTLY — never `provider(forStage:)` (chat-summary
        // plan §5.1 invariant). This method is only called after the caller has
        // confirmed model mode, but the guard is here too for defense in depth.
        guard let pinnedId = config.stageProviderIds["summarizer"],
              !pinnedId.isEmpty,
              let provider = config.provider(id: pinnedId),
              provider.enabled else {
            return nil
        }

        guard let resolvedCommand = resolveCommand(provider) else {
            DebugLog.agent("MessageSummarizer.resolveProfile: command not resolved for provider=\(provider.id)")
            return nil
        }

        let apiKey = credentialStore.apiKey(forProvider: provider.id)
        // Read the stage's model id via modelId(forStage:) — this is safe now
        // because we already confirmed the pin is non-empty above. The fallback
        // is the provider's selectedModelId.
        let selectedModelId = config.modelId(forStage: "summarizer")

        let hints = AgentBackendFactory.providerHints(
            provider: provider,
            resolvedCommand: resolvedCommand,
            apiKey: apiKey,
            selectedModelId: selectedModelId)

        return BackendProfile(
            providerHints: hints,
            scratchDirectory: FileManager.default.temporaryDirectory,
            isReadOnly: true)
    }
}
#endif
