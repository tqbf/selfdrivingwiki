import Testing
import Foundation
@testable import WikiFSCore

/// #665 — the official ACP registry client. Pins:
///
/// - **Codable**: a small synthetic payload round-trips with the right
///   distribution variant (`.npx` / `.binary` / `.uvx`).
/// - **Bundled snapshot**: the committed `Resources/acp-registry.json`
///   decodes and maps to ≥30 agents (the official registry at the time of the
///   snapshot is 38; a slow shrink on the CDN is acceptable, a 0 is a bug).
/// - **Mapping invariants** for each distribution type:
///   - `npx`  → `command = ["npx", package] + args`, `detectExecutable == "npx"`
///   - `uvx`  → `command = ["uvx", package] + args`, `detectExecutable == "uvx"`
///   - `binary (darwin-aarch64)` → strips a leading `./`, `command = [cmd] + args`
///   - `binary` without a darwin platform → entry SKIPPED
///   - `nil distribution` → entry SKIPPED
///   - For every mapped agent, `command.first == detectExecutable` (the
///     catalog convention pinned by `ACPProviderCatalogTests`).
/// - **`ACPProviderCatalog.agents` (sync accessor)** returns the
///   `fallbackCatalog` list when the bundled snapshot is absent (true under
///   `swift test`, where `Bundle.main` is the test runner, not the .app).
/// - **`loadAgents()` (integration)** always returns SOME list — the
///   network/cache/bundled-fallback chain can never produce an empty result.
@Suite
struct ACPRegistryTests {

    // MARK: - Helpers

