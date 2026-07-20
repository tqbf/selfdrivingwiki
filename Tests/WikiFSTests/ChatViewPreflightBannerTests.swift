import Foundation
import Testing
import WikiFSEngine
import WikiFSCore
@testable import WikiFS
@testable import WikiFSEngine

/// Tests for `ChatView.shouldShowPreflightBanner` (#613) — surfaces a
/// previously-captured `AgentLauncher.preflightError` in the chat surface so a
/// rolled-back chat doesn't silently revert to the empty draft composer.
///
/// The preflight error is ALREADY captured at the right choke-point
/// (`AgentLauncher.startInteractiveQuery` / `backend.start` catch); the gap is
/// purely UI: `ChatView` never read it. These tests pin the rendering predicate
/// (visibility matrix + text-pass-through) plus an integration check that the
/// rollback behavior in `AgentOperationRunner.startChat` is preserved (the
/// banner is purely additive on top of the rollback; it does NOT replace it).
///
/// Pure predicate tests — no SwiftUI view tree required (follows the
/// `composerCaptionText` / `canSendPredicate` pattern in `ChatViewD2Tests`).
@MainActor
@Suite struct ChatViewPreflightBannerTests {

    // MARK: - Visibility matrix

    /// Success path: no preflight error → no banner (zero behavioral change).
    @Test func bannerHidden_whenPreflightErrorIsNil() {
        #expect(!ChatView.shouldShowPreflightBanner(
            preflightError: nil,
            chatID: nil,
            isLiveChat: false))
    }

    @Test func bannerHidden_whenPreflightErrorIsEmpty() {
        // Defensive: an empty-string preflightError (shouldn't happen in
        // practice but guards against a future regression at the capture
        // site) still renders no banner.
        #expect(!ChatView.shouldShowPreflightBanner(
            preflightError: "",
            chatID: nil,
            isLiveChat: false))
    }

    /// AC.1: post-rollback draft state — preflightError set, chatID nil (the
    /// rolled-back tab reverted to .newChat), no live session. Banner shows.
    @Test func bannerShown_whenPreflightErrorSet_inDraftState() {
        #expect(ChatView.shouldShowPreflightBanner(
            preflightError: "Provider 'Claude' has no command configured.",
            chatID: nil,
            isLiveChat: false))
    }

    /// A persisted, non-live chat: preflightError set, chatID non-nil but not
    /// the active session. Banner still surfaces (a stale state the user
    /// lands on when a rolled-back tab couldn't be retargeted).
    @Test func bannerShown_whenPreflightErrorSet_onPersistedNonLiveChat() {
        let id = PageID(rawValue: "01J" + String(repeating: "A", count: 22))
        #expect(ChatView.shouldShowPreflightBanner(
            preflightError: "An ingestion is in progress.",
            chatID: id,
            isLiveChat: false))
    }

    /// AC.2: live chat — a session is actively streaming. preflightError would
    /// be nil in practice; the predicate guards against rendering a stale
    /// banner alongside a live streaming session.
    @Test func bannerHidden_whenPreflightErrorSet_onLiveChat() {
        let id = PageID(rawValue: "01J" + String(repeating: "A", count: 22))
        #expect(!ChatView.shouldShowPreflightBanner(
            preflightError: "stale error",
            chatID: id,
            isLiveChat: true))
    }

    // MARK: - Banner text matches preflightError content (AC.3)

    /// AC.3: the banner renders the `preflightError` text verbatim — no
    /// truncation, no rewriting. The static accessor forwards the message
    /// as-is when the banner is showing.
    @Test func bannerMessage_forwardsPreflightErrorVerbatim() {
        let msg = "Failed to launch claude: permission denied"
        let bannerText = ChatView.preflightBannerMessage(
            preflightError: msg,
            chatID: nil,
            isLiveChat: false)
        #expect(bannerText == msg)
    }

    @Test func bannerMessage_isNil_whenPreflightErrorIsNil() {
        #expect(ChatView.preflightBannerMessage(
            preflightError: nil,
            chatID: nil,
            isLiveChat: false) == nil)
    }

    @Test func bannerMessage_isNil_whenLiveChat() {
        let id = PageID(rawValue: "01J" + String(repeating: "A", count: 22))
        #expect(ChatView.preflightBannerMessage(
            preflightError: "stale error",
            chatID: id,
            isLiveChat: true) == nil)
    }

    /// The message preserves the preflightError's multi-line / colon-heavy
    /// content exactly (the real capture sites embed provider names, "Settings
    /// → Agents" tips, and underlying error text). No rewriting at the render
    /// seam.
    @Test func bannerMessage_preservesMultiLineAndSpecialCharacters() {
        let msg = """
        No model selected for provider 'OpenCode'. \
        Open Settings → Agents and pick a model before running.
        """
        let bannerText = ChatView.preflightBannerMessage(
            preflightError: msg,
            chatID: nil,
            isLiveChat: false)
        #expect(bannerText == msg)
    }

    // MARK: - Rollback behavior preserved (AC.5)

    /// AC.5: the rollback path in `AgentOperationRunner.startChat` is
    /// unchanged — the dead chat row STILL gets rolled back when
    /// `preflightError` is set after `startInteractiveQuery`. The banner is
    /// purely additive UI on top of the rollback; it does NOT replace it.
    ///
    /// Drives the SpawnModelGuard path: a launcher with NO selected model
    /// for its resolved provider triggers the guard inside
    /// `startInteractiveQuery`, which sets `preflightError` and returns
    /// early (Scenario A in `plans/preflight-error-chat.md`). The freshly-
    /// created chat row is then rolled back by `startChat`.
    @Test func rollbackStillHappens_whenStartChatPreflightFails() async throws {
        let (model, _) = try tempModel()
        let launcher = try makeRefusingLauncher()

        // Pre-state: zero chats.
        model.reloadChats()
        #expect(model.chats.isEmpty)
        #expect(launcher.preflightError == nil)

        await AgentOperationRunner.startChat(
            firstMessage: "hello",
            launcher: launcher,
            store: model,
            wikiID: "wiki-test",
            changeSignaler: StubChangeSignaler(),
            wikictlDirectory: "/tmp/wiki-test"
        )

        // AC.5: the dead chat row was rolled back — store is empty.
        // (reloadChats forces a sync read after the async bus reload dequeues;
        // `rollbackChatCreation`'s store.deleteChat is synchronous, so the row
        // is gone immediately even before the bus-driven reloadFromStore fires.)
        model.reloadChats()
        #expect(model.chats.isEmpty)

        // The preflight error is set (SpawnModelGuard fired).
        #expect(launcher.preflightError?.contains("No model selected") == true)

        // And the banner predicate fires for this state — the user would
        // see the message instead of an empty draft composer.
        #expect(ChatView.shouldShowPreflightBanner(
            preflightError: launcher.preflightError,
            chatID: nil,
            isLiveChat: false))
    }

    /// AC.5 corollary: the banner predicate is INDEPENDENT of the rollback
    /// logic — setting `launcher.preflightError` directly (without driving
    /// `startChat`) still surfaces the banner. This pins the contract that
    /// the rendering layer doesn't re-implement the rollback trigger; it just
    /// reads `preflightError` as a render-time input.
    @Test func bannerShown_whenPreflightErrorSetDirectly_withoutRollback() {
        let launcher = AgentLauncher()
        #expect(launcher.preflightError == nil)

        launcher.preflightError = "Could not create a scratch working directory for the agent."

        // The banner surfaces the error regardless of whether `startChat`
        // was the one that set it. The rollback flow in `startChat` is a
        // separate concern — `ChatView` just reads the field it's handed.
        #expect(ChatView.shouldShowPreflightBanner(
            preflightError: launcher.preflightError,
            chatID: nil,
            isLiveChat: false))
        #expect(launcher.preflightError == "Could not create a scratch working directory for the agent.")
    }

    // MARK: - Helpers

    /// Mirrors `ChatViewD2Tests.tempModel()`: a throwaway `WikiStoreModel`
    /// backed by a `GRDBWikiStore` in a tmp dir, so chat row CRUD works.
    private func tempModel() throws -> (WikiStoreModel, GRDBWikiStore) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-preflight-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try GRDBWikiStore(databaseURL: dir.appendingPathComponent("WikiFS.sqlite"))
        return (WikiStoreModel(store: store), store)
    }

    /// Mirrors `AgentLauncherSpawnRefusalTests.makeRefusingLauncher()`: a
    /// launcher whose `providersConfig()` returns a config with the default
    /// provider (opencode) having NO `selectedModelId`. The
    /// `SpawnModelGuard.validate` inside `startInteractiveQuery` therefore
    /// sets `preflightError` and returns early — no real subprocess spawned.
    ///
    /// per-op-provider: `startInteractiveQuery` now resolves its provider via
    /// `providersConfig().providerForChat()` (NOT `resolveSelectedProvider`).
    /// So we pre-write a config whose DEFAULT provider is opencode with NO
    /// selected model — `providerForChat()` returns opencode (no chat pin →
    /// fallback to default) and the guard fires on the nil-model state.
    private func makeRefusingLauncher() throws -> AgentLauncher {
        let launcher = AgentLauncher()
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("preflight-banner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        // Pre-write a config whose DEFAULT provider is opencode with no model.
        // #663: `.opencodeDefault` was deleted; built inline.
        var opencodeDefault = AgentProvider(
            id: "opencode",
            label: "OpenCode",
            command: ["opencode", "acp"],
            env: [:],
            enabled: true,
            isDefault: false)
        opencodeDefault.isDefault = true
        let configNoModel = AgentProvidersConfig(
            providers: [opencodeDefault])
        try configNoModel.save(to: tmp)
        launcher.resolveProvidersContainerDirectory = { tmp }
        return launcher
    }
}

/// Minimal `ChangeSignaler` stub for `AgentOperationRunner` paths that need
/// one but aren't exercising the File Provider plumbing.
@MainActor
private final class StubChangeSignaler: ChangeSignaler {
    var path: String? = nil
    func signalChange() async {}
}
