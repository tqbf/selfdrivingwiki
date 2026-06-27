import Foundation
import Testing
@testable import WikiFS

/// Tests for the pure `AgentLauncher.relocatedCredentialPlan` decision: WHEN to
/// seed the user's `.credentials.json` into a sandboxed spawn's relocated
/// `CLAUDE_CONFIG_DIR`. The seed must fire ONLY when the config dir was relocated
/// into the run's own scratch (so a user's own `CLAUDE_CONFIG_DIR` is never touched
/// and unsandboxed runs are no-ops).
@MainActor
struct RelocatedCredentialPlanTests {

    private static let scratch = "/Users/me/Library/Caches/Self Driving Wiki-agent/01ABC"
    private static let home = "/Users/me"

    @Test func seedsWhenConfigDirIsRelocatedIntoScratch() {
        let plan = AgentLauncher.relocatedCredentialPlan(
            configDir: Self.scratch + "/.claude-config",
            scratchPath: Self.scratch,
            home: Self.home)
        #expect(plan?.source == "/Users/me/.claude/.credentials.json")
        #expect(plan?.target == Self.scratch + "/.claude-config/.credentials.json")
    }

    @Test func noSeedWhenUnsandboxed() {
        // Unsandboxed runs never relocate CLAUDE_CONFIG_DIR — nil → no copy.
        #expect(AgentLauncher.relocatedCredentialPlan(
            configDir: nil, scratchPath: Self.scratch, home: Self.home) == nil)
    }

    @Test func noSeedWhenConfigDirIsOutsideOurScratch() {
        // A user's OWN CLAUDE_CONFIG_DIR (not under our scratch) must never be
        // overwritten with a credential copy.
        #expect(AgentLauncher.relocatedCredentialPlan(
            configDir: "/Users/me/.config/claude",
            scratchPath: Self.scratch,
            home: Self.home) == nil)
    }
}
