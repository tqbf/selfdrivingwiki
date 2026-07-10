import Testing
import Foundation
import WikiFSCore

/// Filesystem ACP-agent discovery (slice of #217). The discovery logic is pure
/// given an injected resolver, so it's tested without the real filesystem; a
/// live integration check confirms it against this machine's PATH.
@Suite
struct ACPProviderDiscoveryTests {

    // MARK: - Pure logic (injected resolver)

    @Test func discoversOnlyAgentsWhoseBinaryIsFound() {
        let catalog = [
            KnownACPAgent(id: "a", label: "A", summary: "", detectExecutable: "a", command: ["a", "--acp"]),
            KnownACPAgent(id: "b", label: "B", summary: "", detectExecutable: "b", command: ["b", "acp"]),
            KnownACPAgent(id: "c", label: "C", summary: "", detectExecutable: "c", command: ["c", "--acp"]),
        ]
        // "a" and "c" present, "b" missing.
        let resolve: (String) -> PathPreflight.Result = { exe in
            switch exe {
            case "a": return .found(path: "/usr/local/bin/a")
            case "c": return .found(path: "/opt/homebrew/bin/c")
            default: return .missing(reason: "not found")
            }
        }
        let found = ACPProviderDiscovery.discover(in: catalog, resolve: resolve)
        #expect(found.map(\.agent.id) == ["a", "c"])
        #expect(found[0].resolvedPath == "/usr/local/bin/a")
        #expect(found[1].resolvedPath == "/opt/homebrew/bin/c")
    }

    @Test func emptyCatalogDiscoversNothing() {
        #expect(ACPProviderDiscovery.discover(in: [], resolve: { _ in .found(path: "/x") }).isEmpty)
    }

    @Test func allMissingDiscoversNothing() {
        let catalog = [KnownACPAgent(id: "a", label: "A", summary: "", detectExecutable: "a", command: ["a"])]
        #expect(ACPProviderDiscovery.discover(in: catalog, resolve: { _ in .missing(reason: "nope") }).isEmpty)
    }

    @Test func defaultCatalogIsNonEmptyAndClaudeAbsent() {
        // Claude is deliberately NOT in the ACP catalog (driven via ClaudeCLIBackend).
        #expect(!ACPProviderCatalog.agents.isEmpty)
        #expect(ACPProviderCatalog.agents.allSatisfy { $0.id != "claude" })
        // Each catalog command's first element is its detect executable (convention).
        for agent in ACPProviderCatalog.agents {
            #expect(agent.command.first == agent.detectExecutable)
        }
    }

    // MARK: - Live (this machine's PATH)

    @Test(.tags(.integration))
    func liveDiscoveryFindsInstalledAgents() {
        // Gemini + Hermes are confirmed installed on this machine. Discovery must
        // find them (and must NOT crash on the missing ones). This validates the
        // real login-shell PATH resolver end-to-end.
        let found = ACPProviderDiscovery.discover()
        let foundIDs = Set(found.map(\.agent.id))
        #expect(foundIDs.contains("gemini"))
        #expect(foundIDs.contains("hermes"))
        // Resolved paths are absolute.
        for d in found {
            #expect(d.resolvedPath.hasPrefix("/"))
        }
    }
}
