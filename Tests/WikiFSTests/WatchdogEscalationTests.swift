import Testing
import WikiFSEngine
import Foundation
import WikiFSEngine
@testable import WikiFS
@testable import WikiFSEngine

/// Unit tests for the launcher watchdog's stall-escalation decision
/// (`plans/acp-stall-recovery.md` Phase 3 §3).
///
/// The decision is extracted as a PURE static so it's unit-testable without
/// driving launcher state or spawning processes.
@Suite struct WatchdogEscalationTests {

    // MARK: - Escalate

    @Test func escalatesWhenIdleExceedsThreshold() {
        #expect(AgentLauncher.shouldEscalateWatchdog(
            isRunning: true,
            idleSeconds: 181,
            stallThreshold: 180,
            alreadyEscalated: false
        ) == true)
    }

    @Test func escalatesAtExactlyThreshold() {
        #expect(AgentLauncher.shouldEscalateWatchdog(
            isRunning: true,
            idleSeconds: 180,
            stallThreshold: 180,
            alreadyEscalated: false
        ) == true)
    }

    // MARK: - Don't escalate

    @Test func noEscalateWhenNotRunning() {
        #expect(AgentLauncher.shouldEscalateWatchdog(
            isRunning: false,
            idleSeconds: 9999,
            stallThreshold: 180,
            alreadyEscalated: false
        ) == false)
    }

    @Test func noEscalateWhenIdleBelowThreshold() {
        #expect(AgentLauncher.shouldEscalateWatchdog(
            isRunning: true,
            idleSeconds: 179,
            stallThreshold: 180,
            alreadyEscalated: false
        ) == false)
    }

    @Test func noEscalateWhenAlreadyEscalated() {
        #expect(AgentLauncher.shouldEscalateWatchdog(
            isRunning: true,
            idleSeconds: 9999,
            stallThreshold: 180,
            alreadyEscalated: true
        ) == false)
    }

    @Test func noEscalateWhenNoActivityRecorded() {
        // idleSeconds = -1 (no lastActivityAt) — should not escalate.
        #expect(AgentLauncher.shouldEscalateWatchdog(
            isRunning: true,
            idleSeconds: -1,
            stallThreshold: 180,
            alreadyEscalated: false
        ) == false)
    }

    // MARK: - Threshold constant

    @Test func defaultStallThresholdIs180() {
        #expect(AgentLauncher.watchdogStallThreshold == 180)
    }
}
