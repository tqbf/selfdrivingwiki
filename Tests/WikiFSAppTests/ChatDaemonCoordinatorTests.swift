#if os(macOS)
import Foundation
import Testing
@testable import WikiFSCore
@testable import WikiFSEngine
@testable import WikiFS

/// Tests for `ChatDaemonCoordinator` (Phase C4) — the app-side registry + event
/// router + command wrapper for daemon-hosted chat sessions. These are pure
/// (no live XPC): a `StubChatDaemonCommands` stands in for the
/// `DaemonWorkloadClient`, and `ingestForTesting` drives the event router.
@MainActor
struct ChatDaemonCoordinatorTests {

    // MARK: - Session registry

    @Test func sessionForChatID_isGetOrCreate_sameInstance() {
        let coord = makeCoordinator()
        let a = coord.session(for: PageID(rawValue: "chat-1"))
        let b = coord.session(for: PageID(rawValue: "chat-1"))
        #expect(a === b)
        #expect(a.chatID == .chat(PageID(rawValue: "chat-1")))
    }

    @Test func sessionForNil_returnsSharedDraftSession() {
        let coord = makeCoordinator()
        let draft = coord.session(for: nil)
        #expect(draft.chatID == .draft)
        // Repeated nil lookups return the same draft instance.
        #expect(coord.session(for: nil) === draft)
    }

    @Test func discard_removesCachedSession() {
        let coord = makeCoordinator()
        let first = coord.session(for: PageID(rawValue: "chat-1"))
        coord.discard(chatID: PageID(rawValue: "chat-1"))
        let second = coord.session(for: PageID(rawValue: "chat-1"))
        // After discard, a fresh session is created.
        #expect(first !== second)
    }

    @Test func resetDraft_replacesDraftSession() {
        let coord = makeCoordinator()
        let draft = coord.session(for: nil)
        coord.resetDraft()
        #expect(coord.session(for: nil) !== draft)
    }

    // MARK: - Event routing

    @Test func ingestForTesting_deliversChatEventToOpenSession() {
        let coord = makeCoordinator()
        let session = coord.session(for: PageID(rawValue: "chat-1"))
        coord.ingestForTesting(.chatEvent(chatID: "chat-1", event: .assistantText("hello")))
        #expect(session.events == [.assistantText("hello")])
    }

    @Test func ingestForTesting_doesNotCreateSessionForUnopenedChat() {
        // An envelope for a chat with no open session is consumed by the
        // running-set tracker but does NOT materialize a session.
        let coord = makeCoordinator()
        coord.ingestForTesting(.chatEvent(chatID: "chat-orphan", event: .assistantText("x")))
        #expect(coord.isChatGenerating(PageID(rawValue: "chat-orphan")) == false)
    }

    // MARK: - Running-set aggregate (sidebar liveness)

    @Test func isChatGenerating_trueWhileAnswering() {
        let coord = makeCoordinator()
        coord.ingestForTesting(.chatState(chatID: "chat-run", update: ChatStateUpdate(
            isRunning: true, isGenerating: true, isAwaitingGenerationSlot: false,
            preflightError: nil, thinkingOption: nil, usageData: nil,
            logFileURL: nil, debugFolderURL: nil, runKindRaw: nil, runStartedAt: nil)))
        #expect(coord.isChatGenerating(PageID(rawValue: "chat-run")))
        #expect(coord.anyChatGenerating)
    }

    @Test func isChatGenerating_falseAfterSessionEnds() {
        let coord = makeCoordinator()
        coord.ingestForTesting(.chatState(chatID: "chat-run", update: ChatStateUpdate(
            isRunning: true, isGenerating: true, isAwaitingGenerationSlot: false,
            preflightError: nil, thinkingOption: nil, usageData: nil,
            logFileURL: nil, debugFolderURL: nil, runKindRaw: nil, runStartedAt: nil)))
        coord.ingestForTesting(.chatState(chatID: "chat-run", update: ChatStateUpdate(
            isRunning: false, isGenerating: false, isAwaitingGenerationSlot: false,
            preflightError: nil, thinkingOption: nil, usageData: nil,
            logFileURL: nil, debugFolderURL: nil, runKindRaw: nil, runStartedAt: nil)))
        #expect(!coord.isChatGenerating(PageID(rawValue: "chat-run")))
        #expect(!coord.anyChatGenerating)
    }

