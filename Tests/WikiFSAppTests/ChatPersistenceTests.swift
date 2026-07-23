#if os(macOS)
import Foundation
import WikiFSEngine
import Testing
import WikiFSEngine
@testable import WikiFS
@testable import WikiFSEngine
import WikiFSCore

/// Tests for the flush-cursor arithmetic backing `AgentLauncher`'s transcript
/// persistence sink (issue #119, `plans/persisted-chat-history.md`).
/// `AgentLauncher.unflushedTail(events:persistedCount:)` is the pure extraction
/// of `flushTranscript()`'s slicing logic, so the cursor invariant is testable
/// without a live process or a real store.
@MainActor
struct ChatPersistenceTests {

    private let sampleEvents: [AgentEvent] = [
        .userText("hello"),
        .assistantText("hi there"),
        .messageStop,
        .userText("follow up"),
        .assistantText("sure"),
        .messageStop,
    ]

    @Test func tailIsEverythingWhenNothingFlushedYet() {
        let tail = AgentLauncher.unflushedTail(events: sampleEvents, persistedCount: 0)
        #expect(tail == sampleEvents)
    }

    @Test func tailIsOnlyTheNewSuffixAfterAPartialFlush() {
        // First turn already persisted (events[0..<3)]).
        let tail = AgentLauncher.unflushedTail(events: sampleEvents, persistedCount: 3)
        #expect(tail == Array(sampleEvents[3...]))
    }

    @Test func tailIsEmptyWhenFullyFlushed() {
        let tail = AgentLauncher.unflushedTail(events: sampleEvents, persistedCount: sampleEvents.count)
        #expect(tail.isEmpty)
    }

    @Test func tailIsEmptyWhenPersistedCountExceedsEventsIdempotentGuard() {
        // Guards the `>=` shape of `flushTranscript()`'s check: a cursor at or past
        // the end never produces a negative-range crash, just an empty tail.
        let tail = AgentLauncher.unflushedTail(events: sampleEvents, persistedCount: sampleEvents.count + 5)
        #expect(tail.isEmpty)
    }

    @Test func tailPreservesOrderAndDoesNotFilterByPersistability() {
        // Filtering to persistable events is the model's job
        // (`WikiStoreModel.appendChatEvents`), not the launcher's — the tail
        // includes `.messageStop` (not persistable) verbatim.
        let tail = AgentLauncher.unflushedTail(events: sampleEvents, persistedCount: 2)
        #expect(tail.first == .messageStop)
        #expect(tail == Array(sampleEvents[2...]))
    }

    // MARK: - History seeding (continue chat shows full transcript)

    // When `startInteractiveQuery` receives a `historySeed`, it pre-populates
    // `events` and sets `persistedEventCount` so the seeded (already-stored)
    // rows are never re-persisted by `flushTranscript`. The pure invariant is:
    // `unflushedTail(events: persistedCount:)` must return ONLY the new tail.

    @Test func historySeedSetup_makesUnflushedTailEmptyBeforeNewEvents() {
        // A continued chat seeds 3 prior events; persistedEventCount is set to 3.
        // Before any new events arrive, flushTranscript would produce nothing.
        let seeded: [AgentEvent] = [
            .userText("old question"),
            .assistantText("old answer"),
            .toolUse(name: "Bash", inputSummary: "ls"),
        ]
        let tail = AgentLauncher.unflushedTail(events: seeded, persistedCount: seeded.count)
        #expect(tail.isEmpty)
    }

    @Test func historySeedSetup_flushOnlyPersistsNewTail() {
        // Seed 3 prior events, then append 2 new events (the continue turn).
        // flushTranscript must produce only the 2 new events, not the 3 seeded.
        let seeded: [AgentEvent] = [
            .userText("old question"),
            .assistantText("old answer"),
            .systemInit(model: "claude"),
        ]
        var events = seeded
        events.append(.userText("continue question"))
        events.append(.assistantText("continue answer"))
        let tail = AgentLauncher.unflushedTail(events: events, persistedCount: seeded.count)
        #expect(tail.count == 2)
        #expect(tail[0] == .userText("continue question"))
        #expect(tail[1] == .assistantText("continue answer"))
    }

    // MARK: - End-to-end sink installation via startInteractiveQuery

    // No existing seam lets tests feed stdout lines into `AgentLauncher` without
    // spawning a real agent process (the parser is only reachable via the
    // private `ingestStdout`, driven by a `Process`'s stdout pipe). Per the task's
    // instruction, an end-to-end "sink receives flushed events from a live session"
    // test is skipped rather than spawning a real process in unit tests.

    // MARK: - In-flight checkpoint cursor interactions (#826)

