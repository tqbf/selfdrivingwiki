import Foundation
import Testing
@testable import WikiFSCore
import WikiFSTypes

/// The one-shot provider sidecar → Keychain migration (issue #1159 — AC.5,
/// plan step 17 / Risk 13). Covers known-key classification, provider-scoped
/// references, successful migration, equal-value duplicate removal, conflict
/// preservation, failed-write preservation, idempotence, concurrent sidecar
/// mutation, and removal of plaintext after success.
///
/// Uses `InMemoryCredentialService` as the credential backend — the
/// migration's CONTRACT is backend-independent (it speaks the service
/// protocols); the real-Keychain backend is covered by the opt-in
/// multiprocess fixture.
@Suite(.serialized)
struct AgentProviderCredentialMigrationTests {

    /// Unwrapping helper: these provider ids are grammar-valid literals, so a
    /// nil factory result is a test bug.
    private func ref(
        _ provider: String, _ variable: ProviderSecretEnvironmentVariable
    ) -> CredentialReference {
        guard let reference = CredentialReference.providerSecret(
            providerID: ProviderID(rawValue: provider), variable: variable)
        else { preconditionFailure("test provider id must satisfy the grammar") }
        return reference
    }

    // MARK: Fixtures

    /// Writes RAW sidecar JSON with legacy plaintext secrets still present.
    /// Deliberately NOT `AgentProvidersConfig.writeAtomically` — the #1159
    /// write boundary would strip the secrets, and the migration's input is
    /// precisely a legacy file that predates that boundary.
    private func seedRawSidecar(
        directory: URL,
        providerID: String = "claude-acp",
        env: [String: String]
    ) throws {
        let envJSON = String(decoding: try JSONSerialization.data(withJSONObject: env), as: UTF8.self)
        let json = """
        {"providers":[{"id":"\(providerID)","label":"Seeded","command":["claude","--acp"],"env":\(envJSON),"enabled":true,"isDefault":true}],"generation":0}
        """
        try Data(json.utf8).write(
            to: directory.appendingPathComponent(AgentProvidersConfig.fileName))
    }

    private func makeStore(_ directory: URL) -> AgentProvidersConfigStore {
        AgentProvidersConfigStore(directory: directory)
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("migration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: Classification + references

    @Test func knownSecretVariablesClassifyExactly() {
        #expect(ProviderSecretEnvironmentVariable.isKnownSecret("ANTHROPIC_API_KEY"))
        #expect(ProviderSecretEnvironmentVariable.isKnownSecret("GEMINI_API_KEY"))
        #expect(ProviderSecretEnvironmentVariable.isKnownSecret("OPENAI_API_KEY"))
        #expect(!ProviderSecretEnvironmentVariable.isKnownSecret("CLAUDE_CODE_EXECUTABLE"))
        #expect(!ProviderSecretEnvironmentVariable.isKnownSecret("anthropic_api_key"))
        #expect(!ProviderSecretEnvironmentVariable.isKnownSecret(""))
        #expect(ProviderSecretEnvironmentVariable.allCases.count == 3)
    }

    @Test func providerScopedReferencesAreDistinctPerProviderAndVariable() {
        let claude = ref("claude-acp", .anthropic)
        let geminiProvider = ref("claude-acp", .gemini)
        #expect(claude != geminiProvider)
        #expect(CredentialLocations.location(for: claude).service
            == "org.sockpuppet.WikiFS.credentials")
    }

    // MARK: Migration semantics

    @Test func plaintextSecretsMoveToKeychainAndLeaveTheSidecar() async throws {
        let directory = try makeDirectory()
        try seedRawSidecar(directory: directory, env: ["ANTHROPIC_API_KEY": "sk-legacy"])
        let credentials = InMemoryCredentialService()
        let outcome = await AgentProviderCredentialMigrator.migrateIfNeeded(
            directory: directory, store: makeStore(directory), credentials: credentials)
        #expect(outcome.migrated.count == 1)
        // The value landed in the service under the typed reference...
        let reference = ref("claude-acp", .anthropic)
        #expect(try credentials.resolve(reference).value == "sk-legacy")
        // ...and the sidecar no longer carries it.
        let reloaded = AgentProvidersConfig.load(from: directory)
        #expect(reloaded?.providers.first?.env["ANTHROPIC_API_KEY"] == nil)
        #expect(outcome.isClean)
    }

    @Test func nonSecretEnvironmentSurvivesMigration() async throws {
        let directory = try makeDirectory()
        try seedRawSidecar(directory: directory, env: [
            "CLAUDE_CODE_EXECUTABLE": "/usr/local/bin/claude",
            "ANTHROPIC_API_KEY": "sk-legacy",
        ])
        let credentials = InMemoryCredentialService()
        _ = await AgentProviderCredentialMigrator.migrateIfNeeded(
            directory: directory, store: makeStore(directory), credentials: credentials)
        let reloaded = AgentProvidersConfig.load(from: directory)
        #expect(
            reloaded?.providers.first?.env["CLAUDE_CODE_EXECUTABLE"]
                == "/usr/local/bin/claude")
    }