    @Test func runningStateToken_bumpsOnRunningStateChange() {
        let coord = makeCoordinator()
        let before = coord.runningStateToken

        // Start → token bumps.
        coord.ingestForTesting(.chatState(chatID: "chat-run", update: ChatStateUpdate(
            isRunning: true, isGenerating: true, isAwaitingGenerationSlot: false,
            preflightError: nil, thinkingOption: nil, usageData: nil,
            logFileURL: nil, debugFolderURL: nil, runKindRaw: nil, runStartedAt: nil)))
        let afterStart = coord.runningStateToken
        #expect(afterStart == before + 1)

        // Duplicate running envelope (no change) → token does NOT bump.
        coord.ingestForTesting(.chatState(chatID: "chat-run", update: ChatStateUpdate(
            isRunning: true, isGenerating: true, isAwaitingGenerationSlot: false,
            preflightError: nil, thinkingOption: nil, usageData: nil,
            logFileURL: nil, debugFolderURL: nil, runKindRaw: nil, runStartedAt: nil)))
        #expect(coord.runningStateToken == afterStart)

        // Stop → token bumps again.
        coord.ingestForTesting(.chatState(chatID: "chat-run", update: ChatStateUpdate(
            isRunning: false, isGenerating: false, isAwaitingGenerationSlot: false,
            preflightError: nil, thinkingOption: nil, usageData: nil,
            logFileURL: nil, debugFolderURL: nil, runKindRaw: nil, runStartedAt: nil)))
        #expect(coord.runningStateToken == afterStart + 1)
    }

    @Test func isChatGenerating_reflectsOpenSessionGeneratingFlag() {
        // An open session that reports generating via hydrate also counts.
        let coord = makeCoordinator()
        let session = coord.session(for: PageID(rawValue: "chat-open"))
        session.hydrate(from: ChatSessionState(
            chatID: "chat-open", events: [],
            isRunning: true, isGenerating: true, isAwaitingGenerationSlot: false,
            preflightError: nil, thinkingOption: nil, usageData: nil,
            logFileURL: nil, debugFolderURL: nil, runKindRaw: nil, runStartedAt: nil))
        #expect(coord.isChatGenerating(PageID(rawValue: "chat-open")))
    }

    @Test func isChatGenerating_falseForWarmIdleInteractiveSession() {
        // REGRESSION: the stuck "responding…" badge. For an interactive chat,
        // `AgentLauncher.isRunning` means "the agent process is alive ACROSS
        // TURNS", so it stays true while the session sits idle waiting for the
        // next message — the daemon pushes exactly this state
        // (running=true gen=false) the moment a turn ends, and kept pushing
        // nothing after, because nothing had changed.
        //
        // The badge previously keyed off `isRunning || isGenerating`, so it
        // latched on for the whole life of the session. It must key off
        // `isGenerating` alone (the flag `AgentLauncher` documents as the one
        // "every UI spinner / Stop affordance keys off").
        let coord = makeCoordinator()
        coord.ingestForTesting(.chatState(chatID: "chat-warm", update: ChatStateUpdate(
            isRunning: true, isGenerating: true, isAwaitingGenerationSlot: false,
            preflightError: nil, thinkingOption: nil, usageData: nil,
            logFileURL: nil, debugFolderURL: nil, runKindRaw: nil, runStartedAt: nil)))
        #expect(coord.isChatGenerating(PageID(rawValue: "chat-warm")), "badge on while answering")

        // Turn ends; the process stays warm for the next message.
        coord.ingestForTesting(.chatState(chatID: "chat-warm", update: ChatStateUpdate(
            isRunning: true, isGenerating: false, isAwaitingGenerationSlot: false,
            preflightError: nil, thinkingOption: nil, usageData: nil,
            logFileURL: nil, debugFolderURL: nil, runKindRaw: nil, runStartedAt: nil)))
        #expect(!coord.isChatGenerating(PageID(rawValue: "chat-warm")), "badge must clear when the turn ends")
        #expect(!coord.anyChatGenerating)
    }

