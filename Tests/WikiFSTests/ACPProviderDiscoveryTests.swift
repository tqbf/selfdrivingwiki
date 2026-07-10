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

    @Test func defaultCatalogIsNonEmptyAndClaudeAcpPresent() {
        // The default chat provider (Claude via the ACP wrapper) IS in the catalog;
        // the legacy `claude -p` CLI id is NOT (driven via ClaudeCLIBackend).
        #expect(!ACPProviderCatalog.agents.isEmpty)
        #expect(ACPProviderCatalog.agents.contains(where: { $0.id == "claude-acp" }))
        #expect(ACPProviderCatalog.agents.allSatisfy { $0.id != "claude" })
        // Each catalog command's first element is its detect executable (convention).
        for agent in ACPProviderCatalog.agents {
            #expect(agent.command.first == agent.detectExecutable)
        }
    }

    // MARK: - Live (this machine's PATH)

    @Test(.tags(.integration))
    func liveDiscoveryMatchesFilesystem() {
        // Machine-agnostic: for each catalog agent, discovery must report it
        // installed iff its binary is actually on the login-shell PATH. No
        // hard-coded agent names — so this passes on a CI runner that has none
        // installed (all missing → none reported) and still validates the real
        // login-shell resolver end-to-end on a machine that has some.
        let discovered = ACPProviderDiscovery.discover()
        let discoveredIDs = Set(discovered.map(\.agent.id))
        for agent in ACPProviderCatalog.agents {
            switch PathPreflight.resolveOnLoginShell(executable: agent.detectExecutable) {
            case .found:
                #expect(discoveredIDs.contains(agent.id),
                        "discovery missed installed agent \(agent.id)")
            case .missing:
                #expect(!discoveredIDs.contains(agent.id),
                        "discovery reported a non-installed agent \(agent.id)")
            }
        }
        // Resolved paths are absolute for whatever was found.
        for d in discovered {
            #expect(d.resolvedPath.hasPrefix("/"))
        }
    }
}