    @Test func equalValueDuplicatePlaintextIsRemovedWithoutRewrite() async throws {
        let directory = try makeDirectory()
        try seedRawSidecar(directory: directory, env: ["ANTHROPIC_API_KEY": "same"])
        let credentials = InMemoryCredentialService(seed: [ref("claude-acp", .anthropic): "same"])
        let outcome = await AgentProviderCredentialMigrator.migrateIfNeeded(
            directory: directory, store: makeStore(directory), credentials: credentials)
        #expect(outcome.removedDuplicates.count == 1)
        #expect(outcome.migrated.isEmpty)
        let reloaded = AgentProvidersConfig.load(from: directory)
        #expect(reloaded?.providers.first?.env["ANTHROPIC_API_KEY"] == nil)
        // The Keychain value is untouched.
        #expect(try credentials.resolve(ref("claude-acp", .anthropic)).value == "same")
    }

    @Test func conflictingPlaintextIsNotDeletedWhenValuesDiffer() async throws {
        let directory = try makeDirectory()
        try seedRawSidecar(directory: directory, env: ["ANTHROPIC_API_KEY": "plaintext"])
        let credentials = InMemoryCredentialService(seed: [ref("claude-acp", .anthropic): "keychain-value"])
        let outcome = await AgentProviderCredentialMigrator.migrateIfNeeded(
            directory: directory, store: makeStore(directory), credentials: credentials)
        // Conflict: preserve BOTH values, overwrite nothing, surface bounded status.
        #expect(outcome.conflicts.count == 1)
        #expect(outcome.migrated.isEmpty)
        #expect(outcome.isClean == false)
        // The plaintext entry survives ON DISK (decode strips it from
        // memory by design — the file is the durability contract here).
        let persisted = try String(
            contentsOf: directory.appendingPathComponent("agent-providers.json"),
            encoding: .utf8)
        #expect(persisted.contains("ANTHROPIC_API_KEY") == true)
        #expect(persisted.contains("plaintext") == true)
        #expect(try credentials.resolve(ref("claude-acp", .anthropic)).value == "keychain-value")
        // The bounded report carries names only — never a value.
        let mirrored = "\(outcome)"
        #expect(mirrored.contains("plaintext") == false)
        #expect(mirrored.contains("keychain-value") == false)
    }

    @Test func failedWritePreservesThePlaintextEntry() async throws {
        let directory = try makeDirectory()
        try seedRawSidecar(directory: directory, env: ["GEMINI_API_KEY": "gem-legacy"])
        let credentials = FailingWriteCredentialService()
        let outcome = await AgentProviderCredentialMigrator.migrateIfNeeded(
            directory: directory, store: makeStore(directory), credentials: credentials)
        #expect(outcome.failures.count == 1)
        // The failed entry's plaintext survives on disk (never lose a key).
        let persisted = try String(
            contentsOf: directory.appendingPathComponent("agent-providers.json"),
            encoding: .utf8)
        #expect(persisted.contains("GEMINI_API_KEY") == true)
        #expect(persisted.contains("gem-legacy") == true)
    }

    @Test func unmappableProviderKeepsPlaintextAndReports() async throws {
        let directory = try makeDirectory()
        try seedRawSidecar(
            directory: directory, providerID: "my agent",
            env: ["ANTHROPIC_API_KEY": "sk-orphan"])
        let credentials = InMemoryCredentialService()
        let outcome = await AgentProviderCredentialMigrator.migrateIfNeeded(
            directory: directory, store: makeStore(directory), credentials: credentials)
        #expect(outcome.unmappable.count == 1)
        // The unmappable plaintext survives on disk untouched.
        let persisted = try String(
            contentsOf: directory.appendingPathComponent("agent-providers.json"),
            encoding: .utf8)
        #expect(persisted.contains("ANTHROPIC_API_KEY") == true)
        #expect(persisted.contains("sk-orphan") == true)
    }

