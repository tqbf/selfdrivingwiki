#if os(macOS)
import Testing
import Foundation
import WikiFSCore
@testable import WikiFS
@testable import WikiFSEngine

/// Unit tests for `ChatDetailView.displayMessages` (AC.6) — the pure source-of-truth
/// selector that collapses the live/persisted transcript render path into one
/// `ChatTranscriptView(events:)` call site. Covers source selection (live →
/// launcher events, non-live → persisted) and the `transcriptVisible` filter,
/// without a SwiftUI view-tree harness.
struct ChatDisplayMessagesTests {

    @Test func selectsLauncherEventsWhenLive() {
        let live: [AgentEvent] = [.userText("hello"), .assistantText("streaming")]
        let persisted: [AgentEvent] = [.userText("old"), .assistantText("old answer")]
        let result = ChatDetailView.displayMessages(
            isLiveChat: true, launcherEvents: live, persistedEvents: persisted)
        #expect(result == [.userText("hello"), .assistantText("streaming")])
    }

    @Test func selectsPersistedEventsWhenNotLive() {
        let live: [AgentEvent] = [.userText("hello")]
        let persisted: [AgentEvent] = [.userText("old"), .assistantText("old answer")]
        let result = ChatDetailView.displayMessages(
            isLiveChat: false, launcherEvents: live, persistedEvents: persisted)
        #expect(result == [.userText("old"), .assistantText("old answer")])
    }

    @Test func appliesTranscriptVisibleFilter() {
        // A successful tool result is NOT transcript-visible (only failures
        // surface); userText/assistantText survive.
        let events: [AgentEvent] = [
            .userText("q"),
            .toolResult(isError: false, summary: "ok"),
            .assistantText("a"),
        ]
        let result = ChatDetailView.displayMessages(
            isLiveChat: true, launcherEvents: events, persistedEvents: [])
        #expect(result == [.userText("q"), .assistantText("a")])
    }

    @Test func emptyWhenNoSourceEvents() {
        let result = ChatDetailView.displayMessages(
            isLiveChat: false, launcherEvents: [.userText("x")], persistedEvents: [])
        #expect(result.isEmpty)
    }
}
#endif
