import Foundation
import Testing
@testable import WikiFS
import WikiFSCore

/// Tests for the New Conversation affordance (PR #198 semantics, `plans/
/// persisted-chat-history.md`): the pure `showsNewConversationButton` predicate
/// on `QueryConversationView`, and `AgentLauncher.startNewConversation()`'s
/// clearing/guard behavior.
@MainActor
struct QueryNewConversationTests {

    private func makeLauncher() -> AgentLauncher {
        let launcher = AgentLauncher()
        launcher.resolveClaude = { .found(path: "/usr/bin/true") }
        return launcher
    }

    // MARK: - showsNewConversationButton predicate matrix

    @Test func predicateTrueWhileLiveQuerySession() {
        #expect(QueryConversationView.showsNewConversationButton(
            isRunning: true, isInteractiveSession: true,
            runningKind: .query, hasVisibleConversation: false))
    }

    @Test func predicateFalseForNonQueryRunEvenIfInteractive() {
        // Guards against a non-query run (ingest/lint) ever showing the button
        // via the "live session" arm.
        #expect(!QueryConversationView.showsNewConversationButton(
            isRunning: true, isInteractiveSession: true,
            runningKind: .ingest, hasVisibleConversation: false))
    }

    @Test func predicateFalseWhenRunningButNotInteractive() {
        #expect(!QueryConversationView.showsNewConversationButton(
            isRunning: true, isInteractiveSession: false,
            runningKind: .query, hasVisibleConversation: false))
    }

    @Test func predicateTrueWhenIdleButTranscriptVisible() {
        // A finished transcript still visible is worth discarding even though
        // nothing is running.
        #expect(QueryConversationView.showsNewConversationButton(
            isRunning: false, isInteractiveSession: false,
            runningKind: nil, hasVisibleConversation: true))
    }

    @Test func predicateFalseWhenIdleAndNoVisibleConversation() {
        #expect(!QueryConversationView.showsNewConversationButton(
            isRunning: false, isInteractiveSession: false,
            runningKind: nil, hasVisibleConversation: false))
    }

    // MARK: - startNewConversation() clears idle state

    @Test func startNewConversationClearsStateWhenIdle() {
        let launcher = makeLauncher()
        // Pre-seed visible-run artifacts via the relaxed test seams.
        launcher.events = [.userText("hello"), .assistantText("hi there")]
        launcher.rawTranscript = "some raw transcript"
        launcher.stderr = "some stderr"
        launcher.exitStatus = 0
        launcher.preflightError = "some preflight error"
        // Sentinel: extraction state must be untouched.
        launcher.extractionLog = "sentinel-extraction-log"
        launcher.extractionPID = 4242
        launcher.extractingSourceIDs = [PageID(rawValue: "sentinel-source")]

        launcher.startNewConversation()

        #expect(launcher.events.isEmpty)
        #expect(launcher.rawTranscript.isEmpty)
        #expect(launcher.stderr.isEmpty)
        #expect(launcher.exitStatus == nil)
        #expect(launcher.preflightError == nil)
        // Extraction state is a completely separate mechanism — untouched.
        #expect(launcher.extractionLog == "sentinel-extraction-log")
        #expect(launcher.extractionPID == 4242)
        #expect(launcher.extractingSourceIDs == [PageID(rawValue: "sentinel-source")])
    }

    // MARK: - startNewConversation() guard: never kills a non-query run

    @Test func startNewConversationIsNoOpForNonQueryRun() {
        let launcher = makeLauncher()
        launcher.events = [.userText("hello"), .assistantText("hi there")]
        launcher.isRunning = true
        launcher.runningKind = .ingest

        launcher.startNewConversation()

        // Guard fires: nothing is cleared, nothing is stopped.
        #expect(launcher.events.count == 2)
        #expect(launcher.isRunning)
        #expect(launcher.runningKind == .ingest)
    }
}
