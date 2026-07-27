#if os(macOS)
import Testing
import WikiFSCore
import WikiFSTypes
@testable import WikiFS

/// `ChatWebView.Coordinator` renders **incrementally** — it appends only
/// `events[renderedCount...]` and patches the last row in place. That is sound
/// only while successive `events` arrays are successive states of the same
/// conversation.
///
/// SwiftUI reuses an `NSViewRepresentable`'s view + coordinator across a chat
/// tab switch (both chats render from the same `switch` branch, so structural
/// identity is unchanged), which previously spliced one chat's tail onto
/// another chat's DOM. `transcriptID` is the guard; these tests pin the pure
/// decision function behind it.
struct ChatWebViewTranscriptIDTests {

    private let chatA = TranscriptID.chat(ChatID(rawValue: "chat-a"))
    private let chatB = TranscriptID.chat(ChatID(rawValue: "chat-b"))

    // MARK: - Transcript identity

    @Test func rebuildsWhenTranscriptIDChanges_evenThoughEventsGrew() {
        // The regression: chat B has MORE events than chat A had rendered, so
        // the count check alone reads as "rows were appended" and splices B's
        // tail onto A's DOM.
        #expect(ChatWebView.Coordinator.needsFullReload(
            transcriptID: chatB, renderedTranscriptID: chatA,
            showsInternals: false, renderedShowsInternals: false,
            eventCount: 20, renderedCount: 12))
    }

    @Test func rebuildsWhenTranscriptIDChanges_atIdenticalEventCount() {
        // The quieter half of the same bug: equal counts took the
        // "patch the last row only" path, leaving chat A's whole transcript on
        // screen with a single row swapped.
        #expect(ChatWebView.Coordinator.needsFullReload(
            transcriptID: chatB, renderedTranscriptID: chatA,
            showsInternals: false, renderedShowsInternals: false,
            eventCount: 12, renderedCount: 12))
    }

    @Test func rebuildsWhenArrivingFromNoTranscript() {
        #expect(ChatWebView.Coordinator.needsFullReload(
            transcriptID: chatA, renderedTranscriptID: nil,
            showsInternals: false, renderedShowsInternals: false,
            eventCount: 3, renderedCount: 3))
    }

    @Test func chatIDsAndQueueIDsNeverCollide() {
        // The reason `TranscriptID` is a namespaced enum rather than a String:
        // chat rows and queue items are both ULIDs, so the same raw value in
        // two id spaces must still read as two different transcripts.
        let shared = "01JQ0000000000000000000000"
        #expect(ChatWebView.Coordinator.needsFullReload(
            transcriptID: .queueItem(QueueItemID(rawValue: shared)),
            renderedTranscriptID: .chat(ChatID(rawValue: shared)),
            showsInternals: false, renderedShowsInternals: false,
            eventCount: 5, renderedCount: 5))
    }

    // MARK: - The incremental path stays incremental

    @Test func appendsWithinTheSameTranscript() {
        // Streaming: same chat, rows appended. Must NOT rebuild — a full
        // reload would drop an in-progress text selection every delta.
        #expect(!ChatWebView.Coordinator.needsFullReload(
            transcriptID: chatA, renderedTranscriptID: chatA,
            showsInternals: false, renderedShowsInternals: false,
            eventCount: 13, renderedCount: 12))
    }

    @Test func patchesLastRowWithinTheSameTranscript() {
        // A streamed delta merged into the in-progress `.assistantText` grows
        // the last event in place without changing the count (issue #121).
        #expect(!ChatWebView.Coordinator.needsFullReload(
            transcriptID: chatA, renderedTranscriptID: chatA,
            showsInternals: false, renderedShowsInternals: false,
            eventCount: 12, renderedCount: 12))
    }

    @Test func nilTranscriptIDOptsOutOfIdentityChecks() {
        // Call sites that render one transcript for the view's lifetime
        // (`AgentQueueView`) pass nil and keep the historical behavior.
        #expect(!ChatWebView.Coordinator.needsFullReload(
            transcriptID: nil, renderedTranscriptID: nil,
            showsInternals: false, renderedShowsInternals: false,
            eventCount: 9, renderedCount: 4))
    }

    // MARK: - Pre-existing rebuild triggers still fire

    @Test func rebuildsOnEventCountDecrease() {
        // The reset contract (`events = []`).
        #expect(ChatWebView.Coordinator.needsFullReload(
            transcriptID: chatA, renderedTranscriptID: chatA,
            showsInternals: false, renderedShowsInternals: false,
            eventCount: 0, renderedCount: 12))
    }

    @Test func rebuildsOnShowsInternalsToggle() {
        // Retroactively changes which events are visible rows.
        #expect(ChatWebView.Coordinator.needsFullReload(
            transcriptID: chatA, renderedTranscriptID: chatA,
            showsInternals: true, renderedShowsInternals: false,
            eventCount: 12, renderedCount: 12))
    }

    @Test func rebuildsOnFirstApplyBeforeAnythingRendered() {
        // `renderedShowsInternals` is nil until the first `reload`.
        #expect(ChatWebView.Coordinator.needsFullReload(
            transcriptID: nil, renderedTranscriptID: nil,
            showsInternals: false, renderedShowsInternals: nil,
            eventCount: 0, renderedCount: 0))
    }
}
#endif
