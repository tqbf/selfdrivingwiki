import Foundation
import Testing
@testable import WikiFS
import WikiFSCore

/// Tests for issue #235: preventing silent hangs when starting a chat during
/// an ingest's extraction phase.
///
/// Three concerns:
/// 1. The `shouldBlockEditStart` predicate — chat preflight must block during
///    extraction (via `isIngestInProgress`), not just during the agent run
///    (via `isAgentRunning`). Chats are always write-capable, so they are
///    always subject to the edit-lock preflight (the read-only Ask mode is gone).
/// 2. The `isIngestInProgress` lifecycle on `WikiStoreModel`.
/// 3. The `composerCaptionText` predicate — the waiting state must surface as
///    visible text (not just a tooltip).
@MainActor
struct Issue235IngestExtractionLockTests {

    // MARK: - shouldBlockEditStart predicate

    @Test func chatBlockedWhenIngestInProgress() {
        // Extraction phase: isAgentRunning is false but isIngestInProgress is true.
        // Chat must be blocked (the core #235 fix).
        #expect(AgentOperationRunner.shouldBlockEditStart(
            isAgentRunning: false, isIngestInProgress: true))
    }

    @Test func chatBlockedWhenAgentRunning() {
        // Agent phase: isAgentRunning is true. Chat is blocked (existing behavior).
        #expect(AgentOperationRunner.shouldBlockEditStart(
            isAgentRunning: true, isIngestInProgress: false))
    }

    @Test func chatBlockedWhenBothInProgress() {
        // Both flags set — still blocked.
        #expect(AgentOperationRunner.shouldBlockEditStart(
            isAgentRunning: true, isIngestInProgress: true))
    }

    @Test func chatAllowedWhenIdle() {
        // Neither flag set — no ingest, no agent. Chat is free to start.
        #expect(!AgentOperationRunner.shouldBlockEditStart(
            isAgentRunning: false, isIngestInProgress: false))
    }

    // MARK: - isIngestInProgress lifecycle

    @Test func ingestFlagLifecycle() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-235-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = WikiStoreModel(
            store: try SQLiteWikiStore(databaseURL: dir.appendingPathComponent("WikiFS.sqlite")))

        // Initially clear.
        #expect(!store.isIngestInProgress)

        // beginIngest sets it (simulating the top of runMultiIngest).
        store.beginIngest()
        #expect(store.isIngestInProgress)

        // endIngest clears it (simulating early exit or process termination).
        store.endIngest()
        #expect(!store.isIngestInProgress)

        // Independent of isAgentRunning (extraction vs. spawn-commit gap).
        #expect(!store.isAgentRunning)
        store.beginIngest()
        #expect(store.isIngestInProgress)
        #expect(!store.isAgentRunning)  // agent lock not yet taken
    }

    // MARK: - composerCaptionText predicate

    @Test func captionVisibleWhenAwaitingSlot() {
        // The core #235 UI fix: waiting for the generation gate shows VISIBLE
        // text (was previously only a hidden .help() tooltip).
        let caption = ChatView.composerCaptionText(
            isAwaitingGenerationSlot: true,
            hasChatID: true, isLiveChat: true, isGenerating: false)
        #expect(caption == "Waiting for the other session to finish before sending…")
    }

    @Test func captionVisibleWhenAwaitingSlotDraftState() {
        // Even in draft state (chatID == nil), the waiting caption shows.
        let caption = ChatView.composerCaptionText(
            isAwaitingGenerationSlot: true,
            hasChatID: false, isLiveChat: false, isGenerating: false)
        #expect(caption == "Waiting for the other session to finish before sending…")
    }

    @Test func captionNilWhenIdle() {
        let caption = ChatView.composerCaptionText(
            isAwaitingGenerationSlot: false,
            hasChatID: true, isLiveChat: true, isGenerating: false)
        #expect(caption == nil)
    }

    @Test func captionForPersistedChatBusy() {
        // A persisted (non-live) chat whose launcher is generating a different
        // chat shows the "Another chat is responding" caption.
        let caption = ChatView.composerCaptionText(
            isAwaitingGenerationSlot: false,
            hasChatID: true, isLiveChat: false, isGenerating: true)
        #expect(caption == "Another chat is responding — wait or stop it.")
    }

    @Test func awaitingSlotOverridesPersistedBusy() {
        // When both isAwaitingGenerationSlot and isGenerating are true, the gate
        // wait message takes priority (it's the more actionable state).
        let caption = ChatView.composerCaptionText(
            isAwaitingGenerationSlot: true,
            hasChatID: true, isLiveChat: false, isGenerating: true)
        #expect(caption == "Waiting for the other session to finish before sending…")
    }
}
