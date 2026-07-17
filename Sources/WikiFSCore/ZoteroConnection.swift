import Foundation

/// Bridges a generic `Connection` to Zotero's native client/storage. Zotero is a
/// `.native` provider (issue #483 / spike decision): only its *config form* is
/// schema-driven; its data path stays the in-process `ZoteroClient` + local
/// storage read, preserving the keystroke-latency search picker
/// (`plans/zotero-integration.md`).
///
/// **Spike note.** The API key reuses the existing app-wide Keychain item
/// (`KeychainZoteroCredentialStore`) so this new path and the legacy "Add from
/// Zotero" button share one secret. Per-connection credential scoping (keyed by
/// connection ULID) is a deferred follow-up.
public enum ZoteroConnection {
    /// The provider id this adapter serves — matches the manifest.
    public static let providerID = "zotero"

    /// A stable, well-known id for the single migrated Zotero connection so the
    /// legacy `zotero-config.json` maps to exactly one row.
    public static let defaultConnectionID = "zotero-default"

    // Config keys — must match the manifest's `SchemaField.name`s.
    public static let libraryIDKey = "libraryID"
    public static let zoteroDirKey = "zoteroDirOverride"
    public static let apiKeyField = "apiKey"

    /// The directory to resolve `storage/<key>/<filename>` under: the config
    /// override when set, else the default `~/Zotero`.
    public static func zoteroDirectory(for connection: Connection) -> URL {
        if let override = connection.config[zoteroDirKey],
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return ZoteroLocalStorage.defaultDirectory()
    }

    /// Whether this connection has the minimum config to talk to Zotero: a
    /// non-empty library id *and* a stored API key.
    public static func isConfigured(_ connection: Connection, apiKey: String?) -> Bool {
        guard let libraryID = connection.config[libraryIDKey],
              !libraryID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard let apiKey, !apiKey.isEmpty else { return false }
        return true
    }

    /// Build a `ZoteroClient` from the connection + API key, or `nil` if the
    /// connection isn't fully configured.
    public static func client(
        for connection: Connection,
        apiKey: String?,
        fetcher: any ZoteroClient.RequestFetcher = URLSessionZoteroFetcher()
    ) -> ZoteroClient? {
        guard let libraryID = connection.config[libraryIDKey],
              !libraryID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let apiKey, !apiKey.isEmpty else { return nil }
        return ZoteroClient(
            config: ZoteroClient.Config(libraryID: libraryID, apiKey: apiKey),
            fetcher: fetcher)
    }

    /// Build the migrated Zotero connection from the legacy `ZoteroConfig`
    /// (library id + dir override). The API key is untouched — it already lives
    /// in the shared Keychain item both paths read.
    public static func migratedConnection(from config: ZoteroConfig) -> Connection {
        var values: [String: String] = [:]
        if let libraryID = config.libraryID, !libraryID.isEmpty {
            values[libraryIDKey] = libraryID
        }
        if let dir = config.zoteroDirOverride, !dir.isEmpty {
            values[zoteroDirKey] = dir
        }
        return Connection(
            id: defaultConnectionID,
            providerID: providerID,
            label: "Zotero",
            config: values)
    }
}
