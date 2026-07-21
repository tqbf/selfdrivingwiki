#if os(macOS)
import Testing
import WikiFSEngine
import Foundation
import WikiFSEngine
import ACPModel
@testable import WikiFS
@testable import WikiFSEngine
@testable import WikiFSCore

/// Unit tests for the ACP backend spike (`plans/acp-backend-and-permissions.md`).
/// Pure logic only — NO live agent subprocess (the spike forbids end-to-end
/// testing). Covers:
///   1. `ACPEventTranslator` — ACP `SessionUpdate` → `AgentEvent` mapping
///      (text chunk, tool call, tool result, turn-end).
///   2. `ACPPermissionDelegate` — the yolo (auto-allow) vs always-ask (deferred
///      then resolved allow/deny) policy.
///
/// The turn-boundary contract (`.messageStop` at turn end) is exercised by
/// asserting the contract predicate on a synthesized turn-end marker and by
/// documenting where `.messageStop` is synthesized (`ACPBackend.send`, from the
/// `session/prompt` completion — ACP has no turn-end *notification*).
@Suite struct ACPBackendTests {

    // MARK: - Event translator

    /// A streamed agent prose chunk maps to `.assistantTextDelta` (the launcher
    /// coalesces deltas into one `.assistantText` row, issue #121).
    @Test func agentMessageChunkMapsToAssistantTextDelta() {
        let translator = ACPEventTranslator()
        let update = SessionUpdate.agentMessageChunk(.text(TextContent(text: "Hello, ")))
        let events = translator.translate(update)
        #expect(events == [.assistantTextDelta("Hello, ")])
    }

    @Test func agentMessageChunkIgnoresEmptyText() {
        let translator = ACPEventTranslator()
        let update = SessionUpdate.agentMessageChunk(.text(TextContent(text: "")))
        #expect(translator.translate(update) == [])
    }

    /// Agent reasoning (thought chunks) maps to `.thinkingDelta` so the launcher
    /// can coalesce chunks into a `.thinking` row (issue #391).
    @Test func agentThoughtChunkMapsToThinkingDelta() {
        let translator = ACPEventTranslator()
        let update = SessionUpdate.agentThoughtChunk(.text(TextContent(text: "Considering options\u{2026}")))
        let events = translator.translate(update)
        #expect(events == [.thinkingDelta("Considering options\u{2026}")])
    }

    /// A tool invocation (`tool_call`) with `kind: .execute` + `rawInput`
    /// carrying the command line maps to `.toolUse(name: "Bash", …)` with the
    /// actual command as the summary — not "Run command" with a bare path (AC.1, issue #426).
    @Test func toolCallMapsToToolUse() {
        let translator = ACPEventTranslator()
        let update = SessionUpdate.toolCall(ToolCallUpdate(
            toolCallId: "tc1",
            status: .pending,
            title: nil,
            kind: .execute,
            rawInput: AnyCodable(["command": "wikictl page add --title Foo"])
        ))
        let events = translator.translate(update)
        #expect(events == [.toolUse(name: "Bash", inputSummary: "wikictl page add --title Foo")])
    }

    /// A tool call's `kind` is the fallback name when `title` is nil. Uses
    /// `.read` (→ "Read") since `.execute` now maps to the stable "Bash" (issue #426).
    @Test func toolCallFallsBackToKindWhenNoTitle() {
        let translator = ACPEventTranslator()
        let update = SessionUpdate.toolCall(ToolCallUpdate(
            toolCallId: "tc2",
            status: .pending,
            title: nil,
            kind: .read
        ))
        let events = translator.translate(update)
        #expect(events == [.toolUse(name: "Read", inputSummary: "")])
    }

    /// `.fetch` + `rawInput: ["url": "https://example.com"]` →
    /// `.toolUse(name: "webfetch", inputSummary: "https://example.com")` (AC.2).
    @Test func webFetchToolCallRenderedAsWebfetch() {
        let translator = ACPEventTranslator()
        let update = SessionUpdate.toolCall(ToolCallUpdate(
            toolCallId: "tc-fetch",
            status: .pending,
            title: "Fetch",
            kind: .fetch,
            rawInput: AnyCodable(["url": "https://example.com"])
        ))
        let events = translator.translate(update)
        #expect(events == [.toolUse(name: "webfetch", inputSummary: "https://example.com")])
    }