    @Test func isChatGenerating_falseForOpenSessionThatIsMerelyAlive() {
        // Same contract via the hydrate path rather than the envelope path.
        let coord = makeCoordinator()
        let session = coord.session(for: PageID(rawValue: "chat-warm-hydrate"))
        session.hydrate(from: ChatSessionState(
            chatID: "chat-warm-hydrate", events: [],
            isRunning: true, isGenerating: false, isAwaitingGenerationSlot: false,
            preflightError: nil, thinkingOption: nil, usageData: nil,
            logFileURL: nil, debugFolderURL: nil, runKindRaw: nil, runStartedAt: nil))
        #expect(!coord.isChatGenerating(PageID(rawValue: "chat-warm-hydrate")))
    }

    // MARK: - Commands (forwarded to the daemon client stub)

    @Test func startChat_forwardsRequestAndReturnsChatID() async throws {
        let stub = StubChatDaemonCommands()
        stub.nextStartChatID = "01NEW"
        let coord = ChatDaemonCoordinator(client: stub, eventSink: DaemonQueueEventSink())
        let id = try await coord.startChat(wikiID: "wiki-1", firstMessage: "hi")
        #expect(id == "01NEW")
        let req = try #require(stub.startChatCalls.first)
        #expect(req.wikiID == "wiki-1")
        #expect(req.firstMessage == "hi")
    }

    @Test func continueChat_forwardsTypedRequest() async throws {
        let stub = StubChatDaemonCommands()
        let coord = ChatDaemonCoordinator(client: stub, eventSink: DaemonQueueEventSink())
        try await coord.continueChat(wikiID: "wiki-1", chatID: "chat-1", message: "more")
        let req = try #require(stub.continueChatCalls.first)
        #expect(req.wikiID == "wiki-1")
        #expect(req.chatID == "chat-1")
        #expect(req.message == "more")
    }

    @Test func sendMessage_forwardsChatIDAndMessage() async throws {
        let stub = StubChatDaemonCommands()
        let coord = ChatDaemonCoordinator(client: stub, eventSink: DaemonQueueEventSink())
        try await coord.sendMessage(chatID: "chat-1", message: "follow up")
        #expect(stub.sendCalls.count == 1)
        #expect(stub.sendCalls.first?.0 == "chat-1")
        #expect(stub.sendCalls.first?.1 == "follow up")
    }

    @Test func stop_swallowsErrorsAndForwardsID() async {
        let stub = StubChatDaemonCommands(shouldThrow: true)
        let coord = ChatDaemonCoordinator(client: stub, eventSink: DaemonQueueEventSink())
        // Best-effort: a throwing stop is swallowed (logged), not rethrown.
        await coord.stop(chatID: "chat-1")
        #expect(stub.stopCalls == ["chat-1"])
    }

    @Test func resolvePermission_forwardsApproveAndOptionId() async throws {
        let stub = StubChatDaemonCommands()
        let coord = ChatDaemonCoordinator(client: stub, eventSink: DaemonQueueEventSink())
        await coord.resolvePermission(chatID: "chat-1", optionId: "allow_once", approve: true)
        let req = try #require(stub.resolveCalls.first)
        #expect(req.chatID == "chat-1")
        #expect(req.optionId == "allow_once")
        #expect(req.approve)
    }

    // MARK: - Phase C4 follow-up: setChatConfigOption (7th XPC method)

    @Test func setThinkingEffort_forwardsConfigOptionRequest() async throws {
        let stub = StubChatDaemonCommands()
        let coord = ChatDaemonCoordinator(client: stub, eventSink: DaemonQueueEventSink())
        await coord.setThinkingEffort(chatID: "chat-1", value: "high")
        let req = try #require(stub.configOptionCalls.first)
        #expect(req.chatID == "chat-1")
        #expect(req.option == "thought_level")
        #expect(req.value == "high")
    }

