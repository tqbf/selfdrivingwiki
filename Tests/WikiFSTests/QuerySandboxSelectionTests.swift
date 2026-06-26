import Foundation
import Testing
@testable import WikiFS
@testable import WikiFSCore

/// Tests for the pure `AgentLauncher.selectQuerySandbox` selection. The key
/// invariant (AC.5): when "Allow wiki edits" is OFF, the read-only seatbelt
/// sandbox is returned EVEN WHEN a non-nil edit sandbox is supplied — a global
/// sandbox config can never override the forced read-only boundary. When ON, the
/// edit sandbox is returned verbatim (including `nil`, the fail-open case).
@MainActor
struct QuerySandboxSelectionTests {

    private let readOnly = SandboxProfile.readOnlyInvocation(
        homePath: "/Users/test", scratchDir: "/Users/test/scratch")
    private let edit = SandboxProfile.invocation(
        homePath: "/Users/test",
        scratchDir: "/Users/test/scratch",
        wikiDBPath: "/Users/test/wiki.sqlite")

    @Test func readOnlyWinsWhenEditsDisabledEvenWithNonNilEditSandbox() {
        // A globally-enabled edit sandbox must NOT punch through the forced
        // read-only boundary when "Allow wiki edits" is off.
        let selected = AgentLauncher.selectQuerySandbox(
            allowWikiEdits: false,
            editSandbox: edit,
            readOnlySandbox: readOnly)
        #expect(selected == readOnly)
    }

    @Test func editSandboxUsedWhenEditsEnabled() {
        let selected = AgentLauncher.selectQuerySandbox(
            allowWikiEdits: true,
            editSandbox: edit,
            readOnlySandbox: readOnly)
        #expect(selected == edit)
    }

    @Test func nilEditSandboxReturnedWhenEditsEnabledAndSandboxDisabled() {
        // Fail-open: when edits are allowed but the global sandbox is off, the
        // edit sandbox is nil — returned AS-IS (un-sandboxed), NOT replaced by the
        // read-only sandbox.
        let selected = AgentLauncher.selectQuerySandbox(
            allowWikiEdits: true,
            editSandbox: nil,
            readOnlySandbox: readOnly)
        #expect(selected == nil)
    }

    @Test func readOnlyUsedWhenEditsDisabledAndEditSandboxNil() {
        let selected = AgentLauncher.selectQuerySandbox(
            allowWikiEdits: false,
            editSandbox: nil,
            readOnlySandbox: readOnly)
        #expect(selected == readOnly)
    }
}
