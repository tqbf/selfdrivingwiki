import Foundation
import Testing

/// Pins the opt-in app test gate's wiring so it cannot silently rot (#1398).
///
/// The gate's whole point is that a `WIKIFS_APP_TESTS=1` invocation must
/// either demonstrate that `WikiFSAppTests` executed or fail loudly. Every
/// piece of that contract lives outside the default test graph — the manifest
/// conditional, the guarded runner, the assertion library, and the sentinel —
/// so the always-run graph re-asserts the pieces here by reading the files.
/// If a refactor renames or disconnects any of them, this suite fails in the
/// default `make test` tier where the breakage is visible.
struct OptInAppTestsGateContractTests {
    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // Tests/WikiFSTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // repo root

    @Test func manifestKeepsTheAppTargetOptInAndFlagDriven() throws {
        let manifest = try String(
            contentsOf: Self.repositoryRoot.appendingPathComponent("Package.swift"),
            encoding: .utf8
        )
        // The flag is read from the environment, not hardcoded.
        #expect(
            manifest.contains(#"ProcessInfo.processInfo.environment["WIKIFS_APP_TESTS"] == "1""#),
            "Package.swift must derive appTestsEnabled from WIKIFS_APP_TESTS"
        )
        // The target stays out of the default graph unless the flag is set.
        #expect(
            manifest.contains(#"if $0.name == "WikiFSAppTests" && !appTestsEnabled { return false }"#),
            "Package.swift must keep WikiFSAppTests out of the graph unless appTestsEnabled"
        )
    }

    @Test func sentinelTestShipsInsideTheAppTarget() throws {
        let sentinel = try String(
            contentsOf: Self.repositoryRoot
                .appendingPathComponent("Tests/WikiFSAppTests/OptInGateSentinelTests.swift"),
            encoding: .utf8
        )
        // The sentinel's executed line is the gate's default evidence; the
        // suite name and display name must stay stable because the gate regex
        // matches both.
        #expect(sentinel.contains("struct OptInGateSentinelTests"))
        #expect(sentinel.contains(#"@Suite("Opt-in gate sentinel")"#))
        #expect(sentinel.contains(#"environment["WIKIFS_APP_TESTS"] == "1""#))
    }

    @Test func gateLibraryCountsExecutedLinesNotStartedLines() throws {
        let gate = try String(
            contentsOf: Self.repositoryRoot
                .appendingPathComponent("scripts/lib/optin-app-test-gate.sh"),
            encoding: .utf8
        )
        // Only "passed after"/"failed after" lines prove execution; a
        // started-only match would accept the #1398 skip shape back in.
        #expect(gate.contains(#"passed after | failed after"#))
        // The default expectation matches the sentinel in both output modes:
        // module-qualified IDs (verbose) and the display name (plain).
        #expect(gate.contains(#"WikiFSAppTests\\.OptInGateSentinelTests"#))
        #expect(gate.contains(#"\"Opt-in gate sentinel\""#))
        #expect(gate.contains("#1398"))
    }

    @Test func guardedRunnerEnforcesTheGate() throws {
        let runner = try String(
            contentsOf: Self.repositoryRoot
                .appendingPathComponent("scripts/test-optin-app-tests.sh"),
            encoding: .utf8
        )
        #expect(runner.contains("export WIKIFS_APP_TESTS=1"))
        #expect(runner.contains("optin_gate_assert_executed"))
        #expect(runner.contains("optin-app-test-gate.sh"))
    }

    @Test func makeRecipesRouteOptInRunsThroughTheGuard() throws {
        let makefile = try String(
            contentsOf: Self.repositoryRoot.appendingPathComponent("Makefile"),
            encoding: .utf8
        )
        // `test` under WIKIFS_APP_TESTS=1 and the `test-app` target both go
        // through the guarded runner; a bare swift test recipe line in either
        // spot would reintroduce the unguarded false green.
        #expect(makefile.contains("test-app: deps prompts version keychain extractor-packages"))
        #expect(
            makefile.contains("SWIFT_TEST_NUM_WORKERS=\"$(SWIFT_TEST_NUM_WORKERS)\" scripts/test-optin-app-tests.sh")
        )
        #expect(makefile.contains(#"if [ "$${WIKIFS_APP_TESTS-}" = "1" ]"#))
    }

    @Test func watchdogAppliesTheGateWhenOptedIn() throws {
        let watchdog = try String(
            contentsOf: Self.repositoryRoot
                .appendingPathComponent("scripts/test-with-watchdog.sh"),
            encoding: .utf8
        )
        #expect(watchdog.contains(#"[ "${WIKIFS_APP_TESTS:-}" = "1" ]"#))
        #expect(watchdog.contains("optin_gate_assert_executed"))
    }
}
