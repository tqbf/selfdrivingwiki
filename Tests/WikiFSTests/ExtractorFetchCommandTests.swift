import Foundation
import Testing
import WikiCtlCore
import WikiFSCore
import WikiFSTypes

/// `wikictl extractor fetch <package> --item <key>` — the ad-hoc acquisition
/// verb, against a temp store with an injected catalog double and credential
/// double. The contract: fetch runs the SAME resolution and item engine as
/// `sync` (one item from --item, never the sidecar's watch list), creates
/// the byteless source with full fetch provenance (provider, fetch-URL plan,
/// external identity), validates the ad-hoc key by the sidecar's rules, and
/// takes its template fields (libraryID) from the sidecar without ever
/// modifying it.
@Suite("Extractor fetch command")
struct ExtractorFetchCommandTests {

    /// A credential double whose configured state the test controls —
    /// describe-only, exactly the surface the command is allowed to see.
    private final class CredentialDouble: CredentialDescribing, @unchecked Sendable {
        var configured: Bool
        init(configured: Bool) { self.configured = configured }

        var maximumDescribeBatchSize: Int { 1 }

        func describe(_ reference: CredentialReference) -> CredentialInfo {
            CredentialInfo(
                reference: reference, isConfigured: configured,
                source: .keychain, isWritable: false,
                verificationFailed: false)
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

    private func tempStore() throws -> GRDBWikiStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-extractorfetch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try GRDBWikiStore(databaseURL: dir.appendingPathComponent("WikiFS.sqlite"))
    }

    // MARK: - Catalog fixture (same shape as the sync command tests)

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

    private func catalog(records: [ExtractorPackageCatalogRecord]) throws -> CatalogDouble {
        CatalogDouble(catalog: try ExtractorPackageCatalog(records: records))
    }

    private func writeConfig(
        _ object: [String: Any], fileName: String, to directory: URL
    ) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try data.write(
            to: directory.appendingPathComponent(fileName, isDirectory: false),
            options: .atomic)
    }

    private func tempContainer() throws -> URL {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("extractorfetch-cfg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        return container
    }

    // MARK: - Fetch outcomes

    @Test func fetchCreatesOneSourceWithFetchProvenance() async throws {
        let store = try tempStore()
        let container = try tempContainer()
        // A DIFFERENT item sits on the watch list — fetch must ignore it.
        try writeConfig(
            ["libraryID": "7089244", "attachments": ["PD7VA2H8"]],
            fileName: "zotero-config.json", to: container)

        final class EnqueueLog: @unchecked Sendable {
            var ids: [SourceID] = []
        }
        let log = EnqueueLog()

        let output = try await ExtractorFetchCommand.run(
            packageName: "zotero",
            itemKey: "W23YU548",
            force: false,
            in: store,
            containerDirectory: container,
            catalog: catalog(records: [zoteroRecord()]),
            credentials: CredentialDouble(configured: true),
            enqueueJob: { sourceID in
                log.ids.append(sourceID)
                return nil
            })

        let sources = try store.listSources()
        #expect(sources.count == 1)
        #expect(log.ids.count == 1)
        #expect(output.contains("Zotero Attachment fetch: 1 item(s)"))
        #expect(output.contains("created  W23YU548"))
        let source = try #require(sources.first)
        #expect(source.filename == "W23YU548")
        #expect(source.mimeType == "application/zotero")
        let origin = try store.sourceOrigin(sourceID: source.id)
        #expect(origin?.provider == .zotero)
        #expect(
            origin?.plan == "https://api.zotero.org/users/7089244/items/W23YU548/file")
        #expect(origin?.externalIdentity == "W23YU548")
    }

    @Test func refetchWithoutForceSkipsWithoutEnqueue() async throws {
        let store = try tempStore()
        let container = try tempContainer()
        try writeConfig(
            ["libraryID": "7089244", "attachments": ["W23YU548"]],
            fileName: "zotero-config.json", to: container)

        final class EnqueueLog: @unchecked Sendable {
            var ids: [SourceID] = []
        }
        let log = EnqueueLog()

        _ = try await ExtractorFetchCommand.run(
            packageName: "zotero", itemKey: "W23YU548", force: false,
            in: store, containerDirectory: container,
            catalog: catalog(records: [zoteroRecord()]),
            credentials: CredentialDouble(configured: true),
            enqueueJob: { sourceID in log.ids.append(sourceID); return nil })
        let firstCount = log.ids.count

        let output = try await ExtractorFetchCommand.run(
            packageName: "zotero", itemKey: "W23YU548", force: false,
            in: store, containerDirectory: container,
            catalog: catalog(records: [zoteroRecord()]),
            credentials: CredentialDouble(configured: true),
            enqueueJob: { sourceID in log.ids.append(sourceID); return nil })

        #expect(firstCount == 1)
        #expect(log.ids.count == 1)
        #expect(output.contains("skipped  W23YU548"))
        #expect(try store.listSources().count == 1)
    }

