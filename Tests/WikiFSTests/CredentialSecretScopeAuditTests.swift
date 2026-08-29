import Foundation
import Testing
@testable import WikiFSCore
@testable import WikiFSEngine
import WikiFSTypes

/// Secret-scope audit (issue #1159 — AC.5): known provider API-key variables
/// cannot survive decode normalization, write boundaries, or provider spawn
/// preparation as sidecar data. Non-secret environment variables must still
/// round-trip unchanged.
struct CredentialSecretScopeAuditTests {

    /// A legacy sidecar payload with a plaintext API key — decodes today,
    /// must decode SECRET-FREE after the #1159 boundary.
    private static let legacyJSON = """
    {
      "providers": [
        {
          "id": "claude-acp",
          "label": "Claude",
          "command": ["claude", "--acp"],
          "env": {
            "ANTHROPIC_API_KEY": "sk-plaintext-legacy",
            "CLAUDE_CODE_EXECUTABLE": "/usr/local/bin/claude"
          },
          "enabled": true,
          "isDefault": true
        }
      ],
      "generation": 7
    }
    """

    @Test func decodeNormalizationDropsKnownSecretVariables() throws {
        let data = Data(Self.legacyJSON.utf8)
        let config = try JSONDecoder().decode(AgentProvidersConfig.self, from: data)
        let provider = try #require(config.providers.first)
        #expect(provider.env["ANTHROPIC_API_KEY"] == nil)
        // Non-secret env survives.
        #expect(provider.env["CLAUDE_CODE_EXECUTABLE"] == "/usr/local/bin/claude")
        #expect(config.generation == 7)
    }

    @Test func decodeReEncodesWithoutTheSecret() throws {
        let data = Data(Self.legacyJSON.utf8)
        let config = try JSONDecoder().decode(AgentProvidersConfig.self, from: data)
        let encoded = try JSONEncoder().encode(config)
        let payload = String(decoding: encoded, as: UTF8.self)
        #expect(payload.contains("sk-plaintext-legacy") == false)
        #expect(payload.contains("ANTHROPIC_API_KEY") == false)
    }

    @Test func writeBoundaryStripsInMemorySmuggledSecrets() async throws {
        // An in-place mutation bypasses init/decode — the WRITE boundary must
        // still keep the plaintext off disk.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("scope-audit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let config = AgentProvidersConfig.seed(discovered: [])
        var smuggled = config
        smuggled.providers[0].env["ANTHROPIC_API_KEY"] = "sk-smuggled"
        try smuggled.writeAtomically(to: directory)
        let persisted = try String(
            contentsOf: directory.appendingPathComponent("agent-providers.json"),
            encoding: .utf8)
        #expect(persisted.contains("sk-smuggled") == false)
        #expect(persisted.contains("ANTHROPIC_API_KEY") == false)
    }

    @Test func valueMutationsPreserveNonSecretEnvironment() {
        var provider = AgentProvider(
            id: ProviderID(rawValue: "gemini"),
            label: "Gemini",
            env: ["GOOGLE_GENAI_USE_VERTEXAI": "1"])
        // The #1159 funnel (init/normalized) keeps non-secret values.
        let roundTripped = AgentProvidersConfig(providers: [provider])
        #expect(
            roundTripped.providers.first?.env["GOOGLE_GENAI_USE_VERTEXAI"] == "1")
        // And a secret present in memory cannot enter a fresh config.
        provider.env["GEMINI_API_KEY"] = "AIza-secret"
        let cleaned = AgentProvidersConfig(providers: [provider])
        #expect(cleaned.providers.first?.env["GEMINI_API_KEY"] == nil)
        #expect(
            cleaned.providers.first?.env["GOOGLE_GENAI_USE_VERTEXAI"] == "1")
    }

    @Test func spawnPreparationResolvesSecretsOnlyFromTheService() throws {
        // The spawn seam resolves known secrets from the credential service,
        // not from the sidecar provider: a stripped provider + a configured
        // service yields exactly the resolved env hint, nothing else.
        let reference = try #require(CredentialReference.providerSecret(
            providerID: ProviderID(rawValue: "claude-acp"), variable: .anthropic))
        let credentials = InMemoryCredentialService(seed: [reference: "sk-resolved"])
        let secrets = ProviderSecretEnvironment.resolvedSpawnSecrets(
            for: ProviderID(rawValue: "claude-acp"), resolving: credentials)
        #expect(secrets == ["ANTHROPIC_API_KEY": "sk-resolved"])

        // A provider with a plaintext env secret cannot influence the spawn:
        // the sidecar layer stripped it at decode.
        let legacy = try JSONDecoder().decode(
            AgentProvidersConfig.self, from: Data(Self.legacyJSON.utf8))
        #expect(legacy.providers[0].env["ANTHROPIC_API_KEY"] == nil)
    }
}

/// Provider runtime spawn-secret tests (plan step 29): each selected provider
/// receives ONLY its own resolved known secret variables, rotation is visible
/// on the next preparation, and non-secret `provider.env` behavior is
/// unchanged.
@Suite(.serialized)
struct AgentProviderSpawnSecretTests {