    @Test func setThinkingEffort_swallowsClientError() async {
        // A throwing client must not crash; the optimistic flip stays.
        let stub = StubChatDaemonCommands(shouldThrow: true)
        let coord = ChatDaemonCoordinator(client: stub, eventSink: DaemonQueueEventSink())
        await coord.setThinkingEffort(chatID: "chat-1", value: "high")
        #expect(stub.configOptionCalls.count == 1)
    }

    @Test func session_wiresOnSetChatConfigOptionCallback() async throws {
        // When the coordinator creates a session, the session's
        // onSetChatConfigOption closure should be wired so
        // setThinkingEffort routes through the daemon.
        let stub = StubChatDaemonCommands()
        let coord = ChatDaemonCoordinator(client: stub, eventSink: DaemonQueueEventSink())
        let session = coord.session(for: PageID(rawValue: "chat-wired"))
        session.thinkingOption = ThinkingEffortOption(
            configId: "thought_level", currentValue: "low",
            choices: [ThinkingEffortOption.Choice(value: "low", label: "Low"),
                      ThinkingEffortOption.Choice(value: "high", label: "High")])
        session.setThinkingEffort("high")
        // The callback fires in a detached Task; poll until it lands.
        for _ in 0..<100 {
            if !stub.configOptionCalls.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(session.thinkingOption?.currentValue == "high")
        let req = try #require(stub.configOptionCalls.first)
        #expect(req.chatID == "chat-wired")
        #expect(req.option == "thought_level")
        #expect(req.value == "high")
    }

    @Test func draftSession_doesNotWireConfigOptionCallback() {
        // The draft session (nil chatID) should NOT wire the callback — there
        // is no real chatID to target on the daemon.
        let stub = StubChatDaemonCommands()
        let coord = ChatDaemonCoordinator(client: stub, eventSink: DaemonQueueEventSink())
        let draft = coord.session(for: nil)
        #expect(draft.onSetChatConfigOption == nil)
    }

    @Test func rehydrate_hydratesOpenSessionFromStubState() async {
        let stub = StubChatDaemonCommands()
        stub.sessionState = ChatSessionState(
            chatID: "chat-1", events: [.userText("seed")],
            isRunning: true, isGenerating: true, isAwaitingGenerationSlot: false,
            preflightError: nil, thinkingOption: nil, usageData: nil,
            logFileURL: nil, debugFolderURL: nil, runKindRaw: nil, runStartedAt: nil)
        let coord = ChatDaemonCoordinator(client: stub, eventSink: DaemonQueueEventSink())
        await coord.rehydrate(chatID: PageID(rawValue: "chat-1"))
        let session = coord.session(for: PageID(rawValue: "chat-1"))
        #expect(session.events == [.userText("seed")])
        #expect(session.isRunning)
        #expect(coord.isChatGenerating(PageID(rawValue: "chat-1")))
    }

    @Test func rehydrate_swallowsClientFailure() async {
        // A throwing chatSessionState (e.g. daemon evicted the session) must
        // not crash; the session keeps its prior state.
        let stub = StubChatDaemonCommands(shouldThrow: true)
        let coord = ChatDaemonCoordinator(client: stub, eventSink: DaemonQueueEventSink())
        await coord.rehydrate(chatID: PageID(rawValue: "chat-1"))
        // No assertion crash; session simply remains default-empty.
        #expect(coord.session(for: PageID(rawValue: "chat-1")).events.isEmpty)
    }

    @Test func rehydrateFailure_clearsLivenessSoPersistedRowsRender() async {
        // Regression: the daemon throws `noSession` for any chat whose launcher
        // it has evicted (every chat from a previous app run). If the mirror is
        // left claiming liveness, `ChatDetailView.isLiveChat` is true with zero
        // events and the view renders an empty live stream — a chat with a full
        // persisted transcript showed "Ask a question to start a chat.".
        let stub = StubChatDaemonCommands(shouldThrow: true)
        let coord = ChatDaemonCoordinator(client: stub, eventSink: DaemonQueueEventSink())
        await coord.rehydrate(chatID: PageID(rawValue: "chat-evicted"))
        let session = coord.session(for: PageID(rawValue: "chat-evicted"))
        #expect(session.activeChatID == nil)
        #expect(session.isInteractiveSession == false)
        #expect(coord.isChatGenerating(PageID(rawValue: "chat-evicted")) == false)
    }

    @Test func freshSessionDoesNotClaimLivenessBeforeHydration() async {
        // A mirror the daemon has never reported on must not pass the
        // source-of-truth rule: `activeChatID` is daemon-derived, so it stays
        // nil until `hydrate`/`applyStateUpdate` sets it.
        let coord = makeCoordinator()
        #expect(coord.session(for: PageID(rawValue: "chat-new")).activeChatID == nil)
        #expect(coord.session(for: nil).activeChatID == nil)
    }

    @Test func rehydrateIdleState_leavesSessionNotLive() async {
        // The daemon still holds the launcher but reports it idle — the mirror
        // must render persisted rows, not the launcher's in-memory events.
        let stub = StubChatDaemonCommands()
        stub.sessionState = ChatSessionState(
            chatID: "chat-idle", events: [],
            isRunning: false, isGenerating: false, isAwaitingGenerationSlot: false,
            preflightError: nil, thinkingOption: nil, usageData: nil,
            logFileURL: nil, debugFolderURL: nil, runKindRaw: nil, runStartedAt: nil)
        let coord = ChatDaemonCoordinator(client: stub, eventSink: DaemonQueueEventSink())
        await coord.rehydrate(chatID: PageID(rawValue: "chat-idle"))
        #expect(coord.session(for: PageID(rawValue: "chat-idle")).activeChatID == nil)
        #expect(coord.isChatGenerating(PageID(rawValue: "chat-idle")) == false)
    }

    // MARK: - runningStateToken (rehydrate path)

    @Test func rehydrateGenerating_bumpsRunningStateToken() async {
        let stub = StubChatDaemonCommands()
        stub.sessionState = ChatSessionState(
            chatID: "chat-run", events: [],
            isRunning: true, isGenerating: true, isAwaitingGenerationSlot: false,
            preflightError: nil, thinkingOption: nil, usageData: nil,
            logFileURL: nil, debugFolderURL: nil, runKindRaw: nil, runStartedAt: nil)
        let coord = ChatDaemonCoordinator(client: stub, eventSink: DaemonQueueEventSink())
        let before = coord.runningStateToken
        await coord.rehydrate(chatID: PageID(rawValue: "chat-run"))
        #expect(coord.runningStateToken == before + 1)
        #expect(coord.isChatGenerating(PageID(rawValue: "chat-run")))
    }

    @Test func rehydrateIdle_doesNotBumpTokenWhenAlreadyIdle() async {
        let stub = StubChatDaemonCommands()
        stub.sessionState = ChatSessionState(
            chatID: "chat-idle", events: [],
            isRunning: false, isGenerating: false, isAwaitingGenerationSlot: false,
            preflightError: nil, thinkingOption: nil, usageData: nil,
            logFileURL: nil, debugFolderURL: nil, runKindRaw: nil, runStartedAt: nil)
        let coord = ChatDaemonCoordinator(client: stub, eventSink: DaemonQueueEventSink())
        let before = coord.runningStateToken
        await coord.rehydrate(chatID: PageID(rawValue: "chat-idle"))
        // Was idle, stays idle → no change → no bump.
        #expect(coord.runningStateToken == before)
    }

    @Test func rehydrateFailure_bumpsTokenWhenClearingPriorLiveness() async {
        // A chat that was running (token already bumped) then gets a rehydrate
        // failure (daemon evicted the session). Clearing the stale liveness
        // claim must bump the token so the sidebar drops "responding…".
        let stub = StubChatDaemonCommands()
        stub.sessionState = ChatSessionState(
            chatID: "chat-evicted", events: [],
            isRunning: true, isGenerating: true, isAwaitingGenerationSlot: false,
            preflightError: nil, thinkingOption: nil, usageData: nil,
            logFileURL: nil, debugFolderURL: nil, runKindRaw: nil, runStartedAt: nil)
        let coord = ChatDaemonCoordinator(client: stub, eventSink: DaemonQueueEventSink())
        await coord.rehydrate(chatID: PageID(rawValue: "chat-evicted"))
        let afterRunning = coord.runningStateToken
        #expect(coord.isChatGenerating(PageID(rawValue: "chat-evicted")))

        // Now the daemon evicts the session — rehydrate throws.
        stub.shouldThrow = true
        await coord.rehydrate(chatID: PageID(rawValue: "chat-evicted"))
        #expect(coord.runningStateToken == afterRunning + 1)
        // Both liveness sources clear: generatingChatIDs via setChatGenerating, and
        // the session's isGenerating via markNotLive (which now clears the flags).
        #expect(!coord.isChatGenerating(PageID(rawValue: "chat-evicted")))
    }

    // MARK: - Helpers

    private func makeCoordinator() -> ChatDaemonCoordinator {
        ChatDaemonCoordinator(client: StubChatDaemonCommands(), eventSink: DaemonQueueEventSink())
    }
}

/// A stub `ChatDaemonCommands` that records every call and returns
/// configurable results. `@unchecked Sendable` so it can cross the
/// `ChatDaemonCommands: Sendable` boundary; tests are `@MainActor` so access
/// is race-free.
@MainActor
final class StubChatDaemonCommands: ChatDaemonCommands, @unchecked Sendable {
    var startChatCalls: [ChatStartRequest] = []
    var continueChatCalls: [ChatContinueRequest] = []
    var sendCalls: [(String, String)] = []
    var stopCalls: [String] = []
    var resolveCalls: [ChatPermissionResolveRequest] = []
    var sessionStateRequests: [String] = []
    var configOptionCalls: [ChatConfigOptionRequest] = []

