import Foundation
import Testing
@testable import WikiFS
import WikiFSCore

/// Tests for issue #235: preventing silent hangs when starting a chat during
/// an ingest's extraction phase.
///
/// Two concerns:
/// 1. The `shouldBlockEditStart` predicate — chat preflight must block during
///    extraction (via `isIngestInProgress`). The old `isAgentRunning` edit-lock
///    guard was removed — CAS (page versions, W0) prevents data races, so
///    concurrent agent runs are fine.
/// 2. The `isIngestInProgress` lifecycle on `WikiStoreModel`.
/// 3. The `composerCaptionText` predicate — the waiting state must surface as
///    visible text (not just a tooltip).
@MainActor
struct Issue235IngestExtractionLockTests {

    // MARK: - shouldBlockEditStart predicate

    @Test func chatBlockedWhenIngestInProgress() {
        // Extraction phase: isIngestInProgress is true. Chat must be blocked.
        #expect(AgentOperationRunner.shouldBlockEditStart(
            isIngestInProgress: true))
    }

    @Test func chatAllowedWhenIdle() {
        // No ingest in progress — chat is free to start.
        #expect(!AgentOperationRunner.shouldBlockEditStart(
            isIngestInProgress: false))
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

        // Independent of agentRunCount (extraction vs. spawn-commit gap).
        #expect(store.agentRunCount == 0)
        store.beginIngest()
        #expect(store.isIngestInProgress)
        #expect(store.agentRunCount == 0)  // agent run not yet started
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

    @Test func captionForLiveChatGenerating() {
        // A live chat that is actively generating shows a subtle "Agent is
        // responding…" caption (replaces the old orange banner).
        let caption = ChatView.composerCaptionText(
            isAwaitingGenerationSlot: false,
            hasChatID: true, isLiveChat: true, isGenerating: true)
        #expect(caption == "Agent is responding…")
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