    /// Unwrapping helper: these provider ids are grammar-valid literals.
    private func ref(
        _ provider: String, _ variable: ProviderSecretEnvironmentVariable
    ) -> CredentialReference {
        guard let reference = CredentialReference.providerSecret(
            providerID: ProviderID(rawValue: provider), variable: variable)
        else { preconditionFailure("test provider id must satisfy the grammar") }
        return reference
    }

    @Test func eachProviderReceivesOnlyItsOwnSecrets() async throws {
        let credentials = InMemoryCredentialService(seed: [
            ref("claude-acp", .anthropic): "sk-claude",
            ref("codex", .openAI): "sk-openai",
        ])
        let claudeSecrets = ProviderSecretEnvironment.resolvedSpawnSecrets(
            for: ProviderID(rawValue: "claude-acp"), resolving: credentials)
        #expect(claudeSecrets == ["ANTHROPIC_API_KEY": "sk-claude"])
        let codexSecrets = ProviderSecretEnvironment.resolvedSpawnSecrets(
            for: ProviderID(rawValue: "codex"), resolving: credentials)
        #expect(codexSecrets == ["OPENAI_API_KEY": "sk-openai"])
    }

    @Test func rotationIsVisibleOnTheNextResolution() async throws {
        let credentials = InMemoryCredentialService()
        let providerID = ProviderID(rawValue: "claude-acp")
        let reference = ref("claude-acp", .anthropic)
        try credentials.set("sk-first", for: reference)
        #expect(
            ProviderSecretEnvironment.resolvedSpawnSecrets(
                for: providerID, resolving: credentials)["ANTHROPIC_API_KEY"] == "sk-first")
        // Rotate the value in the service — the next preparation (i.e. the
        // next resolution) observes the new value without any rebuild.
        try credentials.set("sk-rotated", for: reference)
        #expect(
            ProviderSecretEnvironment.resolvedSpawnSecrets(
                for: providerID, resolving: credentials)["ANTHROPIC_API_KEY"] == "sk-rotated")
    }

    @Test func runtimeMergesResolvedSecretsIntoSpawnHints() async throws {
        // Full runtime path: the prepared backend's hints carry the resolved
        // secret under the env. prefix, merged over the non-secret provider env.
        let credentials = InMemoryCredentialService(seed: [
            ref("claude-acp", .anthropic): "sk-runtime",
        ])
        let config = AgentProvidersConfig(
            providers: [
                AgentProvider(
                    id: ProviderID(rawValue: "claude-acp"),
                    label: "Claude",
                    command: ["/bin/echo"],
                    env: ["CLAUDE_CODE_EXECUTABLE": "/bin/claude"]),
            ],
            selectedModelIds: ["claude-acp": ModelID(rawValue: "sonnet")])
        let runtime = AgentProviderRuntime(
            readConfiguration: { config },
            resolveCommand: { providers in
                Dictionary(uniqueKeysWithValues: providers.map { ($0.id, $0.command ?? []) })
            },
            readCredential: { _ in nil },
            readSpawnSecrets: {
                ProviderSecretEnvironment.resolvedSpawnSecrets(
                    for: $0, resolving: credentials)
            },
            resolvePermissionPolicy: { _ in .bypass })
        let preparation = try await runtime.prepare(.interactive)
        let token = preparation.selection.token
        defer { Task { await runtime.release(token) } }
        let backend = try await runtime.preparedBackend(
            from: token, stage: .chat)
        #expect(
            backend.profile.providerHints["env.ANTHROPIC_API_KEY"] == "sk-runtime")
        // Non-secret provider env still rides the env. prefix.
        #expect(
            backend.profile.providerHints["env.CLAUDE_CODE_EXECUTABLE"] == "/bin/claude")
    }

    @Test func absentCredentialsOmitHints() async throws {
        let credentials = InMemoryCredentialService()
        let config = AgentProvidersConfig(
            providers: [
                AgentProvider(
                    id: ProviderID(rawValue: "claude-acp"),
                    label: "Claude",
                    command: ["/bin/echo"]),
            ],
            selectedModelIds: ["claude-acp": ModelID(rawValue: "sonnet")])
        let runtime = AgentProviderRuntime(
            readConfiguration: { config },
            resolveCommand: { providers in
                Dictionary(uniqueKeysWithValues: providers.map { ($0.id, $0.command ?? []) })
            },
            readCredential: { _ in nil },
            readSpawnSecrets: {
                ProviderSecretEnvironment.resolvedSpawnSecrets(
                    for: $0, resolving: credentials)
            },
            resolvePermissionPolicy: { _ in .bypass })
        let preparation = try await runtime.prepare(.interactive)
        let token = preparation.selection.token
        defer { Task { await runtime.release(token) } }
        let backend = try await runtime.preparedBackend(from: token, stage: .chat)
        #expect(backend.profile.providerHints["env.ANTHROPIC_API_KEY"] == nil)
        #expect(backend.profile.providerHints["env.GEMINI_API_KEY"] == nil)
        #expect(backend.profile.providerHints["env.OPENAI_API_KEY"] == nil)
    }
}
