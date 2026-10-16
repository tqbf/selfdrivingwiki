import Foundation
import Testing

/// The #1398 sentinel: a deterministic, dependency-free test inside the
/// opt-in `WikiFSAppTests` target whose executed line is the observable
/// proof that the target ran.
///
/// The opt-in gate (`scripts/lib/optin-app-test-gate.sh`, enforced by
/// `scripts/test-optin-app-tests-reconciled.sh`, `make test-app`, and `make test` under
/// `WIKIFS_APP_TESTS=1`) asserts this suite's executed "passed after" line in
/// the run log. If the app target is dropped from the graph, dies before
/// running, or is otherwise skipped, the sentinel line is absent and the
/// invocation fails loudly instead of reporting a false green.
///
/// The inverse check also lives here: if this target executes while the
/// opt-in flag is NOT set, the graph state disagrees with the flag (the
/// mirrored #1398 anomaly), and this test fails the run too.
@Suite("Opt-in gate sentinel")
struct OptInGateSentinelTests {
    @Test("flag is set")
    func optInFlagIsSet() {
        #expect(
            ProcessInfo.processInfo.environment["WIKIFS_APP_TESTS"] == "1",
            "WikiFSAppTests executed without WIKIFS_APP_TESTS=1: the package graph contains the opt-in app test target while the opt-in flag is absent. This is the mirrored #1398 anomaly — the graph state and the gate flag disagree."
        )
    }
}
