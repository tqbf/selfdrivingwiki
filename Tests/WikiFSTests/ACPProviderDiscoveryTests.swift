#if os(macOS)
import Testing
import WikiFSEngine
import Foundation
import WikiFSEngine
@testable import WikiFSCore

/// Filesystem ACP-agent discovery (slice of #217). The discovery logic is pure
/// given an injected resolver, so it's tested without the real filesystem; a
/// live integration check confirms it against this machine's PATH.
///
@Suite(.timeLimit(.minutes(5)))
struct ACPProviderDiscoveryTests {

    // MARK: - Pure logic (injected resolver)

    @Test func discoversOnlyAgentsWhoseBinaryIsFound() {
        let catalog = [
            KnownACPAgent(id: ProviderID(rawValue: "a"), label: "A", summary: "", detectExecutable: "a", command: ["a", "--acp"]),
            KnownACPAgent(id: ProviderID(rawValue: "b"), label: "B", summary: "", detectExecutable: "b", command: ["b", "acp"]),
            KnownACPAgent(id: ProviderID(rawValue: "c"), label: "C", summary: "", detectExecutable: "c", command: ["c", "--acp"]),
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
        #expect(found.map(\.agent.id) == [ProviderID(rawValue: "a"), ProviderID(rawValue: "c")])
        #expect(found[0].resolvedPath == "/usr/local/bin/a")
        #expect(found[1].resolvedPath == "/opt/homebrew/bin/c")
    }

    @Test func emptyCatalogDiscoversNothing() {
        #expect(ACPProviderDiscovery.discover(in: [], resolve: { _ in .found(path: "/x") }).isEmpty)
    }

    @Test func allMissingDiscoversNothing() {
        let catalog = [KnownACPAgent(id: ProviderID(rawValue: "a"), label: "A", summary: "", detectExecutable: "a", command: ["a"])]
        #expect(ACPProviderDiscovery.discover(in: catalog, resolve: { _ in .missing(reason: "nope") }).isEmpty)
    }

    @Test func defaultCatalogIsNonEmptyAndClaudeAcpPresent() {
        // The default chat provider (Claude via the ACP wrapper) IS in the catalog;
        // the legacy `claude -p` CLI id is NOT (driven via ClaudeCLIBackend).
        #expect(!ACPProviderCatalog.agents.isEmpty)
        #expect(ACPProviderCatalog.agents.contains(where: { $0.id == ProviderID(rawValue: "claude-acp") }))
        #expect(ACPProviderCatalog.agents.allSatisfy { $0.id != ProviderID(rawValue: "claude") })
        // Each catalog command's first element is its detect executable (convention).
        for agent in ACPProviderCatalog.agents {
            #expect(agent.command.first == agent.detectExecutable)
        }
    }

    @Test func claudeAcpIsNotAutoDetectable() {
        // Claude via ACP runs through `bun` — a generic JS runtime. Finding `bun`
        // on PATH does NOT mean `@agentclientprotocol/claude-agent-acp` is
        // installed, so the catalog entry must be marked `autoDetectable: false`.
        let claude = ACPProviderCatalog.agents.first(where: { $0.id == ProviderID(rawValue: "claude-acp") })
        #expect(claude != nil)
        #expect(claude?.autoDetectable == false)
    }

    @Test func skipsNonAutoDetectableEvenWhenBinaryIsFound() {
        // A runtime-launched agent (detectExecutable == "bun" here) must NOT
        // appear in `discover()` output, even when its runtime is on PATH —
        // otherwise users see "Claude detected" just because they have bun.
        let catalog = [
            KnownACPAgent(id: ProviderID(rawValue: "claude-acp"), label: "Claude", summary: "",
                         detectExecutable: "bun", command: ["bun", "x", "pkg"],
                         autoDetectable: false),
            KnownACPAgent(id: ProviderID(rawValue: "gemini"), label: "Gemini", summary: "",
                         detectExecutable: "gemini", command: ["gemini", "--acp"]),
        ]
        let resolve: (String) -> PathPreflight.Result = { exe in
            // Both binaries "found" — but only the autoDetectable one should surface.
            .found(path: "/usr/local/bin/\(exe)")
        }
        let found = ACPProviderDiscovery.discover(in: catalog, resolve: resolve)
        #expect(found.map(\.agent.id) == [ProviderID(rawValue: "gemini")])
    }

    // MARK: - Live (this machine's PATH)

    @Test
    func liveDiscoveryMatchesFilesystem() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            Issue.record("Failed to create temp directory: \(error.localizedDescription)")
            return
        }
        defer {
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                Issue.record("Failed to remove temp directory: \(error.localizedDescription)")
            }
        }

        let catalog = [
            KnownACPAgent(
                id: ProviderID(rawValue: "one"),
                label: "One",
                summary: "",
                detectExecutable: "one",
                command: ["one", "--acp"]),
            KnownACPAgent(
                id: ProviderID(rawValue: "two"),
                label: "Two",
                summary: "",
                detectExecutable: "two",
                command: ["two", "--acp"],
                autoDetectable: false),
        ]
        _ = FileManager.default.createFile(
            atPath: directory.appendingPathComponent("one").path,
            contents: Data(),
            attributes: [.posixPermissions: 0o755])

        let discovered = await ACPProviderDiscovery.discoverOnLoginShell(
            in: catalog,
            runProcess: { _ in
                AsyncProcessResult(
                    terminationStatus: 0,
                    output: .separate(stdout: Data(directory.path.utf8), stderr: Data()))
            })
        let discoveredIDs = Set(discovered.map(\.agent.id))
        #expect(discoveredIDs.contains(ProviderID(rawValue: "one")))
        #expect(!discoveredIDs.contains(ProviderID(rawValue: "two")))
        #expect(discovered.first?.resolvedPath == directory.appendingPathComponent("one").path)
    }
}
#endif // os(macOS)
