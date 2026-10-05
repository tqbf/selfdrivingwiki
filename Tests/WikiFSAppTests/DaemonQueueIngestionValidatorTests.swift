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
///
/// #1364: the message is selected by the launcher's STATED turn-failure fact
/// (`QueueIngestionTurnFailureFact`), never inferred from the exit-status
/// sign — every negative status is synthesized by the launcher, so the
/// validator cannot know a "process death" and must not claim one.
@Suite struct DaemonQueueIngestionValidatorTests {

    @Test("launch failure with exit status -1 and zero turns cannot complete (#1354)")
    func launchFailureWithExitStatusCannotComplete() {
        do {
            try DaemonQueueIngestionProvider.validateLauncherOutcome(
                exitStatus: -1,
                preflightError: "Failed to launch codex-acp. stderr: env: node: No such file or directory",
                turnFailure: .none)
            Issue.record("Expected launch-failure rejection")
        } catch QueueIngestionError.spawnFailed(let message) {
            #expect(message.contains("env: node: No such file or directory"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    /// No turn failure was observed and the status is negative (synthesized
    /// by the launcher's abort paths). The validator reports the abort; it
    /// never claims a process death it cannot know (#1364).
    @Test("no turn failure with negative exit reports an abort, not a death (#1364)")
    func nonzeroExitWithoutTurnFailureStillFails() {
        do {
            try DaemonQueueIngestionProvider.validateLauncherOutcome(
                exitStatus: -1,
                preflightError: nil,
                turnFailure: .none)
            Issue.record("Expected abort rejection")
        } catch QueueIngestionError.spawnFailed(let message) {
            #expect(message.contains("aborted before completing"))
            #expect(!message.contains("died"))
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
                turnFailure: .none)
            Issue.record("Expected abort rejection")
        } catch QueueIngestionError.spawnFailed(let message) {
            #expect(message == "The agent run aborted before completing (exit status 1).")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    /// The #1364 incident shape: turn 1 hit the ceiling (recovered — a later
    /// turn completed), then the run still failed. The failure happened after
    /// the recovery — the message must say so instead of blaming the
    /// long-gone ceiling.
    @Test("run failing after a recovered turn failure names the recovery (#1364)")
    func recoveredTurnFailureWithProcessDeathBlamesDeath() {
        do {
            try DaemonQueueIngestionProvider.validateLauncherOutcome(
                exitStatus: -1,
                preflightError: nil,
                turnFailure: .recovered)
            Issue.record("Expected rejection")
        } catch QueueIngestionError.spawnFailed(let message) {
            #expect(message.contains("after recovering from an earlier turn failure"))
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
                turnFailure: .none)
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
            turnFailure: .none)
    }

    @Test("unrecovered turn failure remains a queue failure with the ceiling message")
    func turnFailureThrows() {
        do {
            try DaemonQueueIngestionProvider.validateLauncherOutcome(
                exitStatus: -1,
                preflightError: nil,
                turnFailure: .unrecovered)
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