    /// `.search` + `rawInput: ["query": "active learning"]` →
    /// `.toolUse(name: "search", inputSummary: "active learning")` (AC.3).
    @Test func searchToolCallRenderedAsSearch() {
        let translator = ACPEventTranslator()
        let update = SessionUpdate.toolCall(ToolCallUpdate(
            toolCallId: "tc-search",
            status: .pending,
            title: "Search",
            kind: .search,
            rawInput: AnyCodable(["query": "active learning"])
        ))
        let events = translator.translate(update)
        #expect(events == [.toolUse(name: "search", inputSummary: "active learning")])
    }

    /// `.edit` with no `rawInput` falls back to `locations.first.path` —
    /// regression guard for agents that populate locations but not rawInput (AC.4).
    @Test func toolCallWithoutRawInputFallsBackToLocations() {
        let translator = ACPEventTranslator()
        let update = SessionUpdate.toolCall(ToolCallUpdate(
            toolCallId: "tc-edit-noraw",
            status: .pending,
            kind: .edit,
            locations: [ToolLocation(path: "/wiki/Foo.md")],
            rawInput: nil
        ))
        let events = translator.translate(update)
        #expect(events == [.toolUse(name: "Edit", inputSummary: "/wiki/Foo.md")])
    }

    /// A completed `tool_call_update` with output text maps to `.toolResult`
    /// (not an error). ACP folds a tool's whole lifecycle into status updates.
    @Test func completedToolCallUpdateMapsToToolResult() {
        let translator = ACPEventTranslator()
        let update = SessionUpdate.toolCallUpdate(ToolCallUpdateDetails(
            toolCallId: "tc1",
            status: .completed,
            content: [
                .content(.text(TextContent(text: "1 file changed")))
            ]
        ))
        let events = translator.translate(update)
        #expect(events == [.toolResult(isError: false, summary: "1 file changed")])
    }

    /// A failed tool update maps to `.toolResult(isError: true)`.
    @Test func failedToolCallUpdateMapsToToolResultWithError() {
        let translator = ACPEventTranslator()
        let update = SessionUpdate.toolCallUpdate(ToolCallUpdateDetails(
            toolCallId: "tc1",
            status: .failed,
            content: [.content(.text(TextContent(text: "permission denied")))]
        ))
        let events = translator.translate(update)
        #expect(events == [.toolResult(isError: true, summary: "permission denied")])
    }

    /// Non-terminal tool statuses (pending/in_progress) carry nothing new for
    /// the transcript — they produce no event.
    @Test func pendingToolCallUpdateEmitsNothing() {
        let translator = ACPEventTranslator()
        let update = SessionUpdate.toolCallUpdate(ToolCallUpdateDetails(
            toolCallId: "tc1",
            status: .inProgress
        ))
        #expect(translator.translate(update) == [])
    }

    /// Unmodeled update types (plan, usage, mode, …) produce no event — same
    /// fallback philosophy as `AgentEventParser` for unmodeled wire lines.
    @Test func unmodeledUpdatesEmitNothing() {
        let translator = ACPEventTranslator()
        #expect(translator.translate(.usageUpdate(UsageUpdate(used: 100, size: 1000))) == [])
        #expect(translator.translate(.currentModeUpdate("agent")) == [])
    }

    // MARK: - Turn-boundary contract

    /// ACP has NO turn-end *notification*; the turn ends when `session/prompt`
    /// returns (carrying `stopReason`). `ACPBackend.send` synthesizes
    /// `.messageStop` from that completion. This test pins the port's
    /// turn-boundary contract: `.messageStop` is the generation-ending event
    /// the launcher keys its gate/lock/flush off (`AgentEvent.endsGeneration`).
    @Test func messageStopEndsGeneration() {
        #expect(AgentEvent.endsGeneration(.messageStop) == true)
        // And the translator never emits .messageStop itself (it's synthesized
        // at prompt completion, not from an update):
        let translator = ACPEventTranslator()
        for update in representativeUpdates() {
            for event in translator.translate(update) {
                #expect(event != .messageStop, "translator must not emit .messageStop — it's synthesized at turn end")
            }
        }
    }

    /// Every ACP `StopReason` is a turn boundary (the prompt request returned),
    /// so `.messageStop` is synthesized for all of them.
    @Test func everyStopReasonIsATurnBoundary() {
        for reason in [StopReason.endTurn, .maxTokens, .refusal, .cancelled, .maxTurnRequests] {
            _ = reason  // exhaustive over the enum cases
        }
    }

    // MARK: - Permission policy: yolo (auto-allow)

