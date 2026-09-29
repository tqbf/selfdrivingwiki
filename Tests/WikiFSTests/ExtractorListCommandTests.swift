import Foundation
import Testing
import WikiCtlCore
import WikiFSCore
import WikiFSTypes

/// `wikictl extractor list` — the runtime discovery surface for
/// acquisition packages, against an injected catalog double and credential
/// double. The contract: the listing is the same discovery walk `sync`
/// performs (so list and the command it points at can never disagree), it
/// surfaces the manifest facts an agent needs to route a fetch (name,
/// fetch template, credential presence, config sidecar), and it stays
/// silent about packages with no sync declaration.
@Suite("Extractor list command")
struct ExtractorListCommandTests {

    /// A credential double whose configured state the test controls —
    /// describe-only, exactly the surface the command is allowed to see.
    private final class CredentialDouble: CredentialDescribing, @unchecked Sendable {
        var configured: Bool
        var verificationFailed: Bool
        init(configured: Bool, verificationFailed: Bool = false) {
            self.configured = configured
            self.verificationFailed = verificationFailed
        }

        var maximumDescribeBatchSize: Int { 1 }

        func describe(_ reference: CredentialReference) -> CredentialInfo {
            CredentialInfo(
                reference: reference, isConfigured: configured,
                source: .keychain, isWritable: false,
                verificationFailed: verificationFailed)
        }

        func describe(_ references: [CredentialReference]) -> [CredentialReference: CredentialInfo] {
            var infos: [CredentialReference: CredentialInfo] = [:]
            for reference in references.prefix(maximumDescribeBatchSize) {
                infos[reference] = describe(reference)
            }
            return infos
        }
    }

    /// The command's discovery seam: a fixed catalog, no filesystem.
    private struct CatalogDouble: ExtractorPackageCatalogReading, Sendable {
        let catalog: ExtractorPackageCatalog
        func read() throws -> ExtractorPackageCatalog { catalog }
    }

    // MARK: - Catalog fixtures

