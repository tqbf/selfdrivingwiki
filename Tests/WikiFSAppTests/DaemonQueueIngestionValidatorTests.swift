#if os(macOS)
import Testing
import Foundation
@testable import WikiFSEngine
import WikiFSCore
@testable import wikid

/// #1354: the daemon host's ingestion outcome validator must reject a failed
/// agent launch even when an exit status exists and no agent turn ran. The
/// observed daemon-side failure shape: the multi-phase orchestrator aborts
/// (`finish(status: -1)`, zero turns) — the old "nonzero AND turn-failure"
/// conjunction silently accepted it and the job settled `.completed`.
/// These tests pin the shared host contract (preflight first, strict
/// nonzero exit second) without standing up the full daemon provider.
@Suite struct DaemonQueueIngestionValidatorTests {

    @Test("launch failure with exit status -1 and zero turns cannot complete (#1354)")
    func launchFailureWithExitStatusCannotComplete() {
        do {
            try DaemonQueueIngestionProvider.validateLauncherOutcome(
                exitStatus: -1,
                preflightError: "Failed to launch codex-acp. stderr: env: node: No such file or directory",
                hadTurnFailure: false)
            Issue.record("Expected launch-failure rejection")
        } catch QueueIngestionError.spawnFailed(let message) {
            #expect(message.contains("env: node: No such file or directory"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("nonzero exit with zero turns fails even without a preflight diagnostic (#1354)")
    func nonzeroExitWithoutTurnFailureStillFails() {
        do {
            try DaemonQueueIngestionProvider.validateLauncherOutcome(
                exitStatus: -1,
                preflightError: nil,
                hadTurnFailure: false)
            Issue.record("Expected abort rejection")
        } catch QueueIngestionError.spawnFailed(let message) {
            #expect(message == "The agent run aborted before completing (exit status -1).")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("missing exit status fails")
    func missingExitStatusFails() {
        do {
            try DaemonQueueIngestionProvider.validateLauncherOutcome(
                exitStatus: nil,
                preflightError: nil,
                hadTurnFailure: false)
            Issue.record("Expected did-not-start rejection")
        } catch QueueIngestionError.spawnFailed(let message) {
            #expect(message == "The agent did not start.")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("successful launcher outcome is accepted")
    func successfulLauncherOutcomeIsAccepted() throws {
        try DaemonQueueIngestionProvider.validateLauncherOutcome(
            exitStatus: 0,
            preflightError: nil,
            hadTurnFailure: false)
    }

    @Test("turn failure remains a queue failure with the ceiling message")
    func turnFailureThrows() {
        do {
            try DaemonQueueIngestionProvider.validateLauncherOutcome(
                exitStatus: -1,
                preflightError: nil,
                hadTurnFailure: true)
            Issue.record("Expected turn failure")
        } catch QueueIngestionError.spawnFailed(let message) {
            #expect(message ==
                "The agent turn exceeded the time ceiling or failed unexpectedly (exit status -1).")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
#endif
