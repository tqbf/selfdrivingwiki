#if os(macOS)
import Testing
import Foundation
import WikiFSEngine
import WikiFSCore
@testable import WikiFSEngine
@testable import WikiFSCore

/// Tests for the per-message summary feature (plans/chat-summary.md).
///
/// Four layers:
///   - **`ChatMessageSummaryKind`** — explicit raw values + Codable round-trip
///     (guards the §4.1 explicit-raw-value fix).
///   - **`MessageSummarizer.Mode`** — the §5.1 mode-encoding invariant
///     (`stageProviderIds["summarizer"]` gates the decision, NEVER
///     `provider(forStage:)`).
///   - **Default backend** — pure truncation via `ChatSummary.summaryExtract`.
///   - **Model backend** — driven end-to-end via `FakeAgentBackend` (AC.4
///     automated model half).
///   - **Store round-trip** — `updateMessageSummary` + `chatMessages` read-back
///     on a real in-memory SQLite DB (AC.1 + AC.6).
@Suite(.timeLimit(.minutes(5)))
struct MessageSummaryTests {

    // MARK: - ChatMessageSummaryKind (§4.1 — explicit raw values)

    @Test func summaryKind_rawValues_areExplicitShortStrings() {
        // The raw values MUST be the short column forms — Swift would otherwise
        // derive them from the case names ("defaultTruncation"), breaking the
        // `summary_kind` column round-trip.
        #expect(ChatMessageSummaryKind.defaultTruncation.rawValue == "default")
        #expect(ChatMessageSummaryKind.model.rawValue == "model")
    }

    @Test func summaryKind_caseIterable_roundTripsThroughRawValue() {
        for kind in ChatMessageSummaryKind.allCases {
            let raw = kind.rawValue
            let back = ChatMessageSummaryKind(rawValue: raw)
            #expect(back == kind, "rawValue round-trip failed for \(kind)")
        }
    }

    @Test func summaryKind_decodesFromColumnLiteral() throws {
        // Decode the column-stored short string literal → the enum case. This
        // guards the explicit-raw-value fix: if the raw values were derived
        // from case names, `"default"` would decode to nil.
        let defaultData = Data("\"default\"".utf8)
        let modelData = Data("\"model\"".utf8)
        let decoder = JSONDecoder()
        #expect(try decoder.decode(ChatMessageSummaryKind.self, from: defaultData) == .defaultTruncation)
        #expect(try decoder.decode(ChatMessageSummaryKind.self, from: modelData) == .model)
    }

    @Test func summaryKind_codableRoundTrip() throws {
        // Full Codable round-trip: encode → decode → equal.
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for kind in ChatMessageSummaryKind.allCases {
            let data = try encoder.encode(kind)
            let back = try decoder.decode(ChatMessageSummaryKind.self, from: data)
            #expect(back == kind)
        }
    }

    // MARK: - Mode encoding (§5.1 — the load-bearing invariant)

    @Test func mode_emptyPin_returnsDefaultTruncation() {
        // The critical invariant: an empty/absent pin ⇒ Default (truncation,
        // no model call). NEVER use `provider(forStage:)` for this decision.
        let config = AgentProvidersConfig(providers: [
            AgentProvider(id: "claude", label: "Claude", command: ["claude"], enabled: true, isDefault: true),
        ])
        // Confirm the precondition: provider(forStage:) returns a provider
        // (the global default) EVEN when the pin is empty — that's the trap.
        #expect(config.provider(forStage: "summarizer").id == "claude")
        // And yet mode(for:) correctly reports Default because it reads
        // stageProviderIds directly, not provider(forStage:).
        #expect(MessageSummarizer.mode(for: config) == .defaultTruncation)
    }

