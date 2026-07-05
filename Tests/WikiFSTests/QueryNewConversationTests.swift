import Foundation
import Testing
@testable import WikiFS
import WikiFSCore

/// Tests for the "New Conversation" control on the Ask/Edit chat page.
///
/// Two things to pin down:
///   1. `QueryConversationView.showsNewConversationButton` — the pure predicate
///      that decides whether the button shows. It must never offer to end a
///      non-query run (ingest/lint) that happens to be streaming into the shared
///      launcher, but should show whenever there's a live query session or a
///      leftover transcript the user might want to clear.
///   2. `AgentLauncher.startNewConversation()` — the behavior wired to the button.
///      On an idle launcher (no process running), it must be a safe no-op that
///      leaves the launcher in its already-clean empty state.
///
/// NOTE: there is no existing seam in `AgentLauncher` to seed `events` /
/// `rawTranscript` from a test without spawning a real `claude` process — `events`
/// is `private(set)` and the only mutator, `ingestStdout`, is `private`. So the
/// "clears a leftover transcript" behavior is covered here only via the pure
/// predicate (which takes `hasConversation` as a plain `Bool` parameter); the
/// launcher-level test below exercises the idle no-op path only.
@MainActor
struct QueryNewConversationTests {

    private func makeLauncher() -> AgentLauncher {
        let launcher = AgentLauncher()
        launcher.resolveClaude = { .found(path: "/usr/bin/true") }
        return launcher
    }

    // MARK: - Predicate matrix

    /// Idle, no conversation → nothing to show or clear.
    @Test func idleNoConversationHidesButton() {
        #expect(QueryConversationView.showsNewConversationButton(
            isInteractiveSession: false,
            hasConversation: false,
            isRunning: false,
            runningKind: nil) == false)
    }

    /// Idle, but a leftover transcript is visible → button shows so the user can
    /// clear it before starting fresh.
    @Test func idleWithConversationShowsButton() {
        #expect(QueryConversationView.showsNewConversationButton(
            isInteractiveSession: false,
            hasConversation: true,
            isRunning: false,
            runningKind: nil) == true)
    }

    /// A live interactive query session (mid-run) → button shows so the user can
    /// end it and start over.
    @Test func liveQuerySessionShowsButton() {
        #expect(QueryConversationView.showsNewConversationButton(
            isInteractiveSession: true,
            hasConversation: true,
            isRunning: true,
            runningKind: .query) == true)
    }

    /// A non-query run (e.g. ingest) is streaming into the shared launcher →
    /// button must hide even though a conversation is visible. It must never
    /// offer to kill someone else's run.
    @Test func runningIngestWithConversationHidesButton() {
        #expect(QueryConversationView.showsNewConversationButton(
            isInteractiveSession: false,
            hasConversation: true,
            isRunning: true,
            runningKind: .ingest) == false)
    }

    /// Idle with `runningKind == nil` (no run has ever started on this launcher)
    /// and a conversation present → button shows.
    @Test func idleRunningKindNilWithConversationShowsButton() {
        #expect(QueryConversationView.showsNewConversationButton(
            isInteractiveSession: false,
            hasConversation: true,
            isRunning: false,
            runningKind: nil) == true)
    }

    // MARK: - Launcher behavior

    /// On an idle launcher, `startNewConversation()` is a safe no-op: no crash,
    /// and the launcher lands in / stays in its clean empty state.
    @Test func startNewConversationOnIdleLauncherIsSafeNoOp() {
        let launcher = makeLauncher()
        #expect(!launcher.isRunning)

        launcher.startNewConversation()

        #expect(launcher.events.isEmpty)
        #expect(!launcher.isInteractiveSession)
        #expect(launcher.exitStatus == nil)
        #expect(launcher.rawTranscript.isEmpty)
    }
}