    /// Locate the repo's bundled snapshot (`Resources/acp-registry.json`)
    /// relative to this test file — same trick `MarkdownEditorWarningTests`
    /// uses to reach `Resources/markdownlint.bundle.js` under `swift test`
    /// (no app bundle).
    private func bundledSnapshotURL() -> URL? {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../../Resources/acp-registry.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    private func decode(_ json: String) throws -> ACPRegistryResponse {
        guard let data = json.data(using: .utf8) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "non-utf8"))
        }
        return try JSONDecoder().decode(ACPRegistryResponse.self, from: data)
    }

    // MARK: - Codable round-trip

    @Test func decodesNpxDistribution() throws {
        let json = """
        {"version":"1.0.0","agents":[
          {"id":"claude-acp","name":"Claude Agent","distribution":
            {"npx":{"package":"@agentclientprotocol/claude-agent-acp@0.59.0","args":["--acp"],"env":{"X":"1"}}}
          }
        ]}
        """
        let res = try decode(json)
        let agent = try #require(res.agents.first)
        let dist = try #require(agent.distribution)
        guard case .npx(let npx) = dist else {
            Issue.record("expected .npx"); return
        }
        #expect(npx.package == "@agentclientprotocol/claude-agent-acp@0.59.0")
        #expect(npx.args == ["--acp"])
        #expect(npx.env == ["X": "1"])
    }

    @Test func decodesBinaryDistribution() throws {
        // Realistic binary distribution shape (mirrors `amp-acp` in the registry):
        // keyed by platform, with a `./`-prefixed cmd.
        let json = """
        {"version":"1.0.0","agents":[
          {"id":"amp-acp","name":"AMP","distribution":{
            "binary":{
              "darwin-aarch64":{"archive":"https://x/y.tar.gz","cmd":"./amp-acp"},
              "linux-x86_64":{"archive":"https://x/z.tar.gz","cmd":"./amp-acp"}
            }
          }}
        ]}
        """
        let res = try decode(json)
        let agent = try #require(res.agents.first)
        let dist = try #require(agent.distribution)
        guard case .binary(let platforms) = dist else {
            Issue.record("expected .binary"); return
        }
        #expect(platforms["darwin-aarch64"]?.cmd == "./amp-acp")
        #expect(platforms["linux-x86_64"]?.archive == "https://x/z.tar.gz")
    }

    @Test func decodesUvxDistribution() throws {
        let json = """
        {"version":"1.0.0","agents":[
          {"id":"fast-agent","name":"Fast Agent","distribution":
            {"uvx":{"package":"fast-agent-acp==0.9.16","args":["-x"]}}
          }
        ]}
        """
        let res = try decode(json)
        let agent = try #require(res.agents.first)
        let dist = try #require(agent.distribution)
        guard case .uvx(let uvx) = dist else {
            Issue.record("expected .uvx"); return
        }
        #expect(uvx.package == "fast-agent-acp==0.9.16")
        #expect(uvx.args == ["-x"])
    }

    @Test func decodesNilDistribution() throws {
        // An agent with no `distribution` key — must round-trip nil (and the
        // mapper must skip it, tested below).
        let json = """
        {"version":"1.0.0","agents":[
          {"id":"unreleased-agent","name":"Unreleased"}
        ]}
        """
        let res = try decode(json)
        let agent = try #require(res.agents.first)
        #expect(agent.distribution == nil)
        #expect(agent.description == nil)
    }

    // MARK: - Mapping: npx / uvx / binary

    @Test func mapsNpxToNpxCommandAndDetect() throws {
        let res = try decode("""
        {"version":"1.0.0","agents":[
          {"id":"claude-acp","name":"Claude Agent","description":"ACP wrapper",
           "distribution":{"npx":{"package":"@agentclientprotocol/claude-agent-acp@0.59.0","args":["--acp"]}}}
        ]}
        """)
        let mapped = ACPRegistryClient.mapRegistryToCatalog(res)
        let agent = try #require(mapped.first)
        #expect(agent.id == "claude-acp")
        #expect(agent.label == "Claude Agent")
        #expect(agent.summary == "ACP wrapper")
        #expect(agent.detectExecutable == "npx")
        #expect(agent.command == ["npx", "@agentclientprotocol/claude-agent-acp@0.59.0", "--acp"])
        // Convention: command[0] == detectExecutable.
        #expect(agent.command.first == agent.detectExecutable)
        // `npx` is a generic JS runtime — finding it on PATH does NOT mean the
        // agent package is installed, so auto-detect would false-positive.
        #expect(agent.autoDetectable == false)
    }

    @Test func mapsNpxWithoutArgs() throws {
        // `claude-acp` in the real registry ships with NO args key.
        let res = try decode("""
        {"version":"1.0.0","agents":[
          {"id":"claude-acp","name":"Claude Agent","distribution":{"npx":{"package":"@agentclientprotocol/claude-agent-acp@0.59.0"}}}
        ]}
        """)
        let mapped = ACPRegistryClient.mapRegistryToCatalog(res)
        let agent = try #require(mapped.first)
        #expect(agent.command == ["npx", "@agentclientprotocol/claude-agent-acp@0.59.0"])
    }

    @Test func mapsUvxToUvxCommandAndDetect() throws {
        let res = try decode("""
        {"version":"1.0.0","agents":[
          {"id":"fast-agent","name":"Fast Agent","distribution":{"uvx":{"package":"fast-agent-acp==0.9.16","args":["-x"]}}}
        ]}
        """)
        let mapped = ACPRegistryClient.mapRegistryToCatalog(res)
        let agent = try #require(mapped.first)
        #expect(agent.detectExecutable == "uvx")
        #expect(agent.command == ["uvx", "fast-agent-acp==0.9.16", "-x"])
        #expect(agent.command.first == agent.detectExecutable)
        // `uvx` is a generic Python runtime — same false-positive risk as `npx`.
        #expect(agent.autoDetectable == false)
    }

    @Test func mapsBinaryStripsLeadingDotSlash() throws {
        let res = try decode("""
        {"version":"1.0.0","agents":[
          {"id":"amp-acp","name":"AMP","distribution":{
            "binary":{"darwin-aarch64":{"archive":"https://x.tar.gz","cmd":"./amp-acp","args":["serve"]}}
          }}
        ]}
        """)
        let mapped = ACPRegistryClient.mapRegistryToCatalog(res)
        let agent = try #require(mapped.first)
        #expect(agent.detectExecutable == "amp-acp")
        #expect(agent.command == ["amp-acp", "serve"])
        #expect(agent.command.first == agent.detectExecutable)
        // `binary` distributions ship a standalone executable — the binary IS
        // the agent, so finding it on PATH means the agent is installed.
        #expect(agent.autoDetectable == true)
    }

    @Test func mapsBinaryWithoutLeadingDotSlash() throws {
        // Windows binaries skip the ./ prefix (`amp-acp.exe`) — but those
        // platforms aren't picked. On darwin, some agents may use `cmd` with
        // no `./` prefix (unusual but legal). The mapper should still produce
        // the right detect/command.
        let res = try decode("""
        {"version":"1.0.0","agents":[
          {"id":"plain","name":"Plain","distribution":{
            "binary":{"darwin-aarch64":{"cmd":"plain"}}
          }}
        ]}
        """)
        let mapped = ACPRegistryClient.mapRegistryToCatalog(res)
        let agent = try #require(mapped.first)
        #expect(agent.detectExecutable == "plain")
        #expect(agent.command == ["plain"])
    }

    @Test func mapsBinaryFallsBackToX86OnAppleSilicon() throws {
        // A registry entry with NO darwin-aarch64 (only x86_64) — must still
        // map (Rosetta runs the x86_64 binary on Apple Silicon).
        let res = try decode("""
        {"version":"1.0.0","agents":[
          {"id":"x86-only","name":"X86 Only","distribution":{
            "binary":{"darwin-x86_64":{"cmd":"./x86-only","args":["--acp"]},"linux-x86_64":{"cmd":"./x86-only"}}
          }}
        ]}
        """)
        let mapped = ACPRegistryClient.mapRegistryToCatalog(res)
        let agent = try #require(mapped.first)
        #expect(agent.detectExecutable == "x86-only")
        #expect(agent.command == ["x86-only", "--acp"])
    }

    // MARK: - Mapping: skip rules

    @Test func skipsAgentWithNilDistribution() throws {
        let res = try decode("""
        {"version":"1.0.0","agents":[
          {"id":"withnpx","name":"WithNpx","distribution":{"npx":{"package":"x"}}},
          {"id":"nodist","name":"NoDist"}
        ]}
        """)
        let mapped = ACPRegistryClient.mapRegistryToCatalog(res)
        #expect(mapped.map(\.id) == ["withnpx"])
    }

    @Test func skipsBinaryWithoutDarwinPlatform() throws {
        // A binary distributed only for linux/windows — unusable on macOS.
        let res = try decode("""
        {"version":"1.0.0","agents":[
          {"id":"linux-only","name":"Linux Only","distribution":{
            "binary":{"linux-aarch64":{"cmd":"./linux"},"linux-x86_64":{"cmd":"./linux"}}
          }}
        ]}
        """)
        let mapped = ACPRegistryClient.mapRegistryToCatalog(res)
        #expect(mapped.isEmpty)
    }

    @Test func keepsConventionCommandFirstEqualsDetect() throws {
        // For every entry in the real bundled snapshot (when present),
        // `command.first == detectExecutable` — the catalog convention that
        // `ACPProviderDiscoveryTests` and `AgentProviderCatalogTests` pin.
        guard let url = bundledSnapshotURL() else {
            // Snapshot absent (e.g. fetched-into-a-tarball CI run) — skip
            // rather than fail; the synthetic-payload tests above still pin
            // the convention.
            return
        }
        let data = try Data(contentsOf: url)
        let res = try JSONDecoder().decode(ACPRegistryResponse.self, from: data)
        let mapped = ACPRegistryClient.mapRegistryToCatalog(res)
        #expect(!mapped.isEmpty)
        for agent in mapped {
            #expect(agent.command.first == agent.detectExecutable,
                    "convention broken for \(agent.id): command=\(agent.command) detect=\(agent.detectExecutable)")
        }
    }

    // MARK: - Bundled snapshot

    @Test func bundledSnapshotDecodesAndMapsToOfficialRegistry() throws {
        // The shipped snapshot must decode + map. The official registry at the
        // time of #665 has 38 agents; treat 30 as a generous floor (we'd want
        // to investigate before anything below that — but a transient
        // removal of a few entries from the live registry is fine).
        guard let url = bundledSnapshotURL() else {
            return  // Tests running where the repo snapshot isn't reachable.
        }
        let data = try Data(contentsOf: url)
        let res = try JSONDecoder().decode(ACPRegistryResponse.self, from: data)
        #expect(res.agents.count >= 30)
        let mapped = ACPRegistryClient.mapRegistryToCatalog(res)
        #expect(mapped.count >= 30)

        // Smoke: the IDs we already seed defaults for / ship in the hardcoded
        // fallback are present in the official registry snapshot.
        let ids = Set(mapped.map(\.id))
        #expect(ids.contains("claude-acp"))
        #expect(ids.contains("gemini"))
        #expect(ids.contains("opencode"))
    }

    // MARK: - Sync accessor (ACPProviderCatalog.agents)

    @Test func syncAgentsReturnsFallbackWhenNoBundle() {
        // Under `swift test`, `Bundle.main` is the test runner — it has no
        // `acp-registry.json` resource. So `ACPProviderCatalog.agents` MUST
        // degrade to `fallbackCatalog`. That keeps the existing
        // `ACPProviderDiscoveryTests.defaultCatalogIsNonEmptyAndClaudeAcpPresent`
        // and `AgentProviderCatalogTests.catalogHasExpandedEntries` assertions
        // valid under tests (they pin entries — `hermes`, `copilot`, `kiro` —
        // that aren't in the official registry snapshot).
        //
        // (In the .app, `agents` loads the bundled snapshot — the runtime
        // catalog is the official 38-agent list, not the 12-entry fallback.)
        let ids = Set(ACPProviderCatalog.agents.map(\.id))
        let fallbackIDs = Set(ACPProviderCatalog.fallbackCatalog.map(\.id))
        #expect(ids == fallbackIDs)
        #expect(ids.contains("hermes"))   // hardcoded only — NOT in official registry
        #expect(ids.contains("copilot"))  // hardcoded only
        #expect(ids.contains("kiro"))     // hardcoded only
    }

    @Test func fallbackCatalogSatisfiesConvention() {
        // The hardcoded fallback (last-resort) also keeps the
        // command.first == detectExecutable invariant — so even if everything
        // else fails, discovery + the catalog disagree on nothing.
        for agent in ACPProviderCatalog.fallbackCatalog {
            #expect(agent.command.first == agent.detectExecutable)
        }
    }

    // MARK: - Live registry round-trip (integration)

    @Test(.timeLimit(.minutes(2)))
    func loadAgentsReturnsNonEmpty() async {
        // The full chain — fresh cache / live fetch / stale cache / bundled
        // snapshot / hardcoded fallback — must always yield SOME non-empty
        // catalog. Never throws, never crashes, never blocks indefinitely.
        // Hits the network if no fresh cache (10s timeout) with a 2-min
        // per-test ceiling as the safety net.
        let agents = await ACPProviderCatalog.loadAgents()
        #expect(!agents.isEmpty)
        // The fallback (the only absolute floor) always has Claude-acp.
        #expect(agents.contains(where: { $0.id == "claude-acp" }))
        // Convention survives the round-trip through whichever source won.
        for agent in agents {
            #expect(agent.command.first == agent.detectExecutable)
        }
    }
}