    @Test func mode_absentPin_returnsDefaultTruncation() {
        // No "summarizer" key at all → Default.
        let config = AgentProvidersConfig(providers: [
            AgentProvider(id: "claude", label: "Claude", command: ["claude"], enabled: true, isDefault: true),
        ])
        #expect(config.stageProviderIds["summarizer"] == nil)
        #expect(MessageSummarizer.mode(for: config) == .defaultTruncation)
    }

    @Test func mode_nonEmptyPin_returnsModel() {
        // A pinned provider ⇒ Model.
        let config = AgentProvidersConfig(providers: [
            AgentProvider(id: "claude", label: "Claude", command: ["claude"], enabled: true, isDefault: true),
            AgentProvider(id: "gemini", label: "Gemini", command: ["gemini", "--acp"], enabled: true, isDefault: false),
        ]).settingStageProvider("gemini", forStage: "summarizer")
        #expect(MessageSummarizer.mode(for: config) == .model)
    }

    @Test func mode_clearedPin_returnsDefaultTruncation() {
        // Setting then clearing the pin restores Default.
        let base = AgentProvidersConfig(providers: [
            AgentProvider(id: "claude", label: "Claude", command: ["claude"], enabled: true, isDefault: true),
        ])
        let pinned = base.settingStageProvider("claude", forStage: "summarizer")
        #expect(MessageSummarizer.mode(for: pinned) == .model)
        let cleared = pinned.settingStageProvider(nil, forStage: "summarizer")
        #expect(MessageSummarizer.mode(for: cleared) == .defaultTruncation)
    }

    // MARK: - Default backend (§4.2 — pure truncation, zero model compute)

    @Test func defaultSummary_reusesChatSummaryExtract() {
        // The default backend IS ChatSummary.summaryExtract(from:maxLength: 200)
        // — byte-identical to the existing on-the-fly outline extraction.
        let text = "The page covers tire selection. It also talks about pressures."
        let expected = ChatSummary.summaryExtract(from: text, maxLength: 200)
        #expect(MessageSummarizer.defaultSummary(for: text) == expected)
    }

    @Test func defaultSummary_emptyInput_returnsEmpty() {
        #expect(MessageSummarizer.defaultSummary(for: "") == "")
        #expect(MessageSummarizer.defaultSummary(for: "   ") == "")
    }

    // MARK: - textToSummarize (event extraction)

    @Test func textToSummarize_assistantText_returnsText() {
        let event = AgentEvent.assistantText("Hello world.")
        #expect(MessageSummarizer.textToSummarize(from: event) == "Hello world.")
    }

    @Test func textToSummarize_result_returnsText() {
        let event = AgentEvent.result(isError: false, text: "The answer.")
        #expect(MessageSummarizer.textToSummarize(from: event) == "The answer.")
    }

    @Test func textToSummarize_nonAssistantEvents_returnNil() {
        #expect(MessageSummarizer.textToSummarize(from: .userText("q")) == nil)
        #expect(MessageSummarizer.textToSummarize(from: .toolUse(name: "Bash", inputSummary: "ls")) == nil)
        #expect(MessageSummarizer.textToSummarize(from: .messageStop) == nil)
    }

    // MARK: - Model backend (§4.3 — injectable AgentBackend seam, AC.4)

    @Test func modelSummary_streamsAssistantTextAsSummary() async {
        // The model half of AC.4, automated: one assistant turn in → summary
        // out via the injected FakeAgentBackend (no real subprocess).
        let backend = FakeAgentBackend(behaviors: [
            FakeSessionBehavior(events: [.assistantText("A concise summary."), .messageStop])
        ])
        let profile = BackendProfile(model: "test-model")
        let result = await MessageSummarizer.modelSummary(
            text: "Some long assistant text that needs summarizing.",
            backend: backend,
            profile: profile)
        #expect(result == "A concise summary.")
        // The backend was used exactly once (one-shot session).
        let counts = await (backend.startCount, backend.sendCount, backend.cancelCount)
        #expect(counts.0 == 1, "startCount")
        #expect(counts.1 == 1, "sendCount")
        #expect(counts.2 == 1, "cancelCount")
    }