    @Test func forceReenqueuesTheExistingSource() async throws {
        let store = try tempStore()
        let container = try tempContainer()
        try writeConfig(
            ["libraryID": "7089244"],
            fileName: "zotero-config.json", to: container)

        final class EnqueueLog: @unchecked Sendable {
            var ids: [SourceID] = []
        }
        let log = EnqueueLog()

        _ = try await ExtractorFetchCommand.run(
            packageName: "zotero", itemKey: "W23YU548", force: false,
            in: store, containerDirectory: container,
            catalog: catalog(records: [zoteroRecord()]),
            credentials: CredentialDouble(configured: true),
            enqueueJob: { sourceID in log.ids.append(sourceID); return nil })
        let output = try await ExtractorFetchCommand.run(
            packageName: "zotero", itemKey: "W23YU548", force: true,
            in: store, containerDirectory: container,
            catalog: catalog(records: [zoteroRecord()]),
            credentials: CredentialDouble(configured: true),
            enqueueJob: { sourceID in log.ids.append(sourceID); return nil })

        #expect(log.ids.count == 2)
        #expect(output.contains("re-enqueued  W23YU548"))
        #expect(try store.listSources().count == 1)
    }

    // MARK: - Validation and config gates

    @Test func invalidItemKeyFailsWithTheDeclaredReason() async throws {
        let store = try tempStore()
        let container = try tempContainer()
        try writeConfig(
            ["libraryID": "7089244"], fileName: "zotero-config.json", to: container)

        do {
            _ = try await ExtractorFetchCommand.run(
                packageName: "zotero", itemKey: "lowercas", force: false,
                in: store, containerDirectory: container,
                catalog: catalog(records: [zoteroRecord()]),
                credentials: CredentialDouble(configured: true),
                enqueueJob: { _ in nil })
            Issue.record("expected invalidItem")
        } catch let error as ExtractorFetchCommand.Failure {
            #expect(
                error.errorDescription?.contains("lowercas") == true)
        }
        #expect(try store.listSources().isEmpty)
    }

    @Test func missingTemplateFieldFailsLikeSync() async throws {
        let store = try tempStore()
        let container = try tempContainer()
        // No sidecar at all — the template's libraryID is unconfigured.

        do {
            _ = try await ExtractorFetchCommand.run(
                packageName: "zotero", itemKey: "W23YU548", force: false,
                in: store, containerDirectory: container,
                catalog: catalog(records: [zoteroRecord()]),
                credentials: CredentialDouble(configured: true),
                enqueueJob: { _ in nil })
            Issue.record("expected requiredFieldNotConfigured")
        } catch let error as ExtractorSyncSidecarError {
            #expect(
                error.errorDescription?.contains("libraryID") == true)
        }
        #expect(try store.listSources().isEmpty)
    }

    @Test func fetchWorksWithAnEmptyWatchList() async throws {
        // The ad-hoc verb must not require the sidecar's item list — only
        // the template fields. An empty (but present) list is fine.
        let store = try tempStore()
        let container = try tempContainer()
        try writeConfig(
            ["libraryID": "7089244", "attachments": []],
            fileName: "zotero-config.json", to: container)

        let output = try await ExtractorFetchCommand.run(
            packageName: "zotero", itemKey: "W23YU548", force: false,
            in: store, containerDirectory: container,
            catalog: catalog(records: [zoteroRecord()]),
            credentials: CredentialDouble(configured: true),
            enqueueJob: { _ in nil })

        #expect(output.contains("created  W23YU548"))
        #expect(try store.listSources().count == 1)
    }

    // MARK: - Parser

    @Test func parserRecognizesFetchAndItsFlags() throws {
        // `fetch` needs a wiki (it writes a source), so unlike `list` it is
        // NOT intercepted before the --wiki requirement.
        let plain = try ArgumentParser.parse(["--wiki", "test", "extractor", "fetch", "zotero", "--item", "W23YU548"]) { _ in nil }
        #expect(
            plain.command == .extractor(.fetch(packageName: "zotero", itemKey: "W23YU548", force: false)))

        let forced = try ArgumentParser.parse(["--wiki", "test", "extractor", "fetch", "zotero", "--item", "W23YU548", "--force"]) { _ in nil }
        #expect(
            forced.command == .extractor(.fetch(packageName: "zotero", itemKey: "W23YU548", force: true)))
    }

    @Test func fetchRequiresItsItemFlag() {
        #expect(throws: ArgumentParser.Failure.self) {
            _ = try ArgumentParser.parse(["--wiki", "test", "extractor", "fetch", "zotero"]) { _ in nil }
        }
    }
}
