import Foundation
import Testing
@testable import WikiFSCore

/// The connections substrate (spike): the provider manifest decodes from JSON,
/// the app-wide store round-trips, and the legacy Zotero config migrates to a
/// connection. These are the novel, data-driven claims of issue #483 / the
/// connections plan — the UI (`SchemaForm`) renders whatever the schema decodes.
struct ConnectionModelTests {

    private func tempDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("connection-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Manifest (JSON → native form contract)

    @Test func zoteroManifestDecodesFromEmbeddedJSON() throws {
        let manifest = try #require(ProviderRegistry.manifest(for: "zotero"))
        #expect(manifest.displayName == "Zotero")
        #expect(manifest.icon == "books.vertical")
        #expect(manifest.capabilities.browse)
        #expect(manifest.backing == .native)
        // The config schema is what SchemaForm renders — order preserved.
        #expect(manifest.config.fields.map(\.name) == ["apiKey", "libraryID", "zoteroDirOverride"])
    }

    @Test func apiKeyFieldIsSecretAndPassword() throws {
        let manifest = try #require(ProviderRegistry.manifest(for: "zotero"))
        let apiKey = try #require(manifest.config.fields.first { $0.name == "apiKey" })
        #expect(apiKey.secret)
        #expect(apiKey.format == .password)
        #expect(manifest.config.secretFieldNames == ["apiKey"])
    }

    @Test func schemaFieldRoundTripsThroughJSON() throws {
        // Proves the same shape a dropped-in manifest.json would use decodes,
        // including an enum + boolean field the UI must render as Picker/Toggle.
        let json = """
        {
          "fields": [
            { "name": "topic", "title": "Topic", "type": "string", "enum": ["news", "general"] },
            { "name": "includeThreads", "title": "Include threads", "type": "boolean" }
          ]
        }
        """
        let schema = try JSONDecoder().decode(ProviderConfigSchema.self, from: Data(json.utf8))
        #expect(schema.fields.count == 2)
        #expect(schema.fields[0].enumValues == ["news", "general"])
        #expect(schema.fields[1].type == .boolean)
    }

    // MARK: - Store (app-wide JSON round-trip)

    // MARK: - Store (per-wiki SQLite round-trip)

    @Test func connectionRoundTripsThroughStore() throws {
        // The per-wiki SQLite store round-trips connections — exercised more
        // fully in SQLiteWikiStoreTests; this test verifies the Connection
        // struct's Codable config column serialization.
        let connection = Connection(
            id: "abc123",
            providerID: "zotero",
            label: "Work Zotero",
            config: ["libraryID": "7089244"])
        let data = try JSONEncoder().encode(connection.config)
        let decoded = try JSONDecoder().decode([String: String].self, from: data)
        #expect(decoded == ["libraryID": "7089244"])
        // Verify the struct round-trips through Codable (config column fidelity).
        let connData = try JSONEncoder().encode(connection)
        let restored = try JSONDecoder().decode(Connection.self, from: connData)
        #expect(restored == connection)
    }

    // MARK: - Zotero migration + adapter

    @Test func migratesLegacyZoteroConfigToConnection() {
        let legacy = ZoteroConfig(libraryID: "7089244", zoteroDirOverride: "/Volumes/Ext/Zotero")
        let connection = ZoteroConnection.migratedConnection(from: legacy)
        #expect(connection.id == ZoteroConnection.defaultConnectionID)
        #expect(connection.providerID == "zotero")
        #expect(connection.config["libraryID"] == "7089244")
        #expect(connection.config["zoteroDirOverride"] == "/Volumes/Ext/Zotero")
    }

    @Test func isConfiguredRequiresLibraryAndKey() {
        let connection = ZoteroConnection.migratedConnection(
            from: ZoteroConfig(libraryID: "7089244"))
        #expect(!ZoteroConnection.isConfigured(connection, apiKey: nil))
        #expect(!ZoteroConnection.isConfigured(connection, apiKey: ""))
        #expect(ZoteroConnection.isConfigured(connection, apiKey: "secret"))
    }

    // MARK: - Per-connection credentials (two Zotero user IDs)

    @Test func credentialStoreIsolatesSecretsPerConnection() throws {
        let store = InMemoryConnectionCredentialStore()
        try store.setSecret("key-work", connectionID: "work", field: "apiKey")
        try store.setSecret("key-personal", connectionID: "personal", field: "apiKey")
        #expect(store.secret(connectionID: "work", field: "apiKey") == "key-work")
        #expect(store.secret(connectionID: "personal", field: "apiKey") == "key-personal")

        try store.setSecret(nil, connectionID: "work", field: "apiKey")
        #expect(store.secret(connectionID: "work", field: "apiKey") == nil)
        #expect(store.secret(connectionID: "personal", field: "apiKey") == "key-personal")
    }

    @Test func zoteroDirectoryUsesOverrideThenDefault() {
        let withOverride = ZoteroConnection.migratedConnection(
            from: ZoteroConfig(libraryID: "1", zoteroDirOverride: "/tmp/z"))
        #expect(ZoteroConnection.zoteroDirectory(for: withOverride).path == "/tmp/z")

        let noOverride = ZoteroConnection.migratedConnection(
            from: ZoteroConfig(libraryID: "1"))
        #expect(ZoteroConnection.zoteroDirectory(for: noOverride) == ZoteroLocalStorage.defaultDirectory())
    }
}