    @Test func modelSummary_resultEventFallback() async {
        // Some agents emit everything in .result instead of streaming
        // .assistantText — modelSummary should take it as fallback (mirrors
        // ACPExtractionClient.convert).
        let backend = FakeAgentBackend(behaviors: [
            FakeSessionBehavior(events: [.result(isError: false, text: "Result-based summary."), .messageStop])
        ])
        let profile = BackendProfile()
        let result = await MessageSummarizer.modelSummary(
            text: "Content.", backend: backend, profile: profile)
        #expect(result == "Result-based summary.")
    }

    @Test func modelSummary_emptyInput_returnsNil() async {
        let backend = FakeAgentBackend(behaviors: [])
        let profile = BackendProfile()
        let result = await MessageSummarizer.modelSummary(
            text: "   ", backend: backend, profile: profile)
        #expect(result == nil)
        // Should not even start a session for empty input.
        let starts = await backend.startCount
        #expect(starts == 0)
    }

    @Test func modelSummary_errorTurn_returnsNil() async {
        // A .turnFailed or .result(isError: true) → nil (the caller leaves
        // summary = NULL so the message is retriable).
        let backend = FakeAgentBackend(behaviors: [
            FakeSessionBehavior(events: [.result(isError: true, text: "boom"), .messageStop])
        ])
        let profile = BackendProfile()
        let result = await MessageSummarizer.modelSummary(
            text: "Content.", backend: backend, profile: profile)
        #expect(result == nil)
    }

    @Test func modelSummary_startFailure_returnsNil() async {
        // If backend.start throws, modelSummary returns nil (no crash).
        let backend = FakeAgentBackend(behaviors: [
            FakeSessionBehavior(shouldFailOnStart: true)
        ])
        let profile = BackendProfile()
        let result = await MessageSummarizer.modelSummary(
            text: "Content.", backend: backend, profile: profile)
        #expect(result == nil)
    }

    // MARK: - resolveProfile (production backend wiring, §4.3)

    @Test func resolveProfile_emptyPin_returnsNil() {
        // Defense in depth: resolveProfile reads the pin directly and bails
        // when it's empty — even though the caller should have confirmed model
        // mode before calling.
        let config = AgentProvidersConfig(providers: [
            AgentProvider(id: "claude", label: "Claude", command: ["claude"], enabled: true, isDefault: true),
        ])
        let creds = InMemoryACPCredentialStore()
        let profile = MessageSummarizer.resolveProfile(
            config: config,
            credentialStore: creds,
            resolveCommand: { _ in ["/usr/bin/true"] })
        #expect(profile == nil)
    }

    @Test func resolveProfile_pinnedProvider_buildsHints() throws {
        let config = AgentProvidersConfig(providers: [
            AgentProvider(id: "claude", label: "Claude", command: ["claude"], enabled: true, isDefault: true),
        ]).settingStageProvider("claude", forStage: "summarizer")
        let creds = InMemoryACPCredentialStore()
        try creds.setAPIKey("secret-key", forProvider: "claude")
        let profile = MessageSummarizer.resolveProfile(
            config: config,
            credentialStore: creds,
            resolveCommand: { _ in ["/usr/bin/claude"] })
        #expect(profile != nil)
        // The provider hint carries the resolved executable.
        #expect(profile?.providerHints[HintKey.acpAgentPath.rawValue] == "/usr/bin/claude")
        // The API key is threaded into hints.
        #expect(profile?.providerHints[HintKey.acpAgentApiKey.rawValue] == "secret-key")
    }

    @Test func resolveProfile_unresolvableCommand_returnsNil() {
        let config = AgentProvidersConfig(providers: [
            AgentProvider(id: "claude", label: "Claude", command: ["claude"], enabled: true, isDefault: true),
        ]).settingStageProvider("claude", forStage: "summarizer")
        let profile = MessageSummarizer.resolveProfile(
            config: config,
            credentialStore: InMemoryACPCredentialStore(),
            resolveCommand: { _ in nil })  // command not resolved
        #expect(profile == nil)
    }

