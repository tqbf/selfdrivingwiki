#if os(macOS)
import Testing
import Foundation
import WikiFSEngine
import WikiFSCore

/// Review M8: unresolved gate components hard-fail to report-only BEFORE the
/// shipped manifest is consulted, and resolved components select from the
/// shipped manifest without throwing.
struct LintCoordinatorGateTests {

    @Test(arguments: [
        ("unconfigured", "claude-sonnet", "20260101" as String?, "low"),
        ("anthropic", "", "20260101" as String?, "low"),
        ("anthropic", "claude-sonnet", "20260101" as String?, "unconfigured"),
        ("anthropic", "claude-sonnet", nil as String?, "low"),
    ])
    func unresolvedComponentsAreReportOnly(
        provider: String, model: String, revision: String?, effort: String
    ) throws {
        let selection = try LintCoordinatorGate.selection(
            provider: provider, model: model, modelRevision: revision, effort: effort)
        guard case .reportOnly(let reason) = selection else {
            Issue.record("unresolved components must never authorize repairs")
            return
        }
        #expect(reason.contains("not fully resolved"))
    }

    @Test func componentsCarryTheLiveBuildPipeline() throws {
        let components = try LintCoordinatorGate.components(
            provider: "anthropic", model: "claude-sonnet",
            modelRevision: "20260101", effort: "low")
        #expect(LintAcceptanceManifest.Pipeline(components)
            == (try LintAcceptanceManifest.Pipeline.live()))
    }
}
#endif
