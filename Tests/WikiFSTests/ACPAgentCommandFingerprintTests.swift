import Foundation
import Testing
@testable import WikiFSCore

@Suite struct ACPAgentCommandFingerprintTests {
    private let catalog = ["codex-acp", "serve"]

    @Test func canonicalPathAndExactArgumentsMatch() throws {
        let result = ACPAgentCommandFingerprint.trustedMatch(
            configuredCommand: ["codex-acp", "serve"],
            catalogCommand: catalog,
            resolve: { _ in ["/opt/acp/bin/codex-acp", "serve"] })
        let fingerprint = try #require(result)
        #expect(fingerprint.canonicalExecutableURL.path == "/opt/acp/bin/codex-acp")
        #expect(fingerprint.arguments == ["serve"])
    }

    @Test(arguments: [
        ["codex-acp", "other"],
        ["codex-acp", "serve", "--extra"],
    ])
    func changedConfiguredArgumentsFail(_ configured: [String]) {
        let result = ACPAgentCommandFingerprint.trustedMatch(
            configuredCommand: configured,
            catalogCommand: catalog,
            resolve: { _ in ["/opt/acp/bin/codex-acp"] + Array(configured.dropFirst()) })
        #expect(result == nil)
    }

    @Test func sameBasenameAtDifferentCanonicalPathFails() {
        let result = ACPAgentCommandFingerprint.trustedMatch(
            configuredCommand: ["/custom/bin/codex-acp", "serve"],
            catalogCommand: catalog,
            resolve: { command in
                command.first == "/custom/bin/codex-acp"
                    ? ["/custom/bin/codex-acp", "serve"]
                    : ["/catalog/bin/codex-acp", "serve"]
            })
        #expect(result == nil)
    }

    @Test func unresolvedCommandFails() {
        let result = ACPAgentCommandFingerprint.trustedMatch(
            configuredCommand: catalog,
            catalogCommand: catalog,
            resolve: { _ in nil })
        #expect(result == nil)
    }

    @Test func relativeOrNoncanonicalResolvedExecutableFails() {
        #expect(ACPAgentCommandFingerprint(resolvedCommand: ["codex-acp", "serve"]) == nil)
        #expect(ACPAgentCommandFingerprint(
            resolvedCommand: ["/opt/acp/../acp/bin/codex-acp", "serve"]) == nil)
    }
}