    // MARK: - Store round-trip (AC.1 + AC.6, integration)

    @Test func freshDB_isAtSchemaVersion41() throws {
        // AC.1: a fresh DB is at user_version = 41.
        let store = try TestStoreFactory.inMemory()
        let version = Int(store.pragmaValue("user_version")) ?? 0
        #expect(version == 41)
    }

    @Test func summaryNullForNewMessages() throws {
        // AC.1 (read side): newly-appended messages have nil summary fields.
        let store = try TestStoreFactory.inMemory()
        let chat = try store.createChat(kind: .edit, title: "Chat")
        _ = try store.appendChatMessages(
            chatID: chat.id,
            events: [.userText("q"), .assistantText("Some answer.")])
        let messages = try store.chatMessages(chatID: chat.id)
        #expect(messages.count == 2)
        for msg in messages {
            #expect(msg.summary == nil, "summary should be nil for \(msg.event)")
            #expect(msg.summaryKind == nil)
            #expect(msg.summaryAt == nil)
        }
    }

    @Test func updateMessageSummary_roundTrips() throws {
        // AC.6 (compute-once path): write a summary, read it back — cached.
        let store = try TestStoreFactory.inMemory()
        let chat = try store.createChat(kind: .edit, title: "Chat")
        let inserted = try store.appendChatMessages(
            chatID: chat.id,
            events: [.assistantText("Long answer.")])
        let target = try #require(inserted.first)
        try store.updateMessageSummary(
            chatID: chat.id, messageID: target.id,
            summary: "Cached one-liner.", kind: .model)

        let after = try store.chatMessages(chatID: chat.id)
        let updated = try #require(after.first { $0.id == target.id })
        #expect(updated.summary == "Cached one-liner.")
        #expect(updated.summaryKind == .model)
        #expect(updated.summaryAt != nil)
    }

    @Test func summaryWrittenForOneMessage_doesNotAffectOthers() throws {
        // Writing a summary for one message leaves others nil (per-message
        // granularity, not per-chat).
        let store = try TestStoreFactory.inMemory()
        let chat = try store.createChat(kind: .edit, title: "Chat")
        let inserted = try store.appendChatMessages(
            chatID: chat.id,
            events: [.assistantText("first."), .assistantText("second.")])
        try store.updateMessageSummary(
            chatID: chat.id, messageID: inserted[0].id,
            summary: "first summary.", kind: .defaultTruncation)

        let after = try store.chatMessages(chatID: chat.id)
        #expect(after[0].summary == "first summary.")
        #expect(after[1].summary == nil)
        #expect(after[1].summaryKind == nil)
    }

    @Test func idempotency_alreadySummarized_isSkippedByFilter() throws {
        // AC.6 (cache short-circuit): the summarizePendingMessages filter
        // (`msg.summary == nil`) skips already-summarized rows. Verify the
        // round-trip supports this: after a write, the message's summary is
        // non-nil so it would be filtered out on the next pass.
        let store = try TestStoreFactory.inMemory()
        let chat = try store.createChat(kind: .edit, title: "Chat")
        let inserted = try store.appendChatMessages(
            chatID: chat.id, events: [.assistantText("text.")])
        try store.updateMessageSummary(
            chatID: chat.id, messageID: inserted[0].id,
            summary: "done.", kind: .defaultTruncation)

        // Re-read: the message now has a non-nil summary, so a filter like
        // `messages.filter { $0.summary == nil }` excludes it.
        let messages = try store.chatMessages(chatID: chat.id)
        let pending = messages.filter { $0.summary == nil }
        #expect(pending.isEmpty, "already-summarized message should be filtered out")
    }
}
#endif // os(macOS)
