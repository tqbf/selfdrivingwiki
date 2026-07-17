import Foundation

/// # Connections — the configured, credentialed instance layer
///
/// A **Connection** is a configured, reusable instance of a provider *kind*
/// (Zotero, later Tavily/Slack/…). It is the missing middle of the four-layer
/// origin model from the wiki design page *Connections Architecture for Source
/// Ingest* (`01KXNQS1`):
///
/// ```
/// Kind        → ProviderManifest        (this file)
/// Connection  → Connection + config     (this file)   ← was missing
/// Item        → --list / native picker  (workspace UI)
/// Rendition   → MaterializedSource       (SourceMaterializer.swift, already built)
/// ```
///
/// The invariant a connection satisfies (design page): *a connection is mutable
/// configuration; provenance is immutable history.* This is why connection
/// identity cannot live purely in provenance columns — a Zotero API key exists
/// with zero sources ingested.
///
/// **Spike note.** This first pass proves the substrate with Zotero only
/// (issue #483 → native `SchemaForm`, no WKWebView). The provider's config form
/// is rendered from the manifest's schema (decoded from JSON — the drop-in
/// contract), but Zotero's *data path* stays native (`ZoteroClient` + native
/// picker). Script-backed providers, a per-wiki SQLite table, per-connection
/// keychain scoping, and the provenance connection-snapshot are deferred — see
/// `plans/connections-substrate-zotero-as-connection.md`.

// MARK: - Schema (the config form contract)

/// One field in a provider's config form. A deliberately small, JSON-Schema-ish
/// value — an ordered `fields` array (not a `properties` object) so field order
/// is preserved without an `x-order` sidecar. Decodable so the deferred
/// script-provider path can load the identical shape from a `manifest.json`.
public struct SchemaField: Codable, Sendable, Equatable, Identifiable {
    /// The value type. `SchemaForm` picks a native control from this + `format`.
    public enum FieldType: String, Codable, Sendable {
        case string, number, integer, boolean
    }

    /// A rendering/semantic hint layered on `type` (JSON Schema's `format`).
    public enum FieldFormat: String, Codable, Sendable {
        case password   // → SecureField, and (with `secret`) routed to Keychain
        case path       // → TextField + "Choose…" directory picker
        case uri
    }

    /// The config key this field reads/writes (e.g. `"libraryID"`).
    public let name: String
    /// The human label shown in the form.
    public let title: String
    public let type: FieldType
    public let format: FieldFormat?
    /// When present, renders a `Picker` instead of a free-text field.
    public let enumValues: [String]?
    /// Whether the value is a secret — stored in the Keychain, never in the
    /// connection's plaintext config JSON.
    public let secret: Bool
    /// Optional helper text under the field.
    public let help: String?
    /// Optional placeholder for empty text fields.
    public let placeholder: String?

    public var id: String { name }

    public init(
        name: String,
        title: String,
        type: FieldType = .string,
        format: FieldFormat? = nil,
        enumValues: [String]? = nil,
        secret: Bool = false,
        help: String? = nil,
        placeholder: String? = nil
    ) {
        self.name = name
        self.title = title
        self.type = type
        self.format = format
        self.enumValues = enumValues
        self.secret = secret
        self.help = help
        self.placeholder = placeholder
    }

    private enum CodingKeys: String, CodingKey {
        case name, title, type, format
        case enumValues = "enum"
        case secret, help, placeholder
    }

    /// Defaulting decoder — a manifest only has to declare `name`/`title`; a
    /// plain text field omits `type`/`format`/`secret` entirely (JSON Schema
    /// treats these as optional). Without this, every field would need `"secret":
    /// false` etc. spelled out.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        title = try c.decode(String.self, forKey: .title)
        type = try c.decodeIfPresent(FieldType.self, forKey: .type) ?? .string
        format = try c.decodeIfPresent(FieldFormat.self, forKey: .format)
        enumValues = try c.decodeIfPresent([String].self, forKey: .enumValues)
        secret = try c.decodeIfPresent(Bool.self, forKey: .secret) ?? false
        help = try c.decodeIfPresent(String.self, forKey: .help)
        placeholder = try c.decodeIfPresent(String.self, forKey: .placeholder)
    }
}

/// A provider's config schema: the ordered fields its connection form renders.
public struct ProviderConfigSchema: Codable, Sendable, Equatable {
    public let fields: [SchemaField]

    public init(fields: [SchemaField]) { self.fields = fields }

    /// The subset of field names that are secrets (→ Keychain, not config JSON).
    public var secretFieldNames: Set<String> {
        Set(fields.filter(\.secret).map(\.name))
    }
}

// MARK: - Provider manifest (the "Kind" layer)

/// Declared capabilities a provider supports. Only `browse` matters this pass
/// (Zotero has a search picker); it's the seam the deferred `--list` script
/// browse step reuses.
public struct ProviderCapabilities: Codable, Sendable, Equatable {
    public var browse: Bool