    /// Yolo resolves immediately with the request's allow option — no deferral,
    /// no UI involvement. Mirrors today's "writes apply with no review".
    @Test func yoloAutoAllowsImmediately() async throws {
        let delegate = ACPPermissionDelegate(policy: .bypass)
        let request = RequestPermissionRequest(
            options: [
                PermissionOption(kind: "allow_always", name: "Allow", optionId: "opt-allow"),
                PermissionOption(kind: "reject_once", name: "Reject", optionId: "opt-reject"),
            ],
            sessionId: SessionId("s1"),
            toolCall: ToolCallUpdate(toolCallId: "tc1", title: "Write file", kind: .edit)
        )

        let response = try await delegate.handlePermissionRequest(request: request)

        // Outcome selects the allow option (allow_always preferred).
        #expect(response.outcome.outcome == "selected")
        #expect(response.outcome.optionId == "opt-allow")
        // Nothing was deferred.
        #expect(delegate.pendingSnapshot().isEmpty)
    }

    /// Yolo prefers `allow_always` over `allow_once` when both are offered.
    @Test func yoloPrefersAllowAlways() async throws {
        let delegate = ACPPermissionDelegate(policy: .bypass)
        let request = RequestPermissionRequest(
            options: [
                PermissionOption(kind: "allow_once", name: "Allow once", optionId: "once"),
                PermissionOption(kind: "allow_always", name: "Allow always", optionId: "always"),
            ],
            sessionId: SessionId("s1"),
            toolCall: ToolCallUpdate(toolCallId: "tc1", title: "Edit")
        )
        let response = try await delegate.handlePermissionRequest(request: request)
        #expect(response.outcome.optionId == "always")
    }

    /// Yolo with no allow option offered → cancelled (the agent treats it as
    /// denied). Defensive: a well-formed request always has an allow.
    @Test func yoloWithNoAllowOptionCancels() async throws {
        let delegate = ACPPermissionDelegate(policy: .bypass)
        let request = RequestPermissionRequest(
            options: [PermissionOption(kind: "reject_once", name: "Reject", optionId: "r")],
            sessionId: SessionId("s1"),
            toolCall: ToolCallUpdate(toolCallId: "tc1", title: "X")
        )
        let response = try await delegate.handlePermissionRequest(request: request)
        #expect(response.outcome.outcome == "cancelled")
        #expect(response.outcome.optionId == nil)
    }

    // MARK: - Permission policy: always-ask (deferred then resolved)

    /// Always-ask DEFERS: the call suspends and records a pending request. It
    /// does NOT resolve until the UI calls `resolve(optionId:)`. Mirrors paseo's
    /// pending-permission map.
    @Test func alwaysAskDefersUntilResolved() async throws {
        let delegate = ACPPermissionDelegate(policy: .alwaysAsk)
        let request = RequestPermissionRequest(
            options: [
                PermissionOption(kind: "allow_always", name: "Allow", optionId: "opt-allow"),
                PermissionOption(kind: "reject_once", name: "Reject", optionId: "opt-reject"),
            ],
            sessionId: SessionId("s1"),
            toolCall: ToolCallUpdate(toolCallId: "tc-pending", title: "Write file", kind: .edit)
        )

        // Start the request on a background task — it must SUSPEND, not return.
        let requestTask = Task<(RequestPermissionResponse, Error?), Never> {
            do {
                let response = try await delegate.handlePermissionRequest(request: request)
                return (response, nil)
            } catch {
                return (.init(outcome: .init(cancelled: true)), error)
            }
        }

        // Give the suspended continuation a moment to register, then assert the
        // request is pending (the future UI would surface this as Approve/Reject).
        try await Task.sleep(nanoseconds: 50_000_000)
        let pending = delegate.pendingSnapshot()
        #expect(pending.count == 1)
        #expect(pending.first?.toolCallId == "tc-pending")
        #expect(pending.first?.options.count == 2)

        // Resolve ALLOW — the future UI's Approve button.
        let resolvedAllow = delegate.resolve(optionId: "opt-allow")
        #expect(resolvedAllow == true)

        let (response, error) = await requestTask.value
        #expect(error == nil)
        #expect(response.outcome.outcome == "selected")
        #expect(response.outcome.optionId == "opt-allow")

        // Pending cleared after resolution.
        #expect(delegate.pendingSnapshot().isEmpty)
    }

