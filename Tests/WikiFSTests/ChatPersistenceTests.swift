import Foundation
import Testing
@testable import WikiFS
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

    // MARK: - End-to-end sink installation via startInteractiveQuery

    // No existing seam lets tests feed stdout lines into `AgentLauncher` without
    // spawning a real `claude -p` process (the parser is only reachable via the
    // private `ingestStdout`, driven by a `Process`'s stdout pipe). Per the task's
    // instruction, an end-to-end "sink receives flushed events from a live session"
    // test is skipped rather than spawning a real process in unit tests.
}
