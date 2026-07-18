import Testing
import WikiFSEngine
import Foundation
import WikiFSEngine
@testable import WikiFS
@testable import WikiFSEngine

/// Unit tests for the launcher watchdog constants.
///
/// The stall-escalation path (`shouldEscalateWatchdog`,
/// `watchdogStallThreshold`) was removed — the idle stall was eliminated
/// because ACP agents emit notifications for every activity, so a live agent
/// is almost never truly idle. The watchdog is now observability-only.
@Suite struct WatchdogEscalationTests {

    // MARK: - Threshold constant

    @Test func warningThresholdIs120() {
        #expect(AgentLauncher.watchdogWarningThreshold == 120)
    }

    @Test func pollIntervalIs3() {
        #expect(AgentLauncher.watchdogPollInterval == 3)
    }
}