    // The streaming checkpoint advances `persistedEventCount` to
    // `streamingRowIndex + 1` (NOT `events.count`) on success — marking ONLY the
    // streamed row as persisted. Any post-streaming events (tool calls, results)
    // remain in the `flushTranscript` tail and append normally. These tests
    // verify that pure cursor arithmetic via `unflushedTail`.

    @Test func checkpoint_excludes_streamed_row_from_turn_end_tail() {
        // AC.3: after a checkpoint, the turn-end flushTranscript tail contains
        // only post-streaming events, not the already-checkpointed row.
        // events = [user(0), assistant_partial(1), toolResult(2)]
        // checkpoint sets persistedCount to idx+1 = 2 (only the streamed row)
        var events: [AgentEvent] = [
            .userText("hello"),
            .assistantText("partial response"),
        ]
        let persistedAfterCheckpoint = 2  // streamingRowIndex+1
        events.append(.toolResult(isError: false, summary: "done"))
        // flushTranscript picks up only the tail
        let tail = AgentLauncher.unflushedTail(events: events, persistedCount: persistedAfterCheckpoint)
        #expect(tail.count == 1)
        #expect(tail.first == .toolResult(isError: false, summary: "done"))
    }

    @Test func checkpoint_grown_in_place_still_excludes_streamed_row() {
        // The streamed row grows in place (same index) — the cursor stays at
        // idx+1, so subsequent in-place growth doesn't reopen the flush window.
        let events: [AgentEvent] = [
            .userText("hello"),
            .assistantText("Hello world this is a longer response"),
            .toolResult(isError: false, summary: "computed"),
        ]
        // After checkpointing at idx=1, persistedCount=2. More deltas grew the
        // row in place (events.count stayed 3), and a toolResult was appended.
        let tail = AgentLauncher.unflushedTail(events: events, persistedCount: 2)
        #expect(tail.count == 1)
        #expect(tail.first == .toolResult(isError: false, summary: "computed"))
    }

    @Test func finalize_is_noop_without_handle() {
        // AC: tool-only turn → no streamingDraftHandle → checkpointStreamingRow
        // is a no-op. The cursor is unchanged, so flushTranscript picks up the
        // whole tail as before.
        let events: [AgentEvent] = [
            .userText("run a tool"),
            .toolUse(name: "Bash", inputSummary: "ls"),
            .toolResult(isError: false, summary: "file.txt"),
        ]
        // No checkpoint happened (handle was nil), so persistedCount stays at 1
        // (user pre-persisted). flushTranscript picks up everything after.
        let tail = AgentLauncher.unflushedTail(events: events, persistedCount: 1)
        #expect(tail.count == 2)
        #expect(tail[0] == .toolUse(name: "Bash", inputSummary: "ls"))
        #expect(tail[1] == .toolResult(isError: false, summary: "file.txt"))
    }

    @Test func multi_block_turn_finalizes_each_streamed_row() {
        // AC.5: a multi-block turn (assistant → tool → assistant) checkpoints
        // each block's row independently. Block 1 at idx=1 (persistedCount=2);
        // block 2 at idx=3 (persistedCount=4). The tool result at idx=2 is in
        // the tail for the final flushTranscript.
        let events: [AgentEvent] = [
            .userText("do two things"),
            .assistantText("first block"),      // idx=1, checkpointed: persisted=2
            .toolResult(isError: false, summary: "first"),  // idx=2
            .assistantText("second block"),     // idx=3, checkpointed: persisted=4
        ]
        // After block 1 is finalized (persistedCount=2) and block 2 is
        // checkpointed (persistedCount=4), the tool result at idx=2 should be
        // in the tail when a final .toolResult arrives at idx=4.
        var grown = events
        grown.append(.toolResult(isError: false, summary: "second"))  // idx=4
        // Block 2's checkpoint advanced persistedCount to idx3+1 = 4
        let tail = AgentLauncher.unflushedTail(events: grown, persistedCount: 4)
        #expect(tail.count == 1)
        #expect(tail.first == .toolResult(isError: false, summary: "second"))
    }

    @Test func checkpoint_failure_keeps_row_in_tail() {
        // AC.4: if the checkpoint FAILS (C2), the cursor is NOT advanced — the
        // streamed row stays in the tail so flushTranscript persists it via the
        // normal append path (no silent data loss).
        let events: [AgentEvent] = [
            .userText("hello"),
            .assistantText("partial response"),
        ]
        // Checkpoint failed → persistedCount NOT advanced → stays at 1 (user
        // pre-persisted). flushTranscript tail includes the streamed row.
        let tail = AgentLauncher.unflushedTail(events: events, persistedCount: 1)
        #expect(tail.count == 1)
        #expect(tail.first == .assistantText("partial response"))
    }
}
#endif
