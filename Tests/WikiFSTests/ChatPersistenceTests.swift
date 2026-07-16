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
}
