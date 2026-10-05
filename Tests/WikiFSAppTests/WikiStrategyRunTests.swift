#if os(macOS)
import Foundation
import GRDB
import Testing
import WikiFSCore
import WikiFSTypes
@testable import WikiFSEngine
@testable import wikid

/// AC.2 of the wiki-strategies plan: every host request captures the wiki's
/// committed editorial strategy, without cross-wiki leakage; later saves affect
/// later requests only; Default snapshots stay unchanged.
///
/// Host/kind matrix covered here (the pairs the product actually supports):
/// - **App host** — every snapshot-bearing path reads
///   `WikiStoreModel.currentStateSnapshot()`: queue ingest
///   (`AppQueueIngestionProvider`), query (`AgentOperationRunner.runQuery`),
///   lint / page-lint (queue + runner), and the legacy runner chat start /
///   continue (no production caller — the app chats through the daemon — but
///   the same snapshot call). Proven here by staging each `OperationRequest`
///   kind's `WIKI_STATE.md` and asserting the strategy section.
/// - **Daemon host** — `DaemonWikiState.stateMarkdown(from:)` feeds queue
///   ingest, lint, page-lint, and the chat session's first turn
///   (`LauncherChatAgentRuntime.submitTurn`). Proven by rendering it.
/// - **Daemon chat warm follow-up** — the supported path with NO staged state:
///   `LauncherChatAgentRuntime` captures the strategy per turn and composes it
///   into the turn prompt as explicit per-turn authority. Authority is explicit
///   even under Default: after a reset, the session's context still holds the
///   previous custom strategy, and only an explicit Default document supersedes
///   it. A resumed provider session gets the same authority on its first turn
///   (`AgentLauncher.startInteractiveQuery(turnStrategyMarkdown:)`).
/// - `SystemPromptService` is deliberately NOT involved: strategy capture is
///   per-request from the store, never process-scoped.
/// - A strategy READ failure never degrades to the Default snapshot: both
///   snapshot hosts throw `WikiStateSnapshotError.strategyReadFailed`, and
///   their callers build no execution request (queue items fail; runner and
///   chat surfaces show a preflight error) — the same never-invent-Default
///   contract the warm-chat turn enforces.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct WikiStrategyRunTests {

    // MARK: - Fixtures

    private func makeModel(wikiID: String) throws -> (WikiStoreModel, GRDBWikiStore) {
        let store = try TestStoreFactory.inMemory()
        store.eventBus = WikiEventBus(wikiID: WikiID(rawValue: wikiID))
        return (WikiStoreModel(store: store), store)
    }

    private func saveStrategy(
        _ store: GRDBWikiStore,
        name: String,
        instructions: String,
        expectedRevision: WikiStrategyRevision?
    ) throws -> WikiStrategy {
        let outcome = try store.saveWikiStrategy(
            name: name, instructions: instructions,
            expectedRevision: expectedRevision)
        guard case .saved(_, let strategy?) = outcome else {
            throw TestFailure("strategy save did not commit a custom strategy")
        }
        return strategy
    }

    /// Reset the wiki to the Default strategy (a tombstone row), advancing the
    /// revision like a real editor reset.
    private func resetToDefault(
        _ store: GRDBWikiStore,
        after strategy: WikiStrategy
    ) throws {
        _ = try store.saveWikiStrategy(
            name: strategy.name, instructions: "   ",
            expectedRevision: strategy.revision)
    }

    private func turn(_ text: String, id: String) -> ChatTurnSubmission {
        ChatTurnSubmission(
            commandID: ChatCommandID(rawValue: "\(id)-command"),
            turnID: ChatTurnID(rawValue: "\(id)-turn"),
            userText: text,
            contextReferences: [],
            submittedAt: Date())
    }

    /// Build the daemon chat runtime exactly as `DaemonChatHost` does, over an
    /// in-process fake backend that records every sent prompt.
    private func makeRuntime(
        store: GRDBWikiStore,
        chatID: ChatID,
        backend: FakeAgentBackend,
        directory: URL
    ) -> (runtime: LauncherChatAgentRuntime, launcher: AgentLauncher) {
        let provider = AgentProvider(
            id: ProviderID(rawValue: "strategy-run-provider"),
            label: "Strategy Run",
            command: ["/usr/bin/true"],
            enabled: true,
            isDefault: true)
        let configuration = AgentProvidersConfig(
            providers: [provider],
            selectedModelIds: [provider.id.rawValue: ModelID(rawValue: "strategy-run-model")])
        let services = AgentProviderRuntime(
            readConfiguration: { configuration },
            resolveCommand: { providers in
                Dictionary(uniqueKeysWithValues: providers.compactMap { provider in
                    provider.command.map { (provider.id, $0) }
                })
            },
            readCredential: { _ in nil },
            resolvePermissionPolicy: { _ in .bypass },
            makeBackend: { _, _, _, _ in backend })
        let launcherPair = makeTestLauncherPair(
            extractionCoordinator: ExtractionCoordinator(
                containerDirectory: directory,
                localExtractorFactory: { StrategyRunStubExtractor() }),
            generationGate: GenerationGate(laneLimits: [.ingest: 1, .interactive: 1]),
            providerServices: services)
        let runtime = LauncherChatAgentRuntime(
            chatID: chatID,
            wikiID: WikiID(rawValue: "strategy-run-wiki"),
            store: store,
            launcher: launcherPair.launcher,
            pushEvent: { _ in },
            onSessionID: { _ in },
            onStateUpdate: { _ in },
            onLiveEvents: { _ in },
            providerServices: services,
            onMessageSummary: { _ in },
            launcherConfigurator: { launcher in launcher.containerDirectory = directory })
        return (runtime, launcherPair.launcher)
    }

    private func startSession(
        runtime: LauncherChatAgentRuntime,
        chatID: ChatID,
        resuming sessionID: String? = nil
    ) async throws -> ChatRuntimeHandle {
        let input = ChatRuntimeStartInput(
            request: ChatRuntimeStartRequest(
                chatID: chatID,
                generation: ChatSessionGenerationID(rawValue: "strategy-run-generation"),
                systemPrompt: "",
                providerID: nil,
                modelID: nil,
                existingProviderSessionID: sessionID.map { AcpSessionID(rawValue: $0) }),
            configuredThinkingOptionID: nil,
            priorEffectiveThinkingOptionID: nil)
        let prepared = try await runtime.prepareStart(input)
        return try await runtime.start(prepared)
    }

    private func stagedStateFile(
        for request: OperationRequest,
        kindLabel: String
    ) throws -> String {
        let scratch = try makeChatDirectory("run-\(kindLabel)")
        defer {
            do {
                try FileManager.default.removeItem(at: scratch)
            } catch {
                Issue.record("Failed to remove staged state fixture: \(error)")
            }
        }
        _ = try request.stage(into: scratch)
        let url = scratch.appendingPathComponent(AgentStaging.stateFileName)
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            Issue.record("\(kindLabel) could not read staged \(AgentStaging.stateFileName): \(error)")
            throw error
        }
    }

    private func assertCustomStrategyRendered(
        _ markdown: String,
        strategy: WikiStrategy,
        context: String
    ) {
        #expect(markdown.contains("# Wiki Strategy"), "\(context): strategy section present")
        #expect(markdown.contains("Name: \(strategy.name)"), "\(context): strategy name")
        #expect(
            markdown.contains("Revision: \(strategy.revision.rawValue)"),
            "\(context): strategy revision")
        #expect(
            markdown.contains(strategy.instructions),
            "\(context): strategy instructions")
    }

    /// The Default strategy document: what a Default wiki's per-turn authority
    /// renders. Assertions stay on stable, parent-owned phrases of the shared
    /// renderer (`WikiStrategyRenderer.render(nil)`).
    private func assertDefaultStrategyRendered(
        _ markdown: String,
        context: String,
        superseded custom: WikiStrategy
    ) {
        #expect(markdown.contains("# Wiki Strategy"), "\(context): strategy section present")
        #expect(markdown.contains("Default"), "\(context): explicit Default authority")
        #expect(
            markdown.contains("Use the application's default summary, entity, and concept organization"),
            "\(context): Default document restores the default editorial rules")
        #expect(!markdown.contains(custom.name), "\(context): stale custom name superseded")
        #expect(!markdown.contains(custom.instructions), "\(context): stale custom instructions superseded")
    }

    // MARK: - App + daemon capture (AC.2: WikiStrategyRunTests.appAndDaemonCapture)

    @Test func appAndDaemonCapture() throws {
        // Two wikis, two committed strategies. Capture is per-request from each
        // wiki's own store — a wiki never sees another wiki's strategy (and no
        // process-scoped service is involved, so this must hold by construction).
        let (appModel, appStore) = try makeModel(wikiID: "strategy-run-app")
        let appStrategy = try saveStrategy(
            appStore, name: "App editorial strategy",
            instructions: "Prefer tutorials over reference prose.",
            expectedRevision: nil)

        let daemonStore = try TestStoreFactory.inMemory()
        let daemonStrategy = try saveStrategy(
            daemonStore, name: "Daemon editorial strategy",
            instructions: "Track revelation order separately from chronology.",
            expectedRevision: nil)

        // App host: the snapshot the model builds at request time.
        let appSnapshot = try appModel.currentStateSnapshot()
        #expect(appSnapshot.strategy == appStrategy)
        assertCustomStrategyRendered(
            appSnapshot.renderStateFile(), strategy: appStrategy,
            context: "app snapshot")

        // Daemon host: the markdown the daemon builds at request time.
        let daemonMarkdown = try DaemonWikiState.stateMarkdown(from: daemonStore)
        assertCustomStrategyRendered(
            daemonMarkdown, strategy: daemonStrategy,
            context: "daemon markdown")

        // No cross-wiki leakage: each rendering carries only its own wiki's
        // strategy, never the other wiki's name or instructions.
        #expect(!appSnapshot.renderStateFile().contains(daemonStrategy.name))
        #expect(!daemonMarkdown.contains(appStrategy.name))
    }

    // MARK: - Every operation kind receives the strategy (AC.2)

    @Test func allOperationKindsReceiveStrategy() throws {
        let (model, store) = try makeModel(wikiID: "strategy-run-kinds")
        let strategy = try saveStrategy(
            store, name: "Kinds strategy",
            instructions: "Every operation kind must see this sentence.",
            expectedRevision: nil)
        // One page, so the staged state has real inventory alongside the
        // strategy — proving the two coexist in one document.
        _ = try store.createPage(title: "Existing Page")

        // The app hosts all build their state markdown exactly this way
        // (AgentOperationRunner :25/:86/:456/:490/:525 and
        // AppQueueIngestionProvider :164/:376/:461) — one snapshot, rendered
        // per request at construction time.
        let appStateMarkdown = try model.currentStateSnapshot().renderStateFile()

        let stagedSource = OperationRequest.StagedSource(
            bytes: Data("# Staged".utf8),
            ext: "md",
            displayPath: "sources/by-id/staged.md",
            name: "staged",
            sourceID: SourceID(rawValue: "01STRATEGYSOURCE000000000000000"))

        let requests: [(label: String, request: OperationRequest)] = [
            ("ingest", .ingest(sources: [stagedSource], stateMarkdown: appStateMarkdown)),
            ("query", .query(question: "What is this wiki about?", stateMarkdown: appStateMarkdown)),
            ("lint", .lint(stateMarkdown: appStateMarkdown)),
            ("lintPage", .lintPage(pageTitle: "Existing Page", brokenLinks: [], stateMarkdown: appStateMarkdown)),
        ]
        for (label, request) in requests {
            let staged = try stagedStateFile(for: request, kindLabel: label)
            assertCustomStrategyRendered(staged, strategy: strategy, context: "app \(label)")
            #expect(
                staged.contains("- Existing Page"),
                "app \(label): page inventory still present alongside the strategy")
        }

        // The daemon queue host builds ingest / lint / page-lint state markdown
        // from DaemonWikiState (DaemonQueueIngestionProvider :103/:241/:298);
        // the chat session's first turn stages the same markdown
        // (LauncherChatAgentRuntime.submitTurn).
        let daemonMarkdown = try DaemonWikiState.stateMarkdown(from: store)
        assertCustomStrategyRendered(daemonMarkdown, strategy: strategy, context: "daemon queue + chat start")
    }

    // MARK: - A run keeps its captured strategy (AC.2)

    @Test func activeRunRetainsCapturedStrategy() throws {
        let (model, store) = try makeModel(wikiID: "strategy-run-retain")
        let first = try saveStrategy(
            store, name: "First revision strategy",
            instructions: "First instructions.",
            expectedRevision: nil)

        // Snapshot paths: the request's snapshot is an immutable value. A save
        // after construction must not change what the in-flight run sees.
        let captured = try model.currentStateSnapshot()
        let capturedRendered = captured.renderStateFile()
        let second = try saveStrategy(
            store, name: "Second revision strategy",
            instructions: "Second instructions.",
            expectedRevision: first.revision)

        #expect(captured.strategy == first, "captured snapshot keeps the revision it was built at")
        assertCustomStrategyRendered(capturedRendered, strategy: first, context: "retained snapshot")
        #expect(!capturedRendered.contains(second.instructions))
        // The store itself has moved on — only LATER requests see revision 2.
        let later = try model.currentStateSnapshot()
        #expect(later.strategy == second)
        assertCustomStrategyRendered(later.renderStateFile(), strategy: second, context: "later snapshot")

        // Chat turns: the prompt is composed once at turn submission from the
        // revision read at that moment. A save after composition cannot change
        // the composed turn.
        let composedAtSecond = LauncherChatAgentRuntime.turnPrompt(
            strategyMarkdown: LauncherChatAgentRuntime.turnStrategyMarkdown(
                try LauncherChatAgentRuntime.readTurnStrategy(from: store)),
            userText: "Continue the analysis.")
        let third = try saveStrategy(
            store, name: "Third revision strategy",
            instructions: "Third instructions.",
            expectedRevision: second.revision)
        #expect(composedAtSecond.contains("Second revision strategy"))
        #expect(!composedAtSecond.contains(third.instructions))
        let composedAtThird = LauncherChatAgentRuntime.turnPrompt(
            strategyMarkdown: LauncherChatAgentRuntime.turnStrategyMarkdown(
                try LauncherChatAgentRuntime.readTurnStrategy(from: store)),
            userText: "Continue the analysis.")
        #expect(composedAtThird.contains("Third revision strategy"))
    }

    // MARK: - Default snapshots unchanged (AC.2)

    @Test func defaultSnapshotParity() throws {
        let (model, store) = try makeModel(wikiID: "strategy-run-default")
        _ = try store.createPage(title: "Plain Page")

        // A wiki that never saved a strategy captures Default: no strategy
        // section, byte-identical to the pre-strategy snapshot.
        let snapshot = try model.currentStateSnapshot()
        #expect(snapshot.strategy == nil)
        let rendered = snapshot.renderStateFile()
        #expect(!rendered.contains("Wiki Strategy"), "Default adds no strategy section")
        #expect(rendered.contains("- Plain Page"), "inventory still present")

        let daemonMarkdown = try DaemonWikiState.stateMarkdown(from: store)
        #expect(!daemonMarkdown.contains("Wiki Strategy"), "daemon Default adds no strategy section")

        // After save-then-reset (a Default tombstone row), the snapshot hosts
        // still see Default — a tombstone reads back as absence, not as a
        // strategy. Snapshot parity is retained for Default in BOTH cases.
        let saved = try saveStrategy(
            store, name: "Transient",
            instructions: "Briefly custom.",
            expectedRevision: nil)
        #expect(try model.currentStateSnapshot().strategy == saved)
        try resetToDefault(store, after: saved)
        #expect(try model.currentStateSnapshot().strategy == nil, "tombstone reads as Default")
        #expect(try model.currentStateSnapshot().renderStateFile().contains("Wiki Strategy") == false)
        #expect(try DaemonWikiState.stateMarkdown(from: store).contains("Wiki Strategy") == false)

        // The Default-strategy chat turn still carries EXPLICIT authority —
        // never silence: a session that previously held a custom strategy must
        // be told the wiki is back on Default. (Snapshot hosts omit the
        // section for parity; per-turn hosts do not.)
        let defaultTurnMarkdown = LauncherChatAgentRuntime.turnStrategyMarkdown(
            try LauncherChatAgentRuntime.readTurnStrategy(from: store))
        #expect(defaultTurnMarkdown.contains("Default"), "per-turn Default authority is explicit")
        #expect(
            defaultTurnMarkdown
                .contains("Use the application's default summary, entity, and concept organization"))
        let defaultTurnPrompt = LauncherChatAgentRuntime.turnPrompt(
            strategyMarkdown: defaultTurnMarkdown, userText: "plain turn")
        #expect(defaultTurnPrompt.hasSuffix("--- new message ---\nplain turn"))
        #expect(!defaultTurnPrompt.contains("Briefly custom."))
    }

    // MARK: - Strategy read failure fails the request, never invents Default (AC.2)

    /// A strategy READ failure must not degrade to the Default snapshot: both
    /// hosts throw `WikiStateSnapshotError.strategyReadFailed`, so their
    /// callers build no execution request (queue items fail; runner and chat
    /// surfaces show a preflight error). The store failure is forced
    /// deterministically: a second connection to the same file-backed database
    /// drops the `wiki_strategy` table, so every later strategy read errors
    /// while the inventory reads keep succeeding.
    @Test func strategyReadFailureThrowsNeverDefaults() throws {
        let directory = try makeChatDirectory("read-error")
        defer { removeFixture(directory) }
        let url = directory.appendingPathComponent("WikiFS.sqlite")
        let store = try GRDBWikiStore(databaseURL: url)
        defer { store.close() }
        let model = WikiStoreModel(store: store)
        _ = try store.createPage(title: "Plain Page")

        let other = try DatabasePool(path: url.path)
        defer {
            do { try other.close() }
            catch { Issue.record("Failed to close strategy fixture pool: \(error)") }
        }
        try other.write { db in
            try db.execute(sql: "DROP TABLE wiki_strategy")
        }

        #expect(throws: WikiStateSnapshotError.self) {
            try model.currentStateSnapshot()
        }
        #expect(throws: WikiStateSnapshotError.self) {
            try DaemonWikiState.stateMarkdown(from: store)
        }
    }

    // MARK: - Chat without staged state gets the strategy per turn (AC.2)

    /// The daemon chat's warm follow-up turns send no `WIKI_STATE.md` — the
    /// session carries the file staged at its first turn. A custom strategy
    /// must still reach each turn: the runtime captures the latest committed
    /// revision at turn submission and composes it above the user's message,
    /// without any page inventory, while the transcript keeps the raw message.
    @Test func chatWithoutStateReceivesCapturedStrategy() async throws {
        let directory = try makeChatDirectory("warm-custom")
        defer { removeFixture(directory) }

        let store = try TestStoreFactory.inMemory()
        let first = try saveStrategy(
            store, name: "Warm chat strategy",
            instructions: "Answer in tutorial voice.",
            expectedRevision: nil)
        let chat = try store.createChat(kind: .edit, title: "Warm chat")
        let backend = FakeAgentBackend()
        let (runtime, launcher) = makeRuntime(
            store: store, chatID: chat.id, backend: backend, directory: directory)
        let handle = try await startSession(runtime: runtime, chatID: chat.id)

        // First turn: starts the session and stages WIKI_STATE.md (with the
        // strategy, through DaemonWikiState).
        try await runtime.submitTurn(turn("First question", id: "first"), in: handle)
        try await waitForSendCount(backend, atLeast: 1)

        // The session's staged state file carries the strategy captured at
        // session start — and a later save must NOT rewrite it.
        guard let scratch = await backend.startedProfiles.first?.scratchDirectory else {
            throw TestFailure("chat session started without a scratch directory")
        }
        let stagedPath = scratch.appendingPathComponent(AgentStaging.stateFileName)
        guard FileManager.default.fileExists(atPath: stagedPath.path) else {
            throw TestFailure("chat session staged no \(AgentStaging.stateFileName) at \(stagedPath.path)")
        }
        let stagedAtStart = try String(contentsOf: stagedPath, encoding: .utf8)
        assertCustomStrategyRendered(stagedAtStart, strategy: first, context: "chat session start state file")

        // Save a new revision between turns. The warm turn carries no state
        // file — it must still receive the strategy, at the LATEST revision.
        let second = try saveStrategy(
            store, name: "Warm chat strategy v2",
            instructions: "Answer in reference voice now.",
            expectedRevision: first.revision)
        try await runtime.submitTurn(turn("Second question", id: "warm"), in: handle)
        try await waitForSendCount(backend, atLeast: 2)
        let warmPrompt = await backend.sentTexts.last ?? ""
        assertCustomStrategyRendered(warmPrompt, strategy: second, context: "warm turn prompt")
        // No inventory rides along on a warm turn — strategy only.
        #expect(!warmPrompt.contains("Existing pages"), "warm turn injects no page inventory")
        #expect(!warmPrompt.contains("# WIKI_STATE"), "warm turn injects no state file")
        #expect(warmPrompt.hasSuffix("--- new message ---\nSecond question"), "user message follows the strategy context")
        // The visible transcript keeps the user's raw message — the strategy
        // context is prompt-only, like the continue path's preamble.
        #expect(lastVisibleUserText(launcher) == "Second question", "transcript shows the raw message")

        // The session-start staged file still shows revision 1: the session
        // keeps what it captured, and only later runs see the new revision.
        let stagedAfterSave = try String(contentsOf: stagedPath, encoding: .utf8)
        #expect(stagedAfterSave == stagedAtStart, "staged state file is not rewritten by a save")
        #expect(!stagedAfterSave.contains(second.instructions))

        await runtime.close(handle)
    }

    /// Custom → reset-to-Default on a WARM follow-up: the turn must carry an
    /// explicit Default document. Silence would leave the previous custom
    /// strategy authoritative in the session's context.
    @Test func customResetWarmFollowupCarriesExplicitDefault() async throws {
        let directory = try makeChatDirectory("warm-reset")
        defer { removeFixture(directory) }

        let store = try TestStoreFactory.inMemory()
        let custom = try saveStrategy(
            store, name: "Reset strategy",
            instructions: "Organize everything by revelation order.",
            expectedRevision: nil)
        let chat = try store.createChat(kind: .edit, title: "Reset chat")
        let backend = FakeAgentBackend()
        let (runtime, launcher) = makeRuntime(
            store: store, chatID: chat.id, backend: backend, directory: directory)
        let handle = try await startSession(runtime: runtime, chatID: chat.id)

        try await runtime.submitTurn(turn("First question", id: "first"), in: handle)
        try await waitForSendCount(backend, atLeast: 1)

        try resetToDefault(store, after: custom)
        try await runtime.submitTurn(turn("After reset question", id: "after-reset"), in: handle)
        try await waitForSendCount(backend, atLeast: 2)
        let afterResetPrompt = await backend.sentTexts.last ?? ""
        assertDefaultStrategyRendered(
            afterResetPrompt, context: "post-reset warm turn", superseded: custom)
        #expect(!afterResetPrompt.contains("Existing pages"), "no page inventory")
        #expect(
            afterResetPrompt.hasSuffix("--- new message ---\nAfter reset question"),
            "user message follows the Default authority")
        #expect(lastVisibleUserText(launcher) == "After reset question")

        await runtime.close(handle)
    }

    /// A RESUMED provider session may retain an earlier strategy revision in
    /// its context, so its first turn carries the current committed revision
    /// as explicit per-request authority — custom now, or explicit Default
    /// after a reset.
    @Test func resumedFirstTurnCarriesCurrentStrategyAuthority() async throws {
        let directory = try makeChatDirectory("resume-strategy")
        defer { removeFixture(directory) }

        let store = try TestStoreFactory.inMemory()
        let custom = try saveStrategy(
            store, name: "Resume strategy",
            instructions: "Prefer story-analysis organization.",
            expectedRevision: nil)
        let chat = try store.createChat(kind: .edit, title: "Resume chat")

        // First resumed turn under the custom strategy: the fake backend
        // reports a successful resume, so the launcher composes the resumed
        // message (RUN ENVIRONMENT + per-turn strategy + user message).
        let customBackend = FakeAgentBackend(resumeSessionID: "resumed-custom")
        let (customRuntime, customLauncher) = makeRuntime(
            store: store, chatID: chat.id, backend: customBackend, directory: directory)
        let customHandle = try await startSession(
            runtime: customRuntime, chatID: chat.id, resuming: "resumed-custom")
        try await customRuntime.submitTurn(
            turn("Resume question", id: "resume-custom"), in: customHandle)
        try await waitForSendCount(customBackend, atLeast: 1)
        let resumedPrompt = await customBackend.sentTexts.first ?? ""
        assertCustomStrategyRendered(resumedPrompt, strategy: custom, context: "resumed first turn")
        #expect(
            resumedPrompt.hasSuffix("# USER MESSAGE\nResume question"),
            "resumed turn keeps the run-env + user-message composition")
        #expect(lastVisibleUserText(customLauncher) == "Resume question")
        await customRuntime.close(customHandle)

        // Reset to Default, then resume again in a fresh runtime/session: the
        // resumed context may still hold the custom strategy, so the new first
        // turn must carry explicit Default authority.
        try resetToDefault(store, after: custom)
        let defaultBackend = FakeAgentBackend(resumeSessionID: "resumed-default")
        let (defaultRuntime, defaultLauncher) = makeRuntime(
            store: store, chatID: chat.id, backend: defaultBackend, directory: directory)
        let defaultHandle = try await startSession(
            runtime: defaultRuntime, chatID: chat.id, resuming: "resumed-default")
        try await defaultRuntime.submitTurn(
            turn("After reset resume", id: "resume-default"), in: defaultHandle)
        try await waitForSendCount(defaultBackend, atLeast: 1)
        let afterResetResumedPrompt = await defaultBackend.sentTexts.first ?? ""
        assertDefaultStrategyRendered(
            afterResetResumedPrompt, context: "post-reset resumed first turn", superseded: custom)
        #expect(!afterResetResumedPrompt.contains("Existing pages"), "no page inventory")
        #expect(
            afterResetResumedPrompt.hasSuffix("# USER MESSAGE\nAfter reset resume"))
        #expect(lastVisibleUserText(defaultLauncher) == "After reset resume")
        await defaultRuntime.close(defaultHandle)
    }

    // MARK: - Helpers

    private func makeChatDirectory(_ label: String) throws -> URL {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appendingPathComponent("tmp", isDirectory: true)
            .appendingPathComponent("strategy-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func removeFixture(_ directory: URL) {
        do { try FileManager.default.removeItem(at: directory) }
        catch { Issue.record("Failed to remove strategy run fixture: \(error)") }
    }

    private func lastVisibleUserText(_ launcher: AgentLauncher) -> String? {
        launcher.events.compactMap { event -> String? in
            if case .userText(let text) = event { return text }
            return nil
        }.last
    }

    private func waitForSendCount(
        _ backend: FakeAgentBackend,
        atLeast target: Int,
        fileID: String = #fileID,
        line: Int = #line
    ) async throws {
        // Bounded, non-blocking wait (Task.sleep — never parks the cooperative
        // pool): the launcher delivers the turn on the main actor after the
        // generation gate releases.
        for _ in 0..<200 {
            if await backend.sendCount >= target { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        let count = await backend.sendCount
        throw TestFailure(
            "timed out waiting for \(target) sends (saw \(count))",
            fileID: fileID, line: line)
    }

}

/// Minimal extraction stub for the launcher pair fixture (chat never invokes
/// it; the coordinator requires a local extractor factory).
private struct StrategyRunStubExtractor: MarkdownExtractor {
    var displayName: String { "strategy-run-stub" }

    func readiness() async -> ExtractionReadiness { .ready }

    func convert(
        pdfData: Data,
        filename: String,
        onProgress: (@Sendable (String) -> Void)?
    ) async throws -> String {
        "stub"
    }
}

/// Swift Testing has no message-carrying failure type; a tiny Error with a
/// message keeps the fixture asserts readable.
private struct TestFailure: Error, CustomStringConvertible {
    let description: String
    let fileID: String
    let line: Int

    init(_ description: String, fileID: String = #fileID, line: Int = #line) {
        self.description = description
        self.fileID = fileID
        self.line = line
    }
}
#endif
