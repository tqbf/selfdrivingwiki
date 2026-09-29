import Foundation
import WikiFSCore
import WikiFSTypes

/// `wikictl extractor list [--json]` — enumerate the machine's syncable
/// acquisition packages straight from the catalog `sync` resolves against
/// (durable records ∪ this process's reviewed overlay).
///
/// This is the DISCOVERY half of the acquisition API. Which packages exist,
/// what they can fetch, and which credential they need are manifest data —
/// resolved at runtime, never a compiled set — so an agent (or a human)
/// cannot be told in advance; this command is where they find out. The
/// listing answers, per syncable surface: the short name `extractor sync`
/// accepts, the URL template the package fetches, the credential it
/// requires and whether that credential is configured, and the config
/// sidecar file that names the items to sync.
///
/// The command is read-only and wiki-independent: it opens no store and
/// mutates nothing. Credential checks are describe-only presence checks,
/// exactly like `sync`'s gate — the value is never read here.
public enum ExtractorListCommand {

    /// One listed surface: one sync-bearing registration of one catalog
    /// record. Codable so `--json` emits one object per line.
    public struct Row: Codable, Equatable, Sendable {
        /// The short name `extractor sync <name>` accepts
        /// (`org.selfdrivingwiki.zotero` → `zotero`).
        public let name: String
        /// Full package id from the manifest.
        public let packageID: String
        /// Installed package version.
        public let version: String
        /// The registration's display name (e.g. "Zotero Attachment").
        public let displayName: String
        /// Package role: `extractor` (converts content) or `fetcher`
        /// (acquires one remote source).
        public let role: String
        /// The registration's claimed input MIME types (a fetcher's inputs).
        public let inputMIMEs: [String]
        /// The URL template the package fetches, from its sync declaration.
        public let urlTemplate: String
        /// The sidecar file (App Group container) that names the items to
        /// sync, from the sync declaration.
        public let configFileName: String
        /// The sidecar's declared field names.
        public let configFields: [String]
        /// Label of the required credential, if the registration declares
        /// one; `nil` when the package syncs without a credential.
        public let credentialLabel: String?
        /// `configured` / `not configured` / `unverified` / `none` /
        /// `unbound`. `unverified` means this process cannot read the
        /// keychain item (no shared-keychain entitlement): the draining
        /// host checks it.
        public let credentialState: String

        public init(
            name: String,
            packageID: String,
            version: String,
            displayName: String,
            role: String,
            inputMIMEs: [String],
            urlTemplate: String,
            configFileName: String,
            configFields: [String],
            credentialLabel: String?,
            credentialState: String
        ) {
            self.name = name
            self.packageID = packageID
            self.version = version
            self.displayName = displayName
            self.role = role
            self.inputMIMEs = inputMIMEs
            self.urlTemplate = urlTemplate
            self.configFileName = configFileName
            self.configFields = configFields
            self.credentialLabel = credentialLabel
            self.credentialState = credentialState
        }
    }

    /// Resolves the listing from a catalog reader. Same discovery walk as
    /// `sync` — one entry per sync-bearing registration of the newest
    /// record per package lineage — so the list and the command it points
    /// at can never disagree.
    public static func rows(
        catalog: any ExtractorPackageCatalogReading,
        credentials: any CredentialDescribing = KeychainCredentialService()
    ) throws -> [Row] {
        let syncable = ExtractorSyncCommand.discoverSyncablePackages(in: try catalog.read())
        return syncable.map { package in
            let required = package.registration.credentialRequirements
                .first { $0.isOptional == false }
            return Row(
                name: package.shortName,
                packageID: package.record.revision.packageID.rawValue,
                version: package.record.revision.version.rawValue,
                displayName: package.record.displayName,
                role: package.registration.role.rawValue,
                inputMIMEs: package.registration.mimeTypes.map(\.rawValue).sorted(),
                urlTemplate: package.sync.urlTemplate,
                configFileName: package.sync.configFileName,
                configFields: package.sync.fields.map(\.name),
                credentialLabel: required?.label,
                credentialState: credentialState(for: package, required: required, credentials: credentials))
        }
    }

    /// Renders the listing. `json` selects one JSON object per line (the
    /// family convention); otherwise aligned text an agent can read and
    /// act on without a second lookup.
    public static func run(
        catalog: any ExtractorPackageCatalogReading,
        credentials: any CredentialDescribing = KeychainCredentialService(),
        json: Bool
    ) throws -> String {
        let rows = try rows(catalog: catalog, credentials: credentials)
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            var jsonLines: [String] = []
            for row in rows {
                let data = try encoder.encode(row)
                jsonLines.append(String(data: data, encoding: .utf8) ?? "{}")
            }
            return jsonLines.joined(separator: "\n")
        }
        guard rows.isEmpty == false else {
            return """
                No syncable acquisition packages are installed. Launch the app once \
                so reviewed packages publish to the machine catalog, then retry.
                """
        }
        var lines: [String] = [
            "Syncable acquisition packages. Import with: wikictl extractor sync <name>",
        ]
        for row in rows {
            lines.append("\(row.name)  \(row.packageID) \(row.version) \(row.role)")
            lines.append("  display:     \(row.displayName)")
            lines.append("  input:       \(row.inputMIMEs.joined(separator: " "))")
            lines.append("  fetches:     \(row.urlTemplate)")
            let credential = row.credentialLabel.map { "\($0) — \(credentialText(row.credentialState))" }
                ?? "none"
            lines.append("  credential:  \(credential)")
            lines.append("  config:      \(row.configFileName) — fields: \(row.configFields.joined(separator: ", "))")
        }
        return lines.joined(separator: "\n")
    }

    /// The describe-only credential presence state, mirroring `sync`'s
    /// gate: absent is a hard failure there, unbound is a build mismatch,
    /// and unreadable-here defers to the draining host.
    private static func credentialState(
        for package: ExtractorSyncCommand.DiscoveredSyncPackage,
        required: ExtractorCredentialRequirement?,
        credentials: any CredentialDescribing
    ) -> String {
        guard let required else { return "none" }
        guard let binding = ReviewedExtractorCredentialBindings.binding(
            packageID: package.record.revision.packageID.rawValue,
            requirementID: required.id.rawValue) else {
            return "unbound"
        }
        let info = credentials.describe(binding.reference)
        if info.isConfigured { return "configured" }
        if info.verificationFailed { return "unverified" }
        return "not configured"
    }

    private static func credentialText(_ state: String) -> String {
        switch state {
        case "configured":
            return "configured"
        case "not configured":
            return "NOT configured — set it in the app's extraction package settings and sync again"
        case "unverified":
            return "cannot be verified from this process; the host that drains the job will check it"
        default:
            return "no reviewed binding in this build"
        }
    }
}