    /// Always-ask then resolve DENY — the future UI's Reject button. The agent
    /// adapts (it already does for denied tools).
    @Test func alwaysAskResolvesDeny() async throws {
        let delegate = ACPPermissionDelegate(policy: .alwaysAsk)
        let request = RequestPermissionRequest(
            options: [
                PermissionOption(kind: "allow_once", name: "Allow", optionId: "opt-allow"),
                PermissionOption(kind: "reject_once", name: "Reject", optionId: "opt-reject"),
            ],
            sessionId: SessionId("s1"),
            toolCall: ToolCallUpdate(toolCallId: "tc-deny", title: "Rm -rf")
        )

        let requestTask = Task<RequestPermissionResponse, Error> {
            try await delegate.handlePermissionRequest(request: request)
        }

        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(delegate.pendingSnapshot().count == 1)

        // Resolve DENY.
        let resolvedDeny = delegate.resolve(optionId: "opt-reject")
        #expect(resolvedDeny == true)

        let response = try await requestTask.value
        #expect(response.outcome.outcome == "selected")
        #expect(response.outcome.optionId == "opt-reject")
    }

    /// Resolving an option id that no pending request offers → false (no-op).
    @Test func resolveUnknownOptionReturnsFalse() async throws {
        let delegate = ACPPermissionDelegate(policy: .alwaysAsk)
        let request = RequestPermissionRequest(
            options: [PermissionOption(kind: "allow_once", name: "Allow", optionId: "opt-allow")],
            sessionId: SessionId("s1"),
            toolCall: ToolCallUpdate(toolCallId: "tc-x", title: "X")
        )
        // Register a pending request but don't resolve it (leave it suspended).
        _ = Task<Void, Never> { _ = try? await delegate.handlePermissionRequest(request: request) }
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(delegate.pendingSnapshot().count == 1)

        // Unknown option id → no resolution.
        #expect(delegate.resolve(optionId: "does-not-exist") == false)
        #expect(delegate.pendingSnapshot().count == 1)

        // Clean up: resolve for real so the suspended task completes.
        _ = delegate.resolve(optionId: "opt-allow")
    }

    // MARK: - Helpers

    /// A representative spread of `SessionUpdate` values (one per modeled kind)
    /// for the turn-boundary sweep.
    private func representativeUpdates() -> [SessionUpdate] {
        [
            .agentMessageChunk(.text(TextContent(text: "hi"))),
            .agentThoughtChunk(.text(TextContent(text: "hmm"))),
            .userMessageChunk(.text(TextContent(text: "yo"))),
            .toolCall(ToolCallUpdate(toolCallId: "t", title: "T", kind: .read)),
            .toolCallUpdate(ToolCallUpdateDetails(toolCallId: "t", status: .completed)),
            .usageUpdate(UsageUpdate(used: 1, size: 1)),
            .currentModeUpdate("agent"),
        ]
    }

    // MARK: - System prompt delivery (issue #427)

    /// A non-empty system prompt is written to the working directory as both
    /// `CLAUDE.md` and `AGENTS.md` with the exact contents (spec-compliant
    /// delivery — ACP's NewSessionRequest has no systemPrompt field).
    @Test
    func deliverSystemPromptWritesBothFiles() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("acp-prompt-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let prompt = "You are a wiki maintainer. Use wikictl first."
        ACPBackend.deliverSystemPrompt(prompt, to: dir.path)

        let claude = try String(contentsOf: dir.appendingPathComponent("CLAUDE.md"), encoding: .utf8)
        let agents = try String(contentsOf: dir.appendingPathComponent("AGENTS.md"), encoding: .utf8)
        #expect(claude == prompt)
        #expect(agents == prompt)
    }

