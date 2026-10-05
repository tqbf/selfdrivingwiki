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
                unrecoveredTurnFailure: false)
            Issue.record("Expected launch-failure rejection")
        } catch QueueIngestionError.spawnFailed(let message) {
            #expect(message.contains("env: node: No such file or directory"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("nonzero negative exit with zero turns reports process death (#1364)")
    func nonzeroExitWithoutTurnFailureStillFails() {
        do {
            try DaemonQueueIngestionProvider.validateLauncherOutcome(
                exitStatus: -1,
                preflightError: nil,
                unrecoveredTurnFailure: false)
            Issue.record("Expected abort rejection")
        } catch QueueIngestionError.spawnFailed(let message) {
            // #1364: a negative status is a synthesized/signal death — named
            // honestly instead of "aborted before completing".
            #expect(message == "The agent process died unexpectedly (exit status -1).")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("nonzero positive exit without turn failure reports an abort (#1364)")
    func positiveExitWithoutTurnFailureReportsAbort() {
        do {
            try DaemonQueueIngestionProvider.validateLauncherOutcome(
                exitStatus: 1,
                preflightError: nil,
                unrecoveredTurnFailure: false)
            Issue.record("Expected abort rejection")
        } catch QueueIngestionError.spawnFailed(let message) {
            #expect(message == "The agent run aborted before completing (exit status 1).")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    /// The #1364 incident shape: turn 1 hit the ceiling (recovered — a later
    /// turn completed), then a phase process died (exit -1). The failure is
    /// the process death, NOT the long-gone ceiling — the message must say so.
    @Test("recovered turn failure + process death blames the death (#1364)")
    func recoveredTurnFailureWithProcessDeathBlamesDeath() {
        do {
            try DaemonQueueIngestionProvider.validateLauncherOutcome(
                exitStatus: -1,
                preflightError: nil,
                unrecoveredTurnFailure: false)
            Issue.record("Expected rejection")
        } catch QueueIngestionError.spawnFailed(let message) {
            #expect(message == "The agent process died unexpectedly (exit status -1).")
            #expect(!message.contains("time ceiling"))
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
                unrecoveredTurnFailure: false)
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
            unrecoveredTurnFailure: false)
    }

    @Test("unrecovered turn failure remains a queue failure with the ceiling message")
    func turnFailureThrows() {
        do {
            try DaemonQueueIngestionProvider.validateLauncherOutcome(
                exitStatus: -1,
                preflightError: nil,
                unrecoveredTurnFailure: true)
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