    @Test func migrationIsIdempotent() async throws {
        let directory = try makeDirectory()
        try seedRawSidecar(directory: directory, env: ["ANTHROPIC_API_KEY": "sk-twice"])
        let credentials = InMemoryCredentialService()
        let store = makeStore(directory)
        let first = await AgentProviderCredentialMigrator.migrateIfNeeded(
            directory: directory, store: store, credentials: credentials)
        #expect(first.migrated.count == 1)
        let second = await AgentProviderCredentialMigrator.migrateIfNeeded(
            directory: directory, store: store, credentials: credentials)
        #expect(second.migrated.isEmpty)
        #expect(second.removedDuplicates.isEmpty)
        #expect(second.isClean)
    }

    @Test func cleanSidecarSkipsTheLockedMutation() async throws {
        let directory = try makeDirectory()
        try seedRawSidecar(directory: directory, env: ["CLAUDE_CODE_EXECUTABLE": "/x"])
        let credentials = InMemoryCredentialService()
        let outcome = await AgentProviderCredentialMigrator.migrateIfNeeded(
            directory: directory, store: makeStore(directory), credentials: credentials)
        #expect(outcome.migrated.isEmpty)
        #expect(outcome.isClean)
    }

    @Test func concurrentSidecarMutationsStayConsistent() async throws {
        let directory = try makeDirectory()
        try seedRawSidecar(directory: directory, env: [
            "ANTHROPIC_API_KEY": "sk-a",
            "OPENAI_API_KEY": "sk-b",
        ])
        let credentials = InMemoryCredentialService()
        let store = makeStore(directory)
        // Two overlapping migration passes (the in-process gate + file lock
        // serialize them; the raw scan may observe the legacy file in both).
        // The DURABLE invariants hold regardless of interleaving: the sidecar
        // ends secret-free and the service holds both resolved values.
        async let first: AgentProviderCredentialMigrationReport =
            AgentProviderCredentialMigrator.migrateIfNeeded(
                directory: directory, store: store, credentials: credentials)
        async let second: AgentProviderCredentialMigrationReport =
            AgentProviderCredentialMigrator.migrateIfNeeded(
                directory: directory, store: store, credentials: credentials)
        let (firstReport, secondReport) = await (first, second)
        #expect(firstReport.conflicts.isEmpty && firstReport.failures.isEmpty)
        #expect(secondReport.conflicts.isEmpty && secondReport.failures.isEmpty)
        let reloaded = AgentProvidersConfig.load(from: directory)
        #expect(reloaded?.providers.first?.env["ANTHROPIC_API_KEY"] == nil)
        #expect(reloaded?.providers.first?.env["OPENAI_API_KEY"] == nil)
        #expect(try credentials.resolve(ref("claude-acp", .anthropic)).value == "sk-a")
        #expect(try credentials.resolve(ref("claude-acp", .openAI)).value == "sk-b")
        // The persisted sidecar carries no plaintext.
        let persisted = try String(
            contentsOf: directory.appendingPathComponent("agent-providers.json"),
            encoding: .utf8)
        #expect(persisted.contains("sk-a") == false)
        #expect(persisted.contains("sk-b") == false)
    }

    @Test func removalOfPlaintextPersistsAfterSuccess() async throws {
        let directory = try makeDirectory()
        try seedRawSidecar(directory: directory, env: ["OPENAI_API_KEY": "sk-openai"])
        let credentials = InMemoryCredentialService()
        _ = await AgentProviderCredentialMigrator.migrateIfNeeded(
            directory: directory, store: makeStore(directory), credentials: credentials)
        let persisted = try String(
            contentsOf: directory.appendingPathComponent("agent-providers.json"),
            encoding: .utf8)
        #expect(persisted.contains("sk-openai") == false)
        #expect(persisted.contains("OPENAI_API_KEY") == false)
    }
}

/// A credential service whose writes FAIL (exercising never-lose-a-key).
struct FailingWriteCredentialService: CredentialDescribing, CredentialWriting,
    CredentialResolving {
    func describe(_ reference: CredentialReference) -> CredentialInfo {
        CredentialInfo(
            reference: reference, isConfigured: false,
            source: .keychain, isWritable: true)
    }

    func describe(_ references: [CredentialReference]) -> [CredentialReference: CredentialInfo] {
        [:]
    }

    var maximumDescribeBatchSize: Int { 64 }

    func set(_ value: String?, for reference: CredentialReference) throws {
        throw CredentialStoreError.writeFailed(operation: "add", status: -25299)
    }

    func unset(_ reference: CredentialReference) throws {
        throw CredentialStoreError.writeFailed(operation: "delete", status: -25299)
    }

    func resolve(_ reference: CredentialReference) throws -> ResolvedCredential {
        throw CredentialStoreError.notConfigured(reference)
    }
}
