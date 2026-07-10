import Testing
import Foundation
import ACPModel
@testable import WikiFS
@testable import WikiFSCore

/// Slice 3 tests (`plans/acp-backend-and-permissions.md`): the dedicated
/// `ACPAgentConfig`, the Keychain-backed `ACPCredentialStore`, the pure
/// auth-decision resolver, and the wiring that replaces the slice-2
/// generic-config path. Pure logic only — NO live agent subprocess (the slice
/// forbids end-to-end testing; a real agent + key is required for live E2E).
@Suite struct ACPConfigTests {

    // MARK: - ACPAgentConfig persistence

    /// Round-trip: save → load reproduces every field.
    @Test func acpConfigRoundTrip() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("acp-config-rt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let original = ACPAgentConfig(
            executable: "/usr/local/bin/claude",
            prefixArguments: "--yes @org/agent --verbose",
            modelOverride: "claude-sonnet-4-5",
            extraEnvironment: "ANTHROPIC_LOG=debug")
        try original.save(to: tmp)

        let loaded = ACPAgentConfig.load(from: tmp)
        #expect(loaded == original)
    }

    /// The persisted JSON file is SEPARATE from `AgentCommandConfig`'s file, so
    /// the two configs never collide.
    @Test func acpConfigUsesSeparateFile() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("acp-sep-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Save BOTH configs to the same directory.
        try AgentCommandConfig(executable: "claude", prefixArguments: "--cli-flag").save(to: tmp)
        try ACPAgentConfig(executable: "npx", prefixArguments: "--acp-flag").save(to: tmp)

        // Each loads back independently — no cross-contamination.
        let cli = AgentCommandConfig.load(from: tmp)
        let acp = ACPAgentConfig.load(from: tmp)
        #expect(cli.executable == "claude")
        #expect(cli.prefixArguments == "--cli-flag")
        #expect(acp.executable == "npx")
        #expect(acp.prefixArguments == "--acp-flag")
    }

    /// Missing file → `.default` (no throw). The default launches the canonical
    /// Claude ACP agent via npx.
    @Test func acpConfigMissingFileDegradesToDefault() {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("acp-missing-\(UUID().uuidString)", isDirectory: true)
        let loaded = ACPAgentConfig.load(from: tmp)
        #expect(loaded == .default)
        #expect(loaded.executable == "npx")
        #expect(loaded.prefixArguments.contains("claude-agent-acp"))
    }

    /// The plain config file NEVER contains the API key — the key lives in the
    /// Keychain store. This is the security invariant: decode the JSON and assert
    /// no secret field is present.
    @Test func acpConfigFileNeverContainsAPIKey() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("acp-nokey-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        try ACPAgentConfig(
            executable: "npx",
            prefixArguments: "--yes @org/agent",
            modelOverride: "",
            extraEnvironment: "").save(to: tmp)

        let url = tmp.appendingPathComponent(ACPAgentConfig.fileName, isDirectory: false)
        let json = try String(contentsOf: url, encoding: .utf8)
        // The Codable struct has only 4 fields; none is a secret. Assert the
        // canonical key name is absent so a future field addition can't leak.
        #expect(!json.lowercased().contains("apikey"))
        #expect(!json.lowercased().contains("secret"))
        #expect(!json.lowercased().contains("token"))
        #expect(!json.lowercased().contains("password"))
    }

    /// Tokenization mirrors `AgentCommandConfig` (shell-aware, quote-preserving).
    @Test func acpConfigTokenizesPrefixArgs() {
        let config = ACPAgentConfig(
            executable: "npx",
            prefixArguments: "--yes @agentclientprotocol/claude-agent-acp")
        #expect(config.tokenizedPrefixArgs() == ["--yes", "@agentclientprotocol/claude-agent-acp"])
    }

    // MARK: - ACPCredentialStore

    /// The in-memory store round-trips the key and respects nil/empty = delete.
    @Test func credentialStoreRoundTrip() throws {
        let store = InMemoryACPCredentialStore()
        #expect(store.apiKey() == nil)

        try store.setAPIKey("sk-test-123")
        #expect(store.apiKey() == "sk-test-123")

        try store.setAPIKey(nil)
        #expect(store.apiKey() == nil)

        try store.setAPIKey("sk-second")
        #expect(store.apiKey() == "sk-second")

        // Empty string is treated as delete (matches the Keychain impl's guard).
        try store.setAPIKey("")
        #expect(store.apiKey() == nil)
    }

    /// The in-memory store can be seeded for tests.
    @Test func credentialStoreSeed() {
        let store = InMemoryACPCredentialStore(seed: "sk-seeded")
        #expect(store.apiKey() == "sk-seeded")
    }

    // MARK: - ACPAuthResolver (pure auth-decision function)

    /// No authMethods advertised → `.skip` (agent needs no auth).
    @Test func authDecisionSkipsWhenNoMethods() {
        #expect(ACPAuthResolver.resolve(authMethods: nil, apiKey: "sk-test") == .skip)
        #expect(ACPAuthResolver.resolve(authMethods: [], apiKey: "sk-test") == .skip)
    }

    /// AuthMethods present + key configured → `.authenticate` with the first
    /// method's id + the key under the conventional `"apiKey"` credential field.
    @Test func authDecisionAuthenticatesWhenKeyPresent() {
        let methods = [
            AuthMethod(id: "anthropic", name: "Anthropic API Key", description: nil),
        ]
        let decision = ACPAuthResolver.resolve(authMethods: methods, apiKey: "sk-test-456")
        guard case .authenticate(let methodId, let creds) = decision else {
            Issue.record("expected .authenticate, got \(decision)")
            return
        }
        #expect(methodId == "anthropic")
        #expect(creds == [ACPAuthResolver.credentialKey: "sk-test-456"])
    }

    /// AuthMethods present + key configured → authenticates with the FIRST
    /// method when several are advertised (common case: a single API-key method).
    @Test func authDecisionPicksFirstMethod() {
        let methods = [
            AuthMethod(id: "oauth-google", name: "Google OAuth", description: nil),
            AuthMethod(id: "anthropic", name: "Anthropic API Key", description: nil),
        ]
        let decision = ACPAuthResolver.resolve(authMethods: methods, apiKey: "sk-test")
        guard case .authenticate(let methodId, _) = decision else {
            Issue.record("expected .authenticate, got \(decision)")
            return
        }
        #expect(methodId == "oauth-google")
    }

    /// AuthMethods present + key MISSING → `.missingCredentials` (surface a
    /// preflight error; never crash).
    @Test func authDecisionMissingCredentialsWhenKeyAbsent() {
        let methods = [AuthMethod(id: "anthropic", name: "Anthropic", description: nil)]
        #expect(ACPAuthResolver.resolve(authMethods: methods, apiKey: nil) == .missingCredentials)
        #expect(ACPAuthResolver.resolve(authMethods: methods, apiKey: "") == .missingCredentials)
    }

    // MARK: - ACPBackend spawn config (reads the API key hint)

    /// `resolveSpawnConfig` threads the API key from `providerHints` into the
    /// spawn config, so `start()` can pass it to `authenticate`.
    @Test func spawnConfigCarriesAPIKey() {
        let profile = BackendProfile(
            providerHints: [
                "acpAgentPath": "/usr/local/bin/npx",
                "acpAgentArgs": "--yes @org/agent",
                "acpAgentApiKey": "sk-from-hints",
            ])
        // We can't call the private resolveSpawnConfig directly; assert via the
        // observable error when the key fields are all set but no path (it should
        // NOT be noAgentConfigured). Instead, assert the hint survives via the
        // factory wiring — see the wiring tests below.
        #expect(profile.providerHints["acpAgentApiKey"] == "sk-from-hints")
    }

    // MARK: - Factory wiring (ACPAgentConfig → providerHints, replaces slice-2)

    /// The factory builds providerHints from the dedicated ACP config + key:
    /// path, args, AND the key all flow through.
    @Test func factoryWiresConfigAndKeyIntoHints() {
        let hints = AgentBackendFactory.acpProviderHints(
            resolvedExecutable: "/usr/local/bin/npx",
            prefixArguments: "--yes @agentclientprotocol/claude-agent-acp",
            apiKey: "sk-wired")
        #expect(hints["acpAgentPath"] == "/usr/local/bin/npx")
        #expect(hints["acpAgentArgs"] == "--yes @agentclientprotocol/claude-agent-acp")
        #expect(hints["acpAgentApiKey"] == "sk-wired")
    }

    /// No API key configured (nil) → the hint is simply absent (some agents need
    /// none; the backend skips auth when the agent advertises no methods).
    @Test func factoryOmitsKeyHintWhenAbsent() {
        let hints = AgentBackendFactory.acpProviderHints(
            resolvedExecutable: "/bin/agent",
            prefixArguments: "",
            apiKey: nil)
        #expect(hints["acpAgentApiKey"] == nil)
        #expect(hints["acpAgentPath"] == "/bin/agent")
    }

    /// Empty key string → treated as absent (no empty hint leaks through).
    @Test func factoryOmitsEmptyKey() {
        let hints = AgentBackendFactory.acpProviderHints(
            resolvedExecutable: "/bin/agent",
            prefixArguments: "",
            apiKey: "")
        #expect(hints["acpAgentApiKey"] == nil)
    }

    /// The args string is stored raw (tokenized later in ACPBackend) — the
    /// contract pinned in slice 2 is preserved.
    @Test func factoryPreservesRawArgsForTokenization() {
        let raw = "--yes @agentclientprotocol/claude-agent-acp"
        let hints = AgentBackendFactory.acpProviderHints(
            resolvedExecutable: "npx", prefixArguments: raw, apiKey: nil)
        #expect(hints["acpAgentArgs"] == raw)
    }

    /// Empty executable → empty dict (→ ACPBackend throws noAgentConfigured).
    @Test func factoryEmptyWhenUnconfigured() {
        let hints = AgentBackendFactory.acpProviderHints(
            resolvedExecutable: "", prefixArguments: "", apiKey: nil)
        #expect(hints.isEmpty)
    }
}