    public init(browse: Bool = false) { self.browse = browse }
}

/// How a provider acquires source bytes. Zotero is `.native` (in-process
/// `ZoteroClient`); `.script` is the deferred drop-in path (a `manifest.json` +
/// executable in `scripts/`) — declared now so the enum is the seam, not a
/// future breaking change.
public enum ProviderBacking: Codable, Sendable, Equatable {
    case native
    case script(path: String)
}

/// A provider *kind*: its identity, its config-form schema, and how it fetches.
/// Decodable from JSON so a built-in (Zotero, embedded JSON below) and a future
/// dropped-in `manifest.json` decode through the exact same path.
public struct ProviderManifest: Codable, Sendable, Equatable, Identifiable {
    /// Stable identity, e.g. `"zotero"` — the discriminator (no `kind` enum).
    public let id: String
    public let displayName: String
    public let description: String
    /// SF Symbol name for sidebar/tab surfaces.
    public let icon: String
    public let capabilities: ProviderCapabilities
    public let config: ProviderConfigSchema
    public let backing: ProviderBacking

    public init(
        id: String,
        displayName: String,
        description: String,
        icon: String,
        capabilities: ProviderCapabilities = ProviderCapabilities(),
        config: ProviderConfigSchema,
        backing: ProviderBacking = .native
    ) {
        self.id = id
        self.displayName = displayName
        self.description = description
        self.icon = icon
        self.capabilities = capabilities
        self.config = config
        self.backing = backing
    }
}

// MARK: - Provider registry

/// The catalog of known provider kinds. This pass ships one built-in — Zotero —
/// decoded from an embedded JSON manifest to prove the data-driven path (the
/// deferred script path appends discovered `scripts/*/manifest.json` here).
public enum ProviderRegistry {
    /// All known provider manifests. Decoded once from embedded JSON — the same
    /// shape a dropped-in `manifest.json` would use.
    public static let builtIn: [ProviderManifest] = {
        [zoteroManifestJSON].compactMap { json in
            guard let data = json.data(using: .utf8) else { return nil }
            do {
                return try JSONDecoder().decode(ProviderManifest.self, from: data)
            } catch {
                DebugLog.config("ProviderRegistry: failed to decode a manifest: \(error)")
                return nil
            }
        }
    }()

    public static func manifest(for providerID: String) -> ProviderManifest? {
        builtIn.first { $0.id == providerID }
    }

    /// Provider kinds a user can add a new connection for. All built-ins are
    /// plural-natural: multiple Zotero connections (one per library / user ID,
    /// each with its own credential).
    public static var addable: [ProviderManifest] { builtIn }

    /// Zotero's manifest as JSON — the same shape a dropped-in provider would
    /// ship as `manifest.json`. Embedded (not a bundle resource) so the spike
    /// needs no `build.sh` change; a real `scripts/` discovery step supersedes
    /// this. The API key is `secret: true` → Keychain, never the config JSON.
    private static let zoteroManifestJSON = """
    {
      "id": "zotero",
      "displayName": "Zotero",
      "description": "Browse your Zotero library and ingest PDF or Markdown attachments.",
      "icon": "books.vertical",
      "capabilities": { "browse": true },
      "backing": { "native": {} },
      "config": {
        "fields": [
          {
            "name": "apiKey",
            "title": "API Key",
            "type": "string",
            "format": "password",
            "secret": true,
            "help": "A Zotero API key with library read access (zotero.org/settings/keys)."
          },
          {
            "name": "libraryID",
            "title": "Library ID",
            "type": "string",
            "help": "Your numeric Zotero user library ID."
          },
          {
            "name": "zoteroDirOverride",
            "title": "Zotero Data Directory",
            "type": "string",
            "format": "path",
            "help": "Optional. Defaults to ~/Zotero."
          }
        ]
      }
    }
    """
}

// MARK: - Connection (the configured instance)

/// A configured instance of a provider kind. Non-secret values live in `config`
/// (persisted per-wiki in the SQLite `connections` table); secrets live in the
/// Keychain, keyed per `(connectionID, field)`.
public struct Connection: Codable, Sendable, Equatable, Identifiable {
    /// UUID at rest. New connections mint a fresh UUID via the store.
    public let id: String
    /// → `ProviderManifest.id`.
    public let providerID: String
    /// User-facing label ("Work Zotero"). Defaults to the provider display name.
    public var label: String
    /// Non-secret config values, keyed by `SchemaField.name`.
    public var config: [String: String]
    public let createdAt: Date

    public init(
        id: String,
        providerID: String,
        label: String,
        config: [String: String] = [:],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.providerID = providerID
        self.label = label
        self.config = config
        self.createdAt = createdAt
    }
}