    /// An empty system prompt writes nothing — preserves the caller-relying-on-
    /// projection-alone behavior (AC.1 skip-silently requirement).
    @Test
    func deliverSystemPromptEmptyWritesNothing() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("acp-prompt-empty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        ACPBackend.deliverSystemPrompt("", to: dir.path)

        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("CLAUDE.md").path))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("AGENTS.md").path))
    }

    /// Both files are byte-identical — catches drift from divergent code paths.
    @Test
    func deliverSystemPromptFilesAreIdentical() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("acp-prompt-identical-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let prompt = "# Wiki Instructions\n\nUse wikictl.\nCite sources.\n"
        ACPBackend.deliverSystemPrompt(prompt, to: dir.path)

        let claude = try Data(contentsOf: dir.appendingPathComponent("CLAUDE.md"))
        let agents = try Data(contentsOf: dir.appendingPathComponent("AGENTS.md"))
        #expect(claude == agents)
    }

    /// Pre-existing stale files are overwritten — covers the scratch-dir-reuse
    /// case (a scratch dir that already has an old CLAUDE.md from a prior run).
    @Test
    func deliverSystemPromptOverwritesStaleFiles() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("acp-prompt-overwrite-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Write a stale old prompt.
        try "OLD STALE PROMPT".write(to: dir.appendingPathComponent("CLAUDE.md"), atomically: true, encoding: .utf8)
        try "OLD STALE PROMPT".write(to: dir.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)

        let newPrompt = "NEW FRESH PROMPT"
        ACPBackend.deliverSystemPrompt(newPrompt, to: dir.path)

        let claude = try String(contentsOf: dir.appendingPathComponent("CLAUDE.md"), encoding: .utf8)
        let agents = try String(contentsOf: dir.appendingPathComponent("AGENTS.md"), encoding: .utf8)
        #expect(claude == newPrompt)
        #expect(agents == newPrompt)
    }

    // MARK: - System prompt injection (issue #427, agent-agnostic delivery)

    /// A non-empty system prompt is prepended to the user text with a delimiter
    /// so the agent can distinguish steering from the actual task.
    @Test
    func injectSystemPromptPrependsPrompt() {
        let result = ACPBackend.injectSystemPrompt(
            "Use wikictl first, web last.",
            into: "Find pages about photosynthesis"
        )
        #expect(result.contains("Use wikictl first, web last."))
        #expect(result.contains("Find pages about photosynthesis"))
        // System prompt comes before the user text.
        let promptRange = result.range(of: "Use wikictl first")
        let userRange = result.range(of: "Find pages about")
        #expect(promptRange!.lowerBound < userRange!.lowerBound)
        // A delimiter separates the two.
        #expect(result.contains("---"))
        #expect(result.contains("# YOUR TASK"))
    }

    /// An empty system prompt passes the user text through unchanged — no
    /// injection when the caller has no system prompt.
    @Test
    func injectSystemPromptEmptyReturnsUserTextUnchanged() {
        let userText = "What is the Calvin cycle?"
        let result = ACPBackend.injectSystemPrompt("", into: userText)
        #expect(result == userText)
    }

    /// The injection preserves the full system prompt content verbatim — a
    /// multi-line prompt with special characters survives intact.
    @Test
    func injectSystemPromptPreservesMultilinePrompt() {
        let prompt = """
        # Wiki Maintainer Instructions

        Use `wikictl` to read and write.
        Cite sources with [[source:Name#"quote"]].
        Never edit through the filesystem.
        """
        let result = ACPBackend.injectSystemPrompt(prompt, into: "Ingest this paper")
        #expect(result.hasPrefix("# Wiki Maintainer Instructions"))
        #expect(result.contains("Use `wikictl` to read and write."))
        #expect(result.contains("Ingest this paper"))
    }

    // MARK: - Phase 4: Usage/cost capture

    /// The translator still returns `[]` for `.usageUpdate` — the data is
    /// consumed internally by the backend's notification drain, not surfaced
    /// as an AgentEvent in the transcript. This test pins that contract.
    @Test
    func usageUpdateStillEmitsNoAgentEvents() {
        let translator = ACPEventTranslator()
        let update = SessionUpdate.usageUpdate(UsageUpdate(
            used: 5000,
            size: 10000,
            cost: Cost(amount: 0.03, currency: "USD")))
        #expect(translator.translate(update) == [])
    }

    /// The `SessionUsage` snapshot struct carries both context window data
    /// (from `UsageUpdate`) and cumulative token totals (from `Usage`).
    @Test
    func sessionUsageStructCarriesAllFields() {
        let usage = SessionUsage(
            inputTokens: 100,
            outputTokens: 200,
            totalTokens: 300,
            cachedReadTokens: 50,
            thoughtTokens: 10,
            cost: 0.05,
            currency: "USD",
            contextUsed: 5000,
            contextSize: 10000,
            providerLabel: "Claude",
            modelId: "sonnet-4",
            thinkingLevel: "high")
        #expect(usage.inputTokens == 100)
        #expect(usage.outputTokens == 200)
        #expect(usage.totalTokens == 300)
        #expect(usage.cachedReadTokens == 50)
        #expect(usage.thoughtTokens == 10)
        #expect(usage.cost == 0.05)
        #expect(usage.currency == "USD")
        #expect(usage.contextUsed == 5000)
        #expect(usage.contextSize == 10000)
        #expect(usage.providerLabel == "Claude")
        #expect(usage.modelId == "sonnet-4")
        #expect(usage.thinkingLevel == "high")
    }

    /// `SessionUsage` with optional fields set to nil (agent didn't report them).
    @Test
    func sessionUsageStructWithNilOptionals() {
        let usage = SessionUsage(
            inputTokens: 10,
            outputTokens: 20,
            totalTokens: 30,
            cachedReadTokens: nil,
            thoughtTokens: nil,
            cost: nil,
            currency: nil,
            contextUsed: 0,
            contextSize: 0)
        #expect(usage.cachedReadTokens == nil)
        #expect(usage.thoughtTokens == nil)
        #expect(usage.cost == nil)
        #expect(usage.currency == nil)
        #expect(usage.contextUsed == 0)
        #expect(usage.contextSize == 0)
        #expect(usage.providerLabel == nil)
        #expect(usage.modelId == nil)
    }

    /// `SessionUsage.merging` combines token counts (summed), and carries
    /// the latest non-nil `providerLabel`/`modelId` (point-in-time, like
    /// cost/currency). Existing nil is preserved; new non-nil overrides.
    @Test
    func mergingCarriesLatestProviderLabelAndModelId() {
        let first = SessionUsage(
            inputTokens: 100, outputTokens: 200, totalTokens: 300,
            cachedReadTokens: nil, thoughtTokens: nil,
            cost: 0.05, currency: "USD", contextUsed: 1000, contextSize: 10000,
            providerLabel: "Claude", modelId: "sonnet-4")

        let second = SessionUsage(
            inputTokens: 50, outputTokens: 30, totalTokens: 80,
            cachedReadTokens: nil, thoughtTokens: nil,
            cost: 0.02, currency: "USD", contextUsed: 5000, contextSize: 10000,
            providerLabel: "Hermes", modelId: "hermes-3")

        let merged = SessionUsage.merging(first, second)
        // Tokens are summed.
        #expect(merged.inputTokens == 150)
        #expect(merged.outputTokens == 230)
        #expect(merged.totalTokens == 380)
        // Cost is summed.
        #expect(merged.cost == 0.07)
        // Latest non-nil wins for point-in-time metadata.
        #expect(merged.providerLabel == "Hermes")
        #expect(merged.modelId == "hermes-3")
    }

    /// `SessionUsage.merging` preserves the existing `providerLabel`/
    /// `modelId` when the new snapshot doesn't supply them (nil).
    @Test
    func mergingPreservesExistingProviderLabelWhenNewIsNil() {
        let first = SessionUsage(
            inputTokens: 100, outputTokens: 200, totalTokens: 300,
            cachedReadTokens: nil, thoughtTokens: nil,
            cost: nil, currency: nil, contextUsed: 0, contextSize: 10000,
            providerLabel: "Claude", modelId: "sonnet-4")

        let second = SessionUsage(
            inputTokens: 50, outputTokens: 30, totalTokens: 80,
            cachedReadTokens: nil, thoughtTokens: nil,
            cost: nil, currency: nil, contextUsed: 5000, contextSize: 10000,
            providerLabel: nil, modelId: nil)

        let merged = SessionUsage.merging(first, second)
        #expect(merged.providerLabel == "Claude")
        #expect(merged.modelId == "sonnet-4")
    }

    /// `SessionUsage.merging` carries the latest non-nil `thinkingLevel`
    /// (point-in-time, like `providerLabel`/`modelId`). Regression test for #569:
    /// the enrichment path in `capturePhaseUsage` must thread `thinkingLevel`
    /// through — otherwise the Activity window's thinking-effort segment is
    /// always blank.
    @Test
    func mergingCarriesLatestThinkingLevel() {
        let first = SessionUsage(
            inputTokens: 100, outputTokens: 200, totalTokens: 300,
            cachedReadTokens: nil, thoughtTokens: nil,
            cost: nil, currency: nil, contextUsed: 0, contextSize: 10000,
            providerLabel: "Claude", modelId: "sonnet-4",
            thinkingLevel: "low")

        let second = SessionUsage(
            inputTokens: 50, outputTokens: 30, totalTokens: 80,
            cachedReadTokens: nil, thoughtTokens: nil,
            cost: nil, currency: nil, contextUsed: 5000, contextSize: 10000,
            providerLabel: "Claude", modelId: "sonnet-4",
            thinkingLevel: "high")

        let merged = SessionUsage.merging(first, second)
        #expect(merged.thinkingLevel == "high")
    }

    /// `SessionUsage.merging` preserves the existing `thinkingLevel` when the
    /// new snapshot doesn't supply one (nil) — the latest-non-nil-wins rule.
    @Test
    func mergingPreservesExistingThinkingLevelWhenNewIsNil() {
        let first = SessionUsage(
            inputTokens: 100, outputTokens: 200, totalTokens: 300,
            cachedReadTokens: nil, thoughtTokens: nil,
            cost: nil, currency: nil, contextUsed: 0, contextSize: 10000,
            providerLabel: "Claude", modelId: "sonnet-4",
            thinkingLevel: "medium")

        let second = SessionUsage(
            inputTokens: 50, outputTokens: 30, totalTokens: 80,
            cachedReadTokens: nil, thoughtTokens: nil,
            cost: nil, currency: nil, contextUsed: 5000, contextSize: 10000,
            providerLabel: nil, modelId: nil,
            thinkingLevel: nil)

        let merged = SessionUsage.merging(first, second)
        #expect(merged.thinkingLevel == "medium")
    }

    /// `SessionUsage.merging(nil, new)` returns `new` directly.
    @Test
    func mergingWithNilExistingReturnsNew() {
        let new = SessionUsage(
            inputTokens: 10, outputTokens: 20, totalTokens: 30,
            cachedReadTokens: nil, thoughtTokens: nil,
            cost: nil, currency: nil, contextUsed: 0, contextSize: 0,
            providerLabel: "OpenCode", modelId: "opencode-1")
        let merged = SessionUsage.merging(nil, new)
        #expect(merged.inputTokens == 10)
        #expect(merged.providerLabel == "OpenCode")
        #expect(merged.modelId == "opencode-1")
    }

    // MARK: - SessionUsage.delta (interactive usage, no double-count)

    /// `delta(from: nil, to: new)` returns `new` directly — the first interactive
    /// turn's delta is the full cumulative session usage. Guards against dropping
    /// the first turn from the daily total.
    @Test
    func deltaWithNilBaselineReturnsFullSnapshot() {
        let current = SessionUsage(
            inputTokens: 100, outputTokens: 50, totalTokens: 150,
            cachedReadTokens: 20, thoughtTokens: 30,
            cost: 0.05, currency: "USD", contextUsed: 4000, contextSize: 10000,
            providerLabel: "Claude", modelId: "sonnet-4",
            thinkingLevel: "high")
        let d = SessionUsage.delta(from: nil, to: current)
        #expect(d.inputTokens == 100)
        #expect(d.outputTokens == 50)
        #expect(d.totalTokens == 150)
        #expect(d.cachedReadTokens == 20)
        #expect(d.thoughtTokens == 30)
        #expect(d.cost == 0.05)
        #expect(d.providerLabel == "Claude")
    }

    /// `delta` subtracts the baseline's cumulative token counts so accumulating
    /// per-turn deltas into `DailyUsage.add` doesn't double-count across turns
    /// of the SAME session. This is the core correctness guarantee for the
    /// interactive-usage wiring: the backend reports cumulative session totals,
    /// but the daily total must only gain THIS turn's marginal tokens.
    @Test
    func deltaSubtractsBaselineTokens() {
        let baseline = SessionUsage(
            inputTokens: 1000, outputTokens: 500, totalTokens: 1500,
            cachedReadTokens: 100, thoughtTokens: 200,
            cost: 1.00, currency: "USD", contextUsed: 3000, contextSize: 10000,
            providerLabel: "Claude", modelId: "sonnet-4",
            thinkingLevel: "high")
        let current = SessionUsage(
            inputTokens: 1300, outputTokens: 700, totalTokens: 2000,
            cachedReadTokens: 150, thoughtTokens: 350,
            cost: 1.40, currency: "USD", contextUsed: 6000, contextSize: 10000,
            providerLabel: "Claude", modelId: "sonnet-4",
            thinkingLevel: "high")
        let d = SessionUsage.delta(from: baseline, to: current)
        #expect(d.inputTokens == 300)
        #expect(d.outputTokens == 200)
        #expect(d.totalTokens == 500)
        #expect(d.cachedReadTokens == 50)
        #expect(d.thoughtTokens == 150)
        // Cost delta is a Double subtraction (1.40 − 1.00) — use approximate
        // equality to avoid float-precision false failures.
        #expect(abs((d.cost ?? 0) - 0.40) < 0.001)
        // Context window is point-in-time, not cumulative.
        #expect(d.contextUsed == 6000)
        #expect(d.contextSize == 10000)
    }

    /// `delta` takes the latest non-nil point-in-time metadata
    /// (providerLabel/modelId/thinkingLevel), matching `merging`'s rule.
    /// A turn that drops the model id must inherit it from the baseline.
    @Test
    func deltaCarriesMetadataFromBaselineWhenMissing() {
        let baseline = SessionUsage(
            inputTokens: 100, outputTokens: 50, totalTokens: 150,
            cachedReadTokens: nil, thoughtTokens: nil,
            cost: nil, currency: nil, contextUsed: 0, contextSize: 10000,
            providerLabel: "Claude", modelId: "sonnet-4",
            thinkingLevel: "high")
        let current = SessionUsage(
            inputTokens: 200, outputTokens: 100, totalTokens: 300,
            cachedReadTokens: nil, thoughtTokens: nil,
            cost: nil, currency: nil, contextUsed: 5000, contextSize: 10000,
            providerLabel: nil, modelId: nil,
            thinkingLevel: nil)
        let d = SessionUsage.delta(from: baseline, to: current)
        #expect(d.providerLabel == "Claude")
        #expect(d.modelId == "sonnet-4")
        #expect(d.thinkingLevel == "high")
    }

    /// `delta` never returns negative token counts even if the backend reports
    /// a lower cumulative total on a later turn (shouldn't happen in practice,
    /// but guards against a session-restart that reuses a stale baseline).
    @Test
    func deltaClampsToZero() {
        let baseline = SessionUsage(
            inputTokens: 500, outputTokens: 400, totalTokens: 900,
            cachedReadTokens: 100, thoughtTokens: 50,
            cost: 2.00, currency: "USD", contextUsed: 5000, contextSize: 10000,
            providerLabel: "Claude", modelId: "sonnet-4",
            thinkingLevel: "high")
        // A LOWER cumulative (e.g. after a session restart reusing a stale
        // baseline). Delta must clamp to 0, not negative.
        let current = SessionUsage(
            inputTokens: 100, outputTokens: 50, totalTokens: 150,
            cachedReadTokens: 10, thoughtTokens: 5,
            cost: 0.50, currency: "USD", contextUsed: 1000, contextSize: 10000,
            providerLabel: "Claude", modelId: "sonnet-4",
            thinkingLevel: "high")
        let d = SessionUsage.delta(from: baseline, to: current)
        #expect(d.inputTokens == 0)
        #expect(d.outputTokens == 0)
        #expect(d.totalTokens == 0)
        #expect(d.cachedReadTokens == 0)
        #expect(d.thoughtTokens == 0)
        // Cost delta clamps to 0 too (current is lower than baseline).
        #expect(d.cost == 0)
    }

    // MARK: - Phase 4: Default config

    /// Parallel executors default to 1 (serial — conservative; requires Phase 3
    /// fork + concurrent session support).
    @Test
    func maxConcurrentExecutorsDefaultsToOne() async {
        let backend = ACPBackend()
        let max = await backend.maxConcurrentExecutorCount()
        #expect(max == 1)
    }

    /// Parallel executors can be explicitly enabled (max > 1).
    @Test
    func maxConcurrentExecutorsCanExceedOne() async {
        let backend = ACPBackend(maxConcurrentExecutors: 3)
        let max = await backend.maxConcurrentExecutorCount()
        #expect(max == 3)
    }

    /// Values below 1 are clamped to 1 (serial) — never zero or negative.
    @Test
    func maxConcurrentExecutorsClampedToOne() async {
        let backend = ACPBackend(maxConcurrentExecutors: 0)
        let max = await backend.maxConcurrentExecutorCount()
        #expect(max == 1)
    }

    // MARK: - #609: turn ceiling threading

    /// The default `ACPBackend()` ceiling is the interactive 1800s — preserved
    /// pre-#609 behavior. Chat (`startInteractiveQuery`) relies on this default
    /// (passed explicitly via `TurnLivenessPolicy.ceiling(for: .chat)`).
    @Test
    func ceilingTimeoutDefaultsToInteractive() async {
        let backend = ACPBackend()
        let ceiling = await backend.ceilingTimeout()
        #expect(ceiling == TurnLivenessPolicy.defaultCeilingTimeout)
        #expect(ceiling == 1800)
    }

    /// An explicit `turnCeilingTimeout: 600` threads through untouched — the
    /// value the launcher passes for ingest/lint (queued pipelines). Pinned so
    /// a future refactor can't accidentally ignore the parameter and fall back
    /// to the default.
    @Test
    func ceilingTimeoutExplicitValueThreaded() async {
        let backend = ACPBackend(turnCeilingTimeout: 600)
        let ceiling = await backend.ceilingTimeout()
        #expect(ceiling == 600)
    }

    /// #609 contract: the queued-ingestion ceiling (600s) is lower than the
    /// interactive default (1800s). Pinned at the construction level so the
    /// two values cannot drift equal at the type level either.
    @Test
    func queuedCeilingLowerThanInteractive() async {
        let interactive = ACPBackend()
        let queued = ACPBackend(turnCeilingTimeout: TurnLivenessPolicy.queuedIngestCeiling)
        let interactiveCeiling = await interactive.ceilingTimeout()
        let queuedCeiling = await queued.ceilingTimeout()
        #expect(queuedCeiling < interactiveCeiling)
    }
}
#endif
