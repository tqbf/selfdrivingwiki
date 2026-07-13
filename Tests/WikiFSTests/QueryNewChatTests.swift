import Foundation
import WikiFSEngine
import Testing
import WikiFSEngine
@testable import WikiFS
@testable import WikiFSEngine
import WikiFSCore

/// Tests for `AgentLauncher.startNewChat()`'s clearing/guard behavior
/// (PR #198 semantics, `plans/persisted-chat-history.md`).
@MainActor
struct QueryNewChatTests {

    private func makeLauncher() -> AgentLauncher {
        let launcher = AgentLauncher()
        launcher.resolveClaude = { .found(path: "/usr/bin/true") }
        return launcher
    }

    // MARK: - startNewChat() clears idle state

    @Test func startNewChatClearsStateWhenIdle() {
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

        launcher.startNewChat()

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

    // MARK: - startNewChat() guard: never kills a non-query run

    @Test func startNewChatIsNoOpForNonQueryRun() {
        let launcher = makeLauncher()
        launcher.events = [.userText("hello"), .assistantText("hi there")]
        launcher.isRunning = true
        launcher.runningKind = .ingest

        launcher.startNewChat()

        // Guard fires: nothing is cleared, nothing is stopped.
        #expect(launcher.events.count == 2)
        #expect(launcher.isRunning)
        #expect(launcher.runningKind == .ingest)
    }
}