    var nextStartChatID: String = "stub-chat-id"
    var sessionState: ChatSessionState?
    var shouldThrow: Bool

    init(shouldThrow: Bool = false) {
        self.shouldThrow = shouldThrow
    }

    func startChat(_ request: ChatStartRequest) async throws -> String {
        startChatCalls.append(request)
        if shouldThrow { throw StubError.throwing }
        return nextStartChatID
    }

    func continueChat(_ request: ChatContinueRequest) async throws {
        continueChatCalls.append(request)
        if shouldThrow { throw StubError.throwing }
    }

    func sendChatMessage(chatID: String, message: String) async throws {
        sendCalls.append((chatID, message))
        if shouldThrow { throw StubError.throwing }
    }

    func stopChat(_ chatID: String) async throws {
        stopCalls.append(chatID)
        if shouldThrow { throw StubError.throwing }
    }

    func chatSessionState(_ chatID: String) async throws -> ChatSessionState {
        sessionStateRequests.append(chatID)
        if shouldThrow { throw StubError.throwing }
        return sessionState ?? ChatSessionState(
            chatID: chatID, events: [],
            isRunning: false, isGenerating: false, isAwaitingGenerationSlot: false,
            preflightError: nil, thinkingOption: nil, usageData: nil,
            logFileURL: nil, debugFolderURL: nil, runKindRaw: nil, runStartedAt: nil)
    }

    func resolveChatPermission(_ request: ChatPermissionResolveRequest) async throws {
        resolveCalls.append(request)
        if shouldThrow { throw StubError.throwing }
    }

    func setChatConfigOption(_ request: ChatConfigOptionRequest) async throws {
        configOptionCalls.append(request)
        if shouldThrow { throw StubError.throwing }
    }
}

private enum StubError: Error { case throwing }
#endif