    /// The reviewed zotero package's shape: same identity, requirement, and
    /// sync declaration the committed manifest declares, so the compiled
    /// credential binding resolves exactly as in production.
    private func zoteroRecord() throws -> ExtractorPackageCatalogRecord {
        let sync = try ExtractorSyncDeclaration(
            configFileName: "zotero-config.json",
            urlTemplate: "https://api.zotero.org/users/{libraryID}/items/{itemKey}/file",
            fields: [
                ExtractorSyncFieldDeclaration(name: "libraryID", required: true),
                ExtractorSyncFieldDeclaration(name: "attachments", required: true, isList: true),
            ],
            itemValidation: ExtractorSyncItemValidation(
                minimumLength: 8, maximumLength: 8,
                alphabet: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"))
        let registration = try ExtractorRegistration(
            id: ExtractorRegistrationID(validating: "attachment"),
            displayName: "Zotero Attachment",
            kinds: [],
            mimeTypes: [ExtractorMIMEType(validating: "application/zotero")],
            credentialRequirements: [
                ExtractorCredentialRequirement(
                    id: ExtractorCredentialRequirementID(validating: "zotero-api-key"),
                    kind: .secret,
                    isOptional: false,
                    label: "Zotero API Key",
                    purpose: "Read your Zotero library and download attachment files."),
            ],
            sync: sync,
            role: .fetcher)
        return try ExtractorPackageCatalogRecord(
            revision: ExtractorPackageRevisionID(
                packageID: ExtractorPackageID(validating: "org.selfdrivingwiki.zotero"),
                version: try ExtractorPackageVersion(validating: "1.1.0"),
                digest: ExtractorPackageDigest(
                    bytes: Array(repeating: 0x2a, count: 32))),
            displayName: "Zotero Attachment",
            protocolRevision: .v5,
            manifestRevision: .v4,
            launch: .runtime(command: ExtractorRuntimeName(rawValue: "uv")!, arguments: ["run", "--script"]),
            registrations: [registration],
            capabilities: [.network],
            installedAt: RFC3339Timestamp(date: Date(timeIntervalSince1970: 0)))
    }

    /// A second syncable package with NO credential requirement — the
    /// zero-host-code-changes contract: the listing knows nothing about it
    /// beyond its manifest.
    private func readiumRecord() throws -> ExtractorPackageCatalogRecord {
        let sync = try ExtractorSyncDeclaration(
            configFileName: "readium-config.json",
            urlTemplate: "https://api.readium.org/libraries/{library}/items/{itemKey}/download",
            fields: [
                ExtractorSyncFieldDeclaration(name: "library", required: true),
                ExtractorSyncFieldDeclaration(name: "items", required: true, isList: true),
            ],
            itemValidation: ExtractorSyncItemValidation(
                minimumLength: 4, maximumLength: 16,
                alphabet: "abcdefghijklmnopqrstuvwxyz0123456789"))
        let registration = try ExtractorRegistration(
            id: ExtractorRegistrationID(validating: "items"),
            displayName: "Readium Items",
            kinds: [],
            mimeTypes: [ExtractorMIMEType(validating: "application/readium")],
            credentialRequirements: [],
            sync: sync,
            role: .fetcher)
        return try ExtractorPackageCatalogRecord(
            revision: ExtractorPackageRevisionID(
                packageID: ExtractorPackageID(validating: "org.example.readium"),
                version: try ExtractorPackageVersion(validating: "0.3.0"),
                digest: ExtractorPackageDigest(
                    bytes: Array(repeating: 0x1b, count: 32))),
            displayName: "Readium Items",
            protocolRevision: .v5,
            manifestRevision: .v4,
            launch: .runtime(command: ExtractorRuntimeName(rawValue: "uv")!, arguments: ["run", "--script"]),
            registrations: [registration],
            capabilities: [.network],
            installedAt: RFC3339Timestamp(date: Date(timeIntervalSince1970: 0)))
    }

    /// A NON-syncable package (a plain converter registration, no sync
    /// declaration): installed, but not part of the acquisition surface.
    private func plainExtractorRecord() throws -> ExtractorPackageCatalogRecord {
        let registration = try ExtractorRegistration(
            id: ExtractorRegistrationID(validating: "convert"),
            displayName: "Convert",
            kinds: [ExtractorKind.pdf],
            mimeTypes: [ExtractorMIMEType(validating: "application/pdf")],
            credentialRequirements: [],
            sync: nil,
            role: .extractor)
        return try ExtractorPackageCatalogRecord(
            revision: ExtractorPackageRevisionID(
                packageID: ExtractorPackageID(validating: "org.selfdrivingwiki.pdf2md"),
                version: try ExtractorPackageVersion(validating: "1.0.0"),
                digest: ExtractorPackageDigest(
                    bytes: Array(repeating: 0x07, count: 32))),
            displayName: "pdf2md",
            protocolRevision: .v5,
            manifestRevision: .v4,
            launch: .runtime(command: ExtractorRuntimeName(rawValue: "uv")!, arguments: ["run", "--script"]),
            registrations: [registration],
            capabilities: [],
            installedAt: RFC3339Timestamp(date: Date(timeIntervalSince1970: 0)))
    }

    private func catalog(records: [ExtractorPackageCatalogRecord]) throws -> CatalogDouble {
        CatalogDouble(catalog: try ExtractorPackageCatalog(records: records))
    }

    // MARK: - Rows

    @Test func rowsCarryTheManifestFactsAnAgentNeeds() throws {
        let rows = try ExtractorListCommand.rows(
            catalog: catalog(records: [zoteroRecord(), readiumRecord()]),
            credentials: CredentialDouble(configured: true))

        #expect(rows.count == 2)
        let zotero = rows.first { $0.name == "zotero" }
        #expect(zotero?.packageID == "org.selfdrivingwiki.zotero")
        #expect(zotero?.version == "1.1.0")
        #expect(zotero?.displayName == "Zotero Attachment")
        #expect(zotero?.role == "fetcher")
        #expect(zotero?.inputMIMEs == ["application/zotero"])
        #expect(zotero?.urlTemplate == "https://api.zotero.org/users/{libraryID}/items/{itemKey}/file")
        #expect(zotero?.configFileName == "zotero-config.json")
        #expect(zotero?.configFields == ["libraryID", "attachments"])
        #expect(zotero?.credentialLabel == "Zotero API Key")
        #expect(zotero?.credentialState == "configured")

        // The credential-free package reports no requirement at all.
        let readium = rows.first { $0.name == "readium" }
        #expect(readium?.credentialLabel == nil)
        #expect(readium?.credentialState == "none")
    }

    @Test func packagesWithoutASyncDeclarationAreNotListed() throws {
        let rows = try ExtractorListCommand.rows(
            catalog: catalog(records: [zoteroRecord(), plainExtractorRecord()]),
            credentials: CredentialDouble(configured: true))
        #expect(rows.map(\.name) == ["zotero"])
    }

    @Test func credentialStatesMirrorTheSyncGate() throws {
        let notConfigured = try ExtractorListCommand.rows(
            catalog: catalog(records: [zoteroRecord()]),
            credentials: CredentialDouble(configured: false))
        #expect(notConfigured.first?.credentialState == "not configured")

        // Unreadable-here (a bare CLI Mach-O cannot read the shared
        // keychain) defers to the draining host — it is not "unset".
        let unverified = try ExtractorListCommand.rows(
            catalog: catalog(records: [zoteroRecord()]),
            credentials: CredentialDouble(configured: false, verificationFailed: true))
        #expect(unverified.first?.credentialState == "unverified")
    }

    // MARK: - Rendering

    @Test func textOutputNamesTheSyncCommandAndTheFacts() throws {
        let output = try ExtractorListCommand.run(
            catalog: catalog(records: [zoteroRecord()]),
            credentials: CredentialDouble(configured: true),
            json: false)
        #expect(output.contains("wikictl extractor sync <name>"))
        #expect(output.contains("zotero"))
        #expect(output.contains("https://api.zotero.org/users/{libraryID}/items/{itemKey}/file"))
        #expect(output.contains("Zotero API Key — configured"))
        #expect(output.contains("zotero-config.json"))
    }

    @Test func unconfiguredCredentialSaysHowToFixIt() throws {
        let output = try ExtractorListCommand.run(
            catalog: catalog(records: [zoteroRecord()]),
            credentials: CredentialDouble(configured: false),
            json: false)
        #expect(output.contains("NOT configured"))
        #expect(output.contains("extraction package settings"))
    }

    @Test func emptyCatalogSaysSoAndNamesTheRemedy() throws {
        let output = try ExtractorListCommand.run(
            catalog: catalog(records: []),
            credentials: CredentialDouble(configured: true),
            json: false)
        #expect(output.contains("No syncable acquisition packages are installed"))
        #expect(output.contains("Launch the app once"))
    }

    @Test func jsonOutputEmitsOneDecodableRowPerLine() throws {
        let output = try ExtractorListCommand.run(
            catalog: catalog(records: [zoteroRecord(), readiumRecord()]),
            credentials: CredentialDouble(configured: true),
            json: true)
        let lines = output.split(separator: "\n")
        #expect(lines.count == 2)
        let rows = try lines.map { line in
            try JSONDecoder().decode(ExtractorListCommand.Row.self, from: Data(line.utf8))
        }
        #expect(rows.map(\.name).sorted() == ["readium", "zotero"])
        #expect(rows.first { $0.name == "zotero" }?.credentialState == "configured")
    }

    // MARK: - Parser

    @Test func parserRecognizesListAndItsJsonFlag() throws {
        let plain = try ArgumentParser.parse(["extractor", "list"]) { _ in nil }
        #expect(plain.command == .extractor(.list(json: false)))

        let json = try ArgumentParser.parse(["extractor", "list", "--json"]) { _ in nil }
        #expect(json.command == .extractor(.list(json: true)))
    }

    @Test func syncStillRequiresItsPackageName() {
        #expect(throws: ArgumentParser.Failure.self) {
            _ = try ArgumentParser.parse(["extractor", "sync"]) { _ in nil }
        }
    }
}
