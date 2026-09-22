import Foundation
import Testing
import WikiCtlCore
import WikiFSCore
import WikiFSTypes

/// AC.6, CLI layer: `wikictl extractor sync <package>` against a temp store
/// with an injected catalog double and enqueue closure. Discovery, source
/// creation, dedupe, `--force`, enqueue call recording, hard-failure
/// messages (unconfigured field, empty list, missing credential), the
/// deferral note, and the second-package contract: a different declared
/// package syncs with zero host-code changes. The drain side is covered by
/// the queue-extraction provider-route tests in the app-target suite.
@Suite("Extractor sync command")
struct ExtractorSyncCommandTests {

    /// A credential double whose configured state the test controls —
    /// describe-only, exactly the surface the command is allowed to see.
    /// `verificationFailed` models the unreadable-here case (a bare CLI
    /// Mach-O cannot carry keychain-access-groups; every shared-keychain
    /// read fails errSecMissingEntitlement and describe reports it via the
    /// flag, not as "unset").
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

    private func tempStore() throws -> GRDBWikiStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-extractorsync-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try GRDBWikiStore(databaseURL: dir.appendingPathComponent("WikiFS.sqlite"))
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
            kinds: [.zotero],
            mimeTypes: [ExtractorMIMEType(validating: "application/zotero")],
            credentialRequirements: [
                ExtractorCredentialRequirement(
                    id: ExtractorCredentialRequirementID(validating: "zotero-api-key"),
                    kind: .secret,
                    isOptional: false,
                    label: "Zotero API Key",
                    purpose: "Read your Zotero library and download attachment files."),
            ],
            sync: sync)
        return try ExtractorPackageCatalogRecord(
            revision: ExtractorPackageRevisionID(
                packageID: ExtractorPackageID(validating: "org.selfdrivingwiki.zotero"),
                version: try ExtractorPackageVersion(validating: "1.0.2"),
                digest: ExtractorPackageDigest(
                    bytes: Array(repeating: 0x2a, count: 32))),
            displayName: "Zotero Attachment",
            protocolRevision: .v4,
            manifestRevision: .v3,
            launch: .runtime(command: ExtractorRuntimeName(rawValue: "uv")!, arguments: ["run", "--script"]),
            registrations: [registration],
            capabilities: [.network],
            installedAt: RFC3339Timestamp(date: Date(timeIntervalSince1970: 0)))
    }

    /// A SECOND syncable package — different template, different alphabet,
    /// NO credential requirements (so it syncs without any reviewed
    /// binding). This is the zero-host-code-changes contract: nothing in
    /// the command or engine knows this package.
    private func readiumRecord() throws -> ExtractorPackageCatalogRecord {
        let sync = try ExtractorSyncDeclaration(
            configFileName: "readium-config.json",
            urlTemplate: "https://api.readium.org/libraries/{library}/items/{itemKey}/download",
            fields: [
                ExtractorSyncFieldDeclaration(name: "library", required: true),
                ExtractorSyncFieldDeclaration(name: "items", required: true, isList: true),
            ],
            itemValidation: ExtractorSyncItemValidation(
                minimumLength: 1, maximumLength: 12,
                alphabet: "0123456789abcdef"),
            sourceMIMEType: ExtractorMIMEType(validating: "application/x-readium"))
        let registration = try ExtractorRegistration(
            id: ExtractorRegistrationID(validating: "download"),
            displayName: "Readium Download",
            kinds: [.pdf],
            mimeTypes: [ExtractorMIMEType(validating: "application/pdf")],
            sync: sync)
        return try ExtractorPackageCatalogRecord(
            revision: ExtractorPackageRevisionID(
                packageID: ExtractorPackageID(validating: "org.example.readium"),
                version: try ExtractorPackageVersion(validating: "0.1.0"),
                digest: ExtractorPackageDigest(
                    bytes: Array(repeating: 0x1d, count: 32))),
            displayName: "Readium",
            protocolRevision: .v3,
            manifestRevision: .v3,
            launch: .direct,
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

    // MARK: - Sync outcomes

    @Test func createsOneSourcePerItemAndEnqueuesInOrder() async throws {
        let store = try tempStore()
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("extractorsync-cfg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        try writeConfig(
            ["libraryID": "12345", "attachments": ["ABCD1234", "WXYZ9876"]],
            fileName: "zotero-config.json", to: container)

        final class EnqueueLog: @unchecked Sendable {
            var ids: [SourceID] = []
        }
        let log = EnqueueLog()

        let output = try await ExtractorSyncCommand.run(
            packageName: "zotero",
            force: false,
            in: store,
            containerDirectory: container,
            catalog: catalog(records: [zoteroRecord()]),
            credentials: CredentialDouble(configured: true),
            enqueue: { sourceID in log.ids.append(sourceID) })

        let sources = try store.listSources()
        #expect(sources.count == 2)
        #expect(log.ids.count == 2)
        #expect(output.contains("Zotero Attachment sync: 2 item(s)"))
        #expect(output.contains("created  ABCD1234"))
        #expect(output.contains("created  WXYZ9876"))
        for source in sources {
            let origin = try store.sourceOrigin(sourceID: source.id)
            #expect(origin?.provider == .zotero)
            #expect(source.mimeType == "application/zotero")
            #expect(
                origin?.plan == "https://api.zotero.org/users/12345/items/\(source.filename)/file")
            #expect(origin?.externalIdentity == source.filename)
        }
        // Every created source was enqueued.
        #expect(Set(log.ids) == Set(sources.map(\.id)))
    }

    @Test func rerunSkipsExistingWithoutEnqueue() async throws {
        let store = try tempStore()
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("extractorsync-cfg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        try writeConfig(
            ["libraryID": "12345", "attachments": ["ABCD1234"]],
            fileName: "zotero-config.json", to: container)

        final class EnqueueLog: @unchecked Sendable { var ids: [SourceID] = [] }
        let log = EnqueueLog()
        _ = try await ExtractorSyncCommand.run(
            packageName: "zotero", force: false, in: store, containerDirectory: container,
            catalog: catalog(records: [zoteroRecord()]),
            credentials: CredentialDouble(configured: true),
            enqueue: { log.ids.append($0) })
        #expect(log.ids.count == 1)

        let second = try await ExtractorSyncCommand.run(
            packageName: "zotero", force: false, in: store, containerDirectory: container,
            catalog: catalog(records: [zoteroRecord()]),
            credentials: CredentialDouble(configured: true),
            enqueue: { log.ids.append($0) })
        #expect(log.ids.count == 1) // no new enqueue
        #expect(second.contains("skipped  ABCD1234"))
        #expect(try store.listSources().count == 1)
    }

    @Test func forceReenqueuesExistingSources() async throws {
        let store = try tempStore()
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("extractorsync-cfg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        try writeConfig(
            ["libraryID": "12345", "attachments": ["ABCD1234"]],
            fileName: "zotero-config.json", to: container)

        final class EnqueueLog: @unchecked Sendable { var ids: [SourceID] = [] }
        let log = EnqueueLog()
        _ = try await ExtractorSyncCommand.run(
            packageName: "zotero", force: false, in: store, containerDirectory: container,
            catalog: catalog(records: [zoteroRecord()]),
            credentials: CredentialDouble(configured: true),
            enqueue: { log.ids.append($0) })
        let original = log.ids

        let output = try await ExtractorSyncCommand.run(
            packageName: "zotero", force: true, in: store, containerDirectory: container,
            catalog: catalog(records: [zoteroRecord()]),
            credentials: CredentialDouble(configured: true),
            enqueue: { log.ids.append($0) })

        #expect(output.contains("re-enqueued  ABCD1234"))
        #expect(log.ids.count == 2)
        #expect(log.ids[1] == original[0])
        #expect(try store.listSources().count == 1) // no duplicate source
    }

    // MARK: - Hard gates

    @Test func unconfiguredFieldFailsHard() async throws {
        let store = try tempStore()
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("extractorsync-cfg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        // A config without the required libraryID field.
        try writeConfig(
            ["attachments": ["ABCD1234"]],
            fileName: "zotero-config.json", to: container)

        await #expect(throws: ExtractorSyncSidecarError.requiredFieldNotConfigured(
            field: "libraryID", configFileName: "zotero-config.json")) {
            _ = try await ExtractorSyncCommand.run(
                packageName: "zotero", force: false, in: store, containerDirectory: container,
                catalog: catalog(records: [zoteroRecord()]),
                credentials: CredentialDouble(configured: true),
                enqueue: { _ in })
        }
    }

    @Test func emptyItemListFailsHard() async throws {
        let store = try tempStore()
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("extractorsync-cfg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        try writeConfig(
            ["libraryID": "12345", "attachments": []],
            fileName: "zotero-config.json", to: container)

        await #expect(throws: ExtractorSyncSidecarError.requiredListIsEmpty(
            field: "attachments", configFileName: "zotero-config.json")) {
            _ = try await ExtractorSyncCommand.run(
                packageName: "zotero", force: false, in: store, containerDirectory: container,
                catalog: catalog(records: [zoteroRecord()]),
                credentials: CredentialDouble(configured: true),
                enqueue: { _ in })
        }
    }

    @Test func missingRequiredCredentialFailsHardWithSetupGuidance() async throws {
        let store = try tempStore()
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("extractorsync-cfg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        try writeConfig(
            ["libraryID": "12345", "attachments": ["ABCD1234"]],
            fileName: "zotero-config.json", to: container)

        do {
            _ = try await ExtractorSyncCommand.run(
                packageName: "zotero", force: false, in: store, containerDirectory: container,
                catalog: catalog(records: [zoteroRecord()]),
                credentials: CredentialDouble(configured: false),
                enqueue: { _ in })
            Issue.record("expected requiredCredentialNotConfigured")
        } catch let error as ExtractorSyncCommand.Failure {
            // The gate is package-data-driven: the failure names the
            // requirement's declared label, not a host literal.
            #expect(error == .requiredCredentialNotConfigured(label: "Zotero API Key"))
            #expect(error.errorDescription?.contains("not configured") == true)
        }
        #expect(try store.listSources().isEmpty)
    }

    @Test func unreadableCredentialDefersTheCheckToTheDrainingHost() async throws {
        // verificationFailed (not "unset") must NOT fail the sync: the
        // entitled host draining the job re-checks the credential. The
        // command proceeds, creates the sources, and says it deferred.
        let store = try tempStore()
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("extractorsync-cfg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        try writeConfig(
            ["libraryID": "12345", "attachments": ["ABCD1234"]],
            fileName: "zotero-config.json", to: container)

        let output = try await ExtractorSyncCommand.run(
            packageName: "zotero", force: false, in: store, containerDirectory: container,
            catalog: catalog(records: [zoteroRecord()]),
            credentials: CredentialDouble(configured: false, verificationFailed: true),
            enqueue: { _ in })
        #expect(output.contains("could not be verified from this process"))
        #expect(try store.listSources().count == 1)
    }

    // MARK: - Discovery

    @Test func unknownPackageFailsListingDiscoveredNames() async throws {
        let store = try tempStore()
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("extractorsync-cfg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)

        do {
            _ = try await ExtractorSyncCommand.run(
                packageName: "notapackage", force: false, in: store,
                containerDirectory: container,
                catalog: catalog(records: [zoteroRecord(), readiumRecord()]),
                credentials: CredentialDouble(configured: true),
                enqueue: { _ in })
            Issue.record("expected unknownPackage")
        } catch let error as ExtractorSyncCommand.Failure {
            #expect(error == .unknownPackage("notapackage", discovered: ["readium", "zotero"]))
            let message = error.errorDescription ?? ""
            #expect(message.contains("Unknown extraction package 'notapackage'"))
            #expect(message.contains("readium"))
            #expect(message.contains("zotero"))
        }
    }

    @Test func unknownPackageWithNoSyncablePackagesSaysSo() async throws {
        let store = try tempStore()
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("extractorsync-cfg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)

        do {
            _ = try await ExtractorSyncCommand.run(
                packageName: "zotero", force: false, in: store,
                containerDirectory: container,
                catalog: catalog(records: []),
                credentials: CredentialDouble(configured: true),
                enqueue: { _ in })
            Issue.record("expected unknownPackage")
        } catch let error as ExtractorSyncCommand.Failure {
            #expect(
                error.errorDescription?.contains("No syncable packages are installed") == true)
        }
    }

    /// A package whose NEWEST revision declares sync is the discovered one:
    /// an older record without a declaration must not shadow it.
    @Test func discoveryUsesTheNewestRecordPerPackage() async throws {
        let store = try tempStore()
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("extractorsync-cfg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        try writeConfig(
            ["libraryID": "12345", "attachments": ["ABCD1234"]],
            fileName: "zotero-config.json", to: container)

        var older = try zoteroRecord()
        // Same lineage, older version, no sync declaration.
        older = try ExtractorPackageCatalogRecord(
            revision: ExtractorPackageRevisionID(
                packageID: older.revision.packageID,
                version: try ExtractorPackageVersion(validating: "1.0.0"),
                digest: ExtractorPackageDigest(bytes: Array(repeating: 0x0f, count: 32))),
            displayName: older.displayName,
            protocolRevision: older.protocolRevision,
            manifestRevision: .v2,
            launch: older.launch,
            registrations: try older.registrations.map {
                try ExtractorRegistration(
                    id: $0.id, displayName: $0.displayName, kinds: $0.kinds,
                    mimeTypes: $0.mimeTypes, filenameExtensions: $0.filenameExtensions,
                    credentialRequirements: $0.credentialRequirements)
            },
            capabilities: older.capabilities,
            installedAt: older.installedAt)

        final class EnqueueLog: @unchecked Sendable { var ids: [SourceID] = [] }
        let log = EnqueueLog()
        let output = try await ExtractorSyncCommand.run(
            packageName: "zotero", force: false, in: store, containerDirectory: container,
            catalog: catalog(records: [older, zoteroRecord()]),
            credentials: CredentialDouble(configured: true),
            enqueue: { log.ids.append($0) })

        #expect(output.contains("created  ABCD1234"))
        #expect(log.ids.count == 1)
    }

    /// A registration with a required credential requirement but NO
    /// compiled reviewed binding hard-fails the gate — the reviewed-only
    /// surface, typed.
    @Test func unboundRequiredCredentialFailsHard() async throws {
        var record = try readiumRecord()
        record = try ExtractorPackageCatalogRecord(
            revision: record.revision,
            displayName: record.displayName,
            protocolRevision: record.protocolRevision,
            manifestRevision: .v3,
            launch: record.launch,
            registrations: try record.registrations.map {
                try ExtractorRegistration(
                    id: $0.id, displayName: $0.displayName, kinds: $0.kinds,
                    mimeTypes: $0.mimeTypes, filenameExtensions: $0.filenameExtensions,
                    credentialRequirements: [
                        ExtractorCredentialRequirement(
                            id: ExtractorCredentialRequirementID(validating: "vault-token"),
                            kind: .secret, isOptional: false,
                            label: "Vault Token", purpose: "Access the vault."),
                    ],
                    sync: $0.sync)
            },
            capabilities: record.capabilities,
            installedAt: record.installedAt)

        let store = try tempStore()
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("extractorsync-cfg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)

        await #expect(throws: ExtractorSyncCommand.Failure.requiredCredentialUnavailable(
            packageName: "readium", requirementID: "vault-token")) {
            _ = try await ExtractorSyncCommand.run(
                packageName: "readium", force: false, in: store,
                containerDirectory: container,
                catalog: catalog(records: [record]),
                credentials: CredentialDouble(configured: true),
                enqueue: { _ in })
        }
    }

    // MARK: - The second-package contract (AC.3)

    /// A second syncable package — different template, different alphabet,
    /// no credential requirements — syncs end to end with ZERO host-code
    /// changes: discovery → sidecar load → source creation + enqueue.
    @Test func secondDeclaredPackageSyncsWithZeroHostChanges() async throws {
        let store = try tempStore()
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("extractorsync-cfg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        try writeConfig(
            ["library": "lib-9", "items": ["deadbeef", "0123456789ab"]],
            fileName: "readium-config.json", to: container)

        final class EnqueueLog: @unchecked Sendable { var ids: [SourceID] = [] }
        let log = EnqueueLog()

        let output = try await ExtractorSyncCommand.run(
            packageName: "readium",
            force: false,
            in: store,
            containerDirectory: container,
            catalog: catalog(records: [zoteroRecord(), readiumRecord()]),
            credentials: CredentialDouble(configured: false),
            enqueue: { sourceID in log.ids.append(sourceID) })

        #expect(output.contains("Readium sync: 2 item(s)"))
        #expect(output.contains("created  deadbeef"))
        #expect(output.contains("created  0123456789ab"))
        #expect(log.ids.count == 2)

        let sources = try store.listSources()
        #expect(sources.count == 2)
        for source in sources {
            #expect(source.mimeType == "application/x-readium")
            let origin = try store.sourceOrigin(sourceID: source.id)
            #expect(
                origin?.plan == "https://api.readium.org/libraries/lib-9/items/\(source.filename)/download")
            // The agent name is the package ID's last label; unknown to the
            // origin-provider table, it degrades to the generic origin.
            #expect(origin?.provider == nil)
        }
    }

    // MARK: - Parse grammar (shape only; names are execution-time data)

    @Test func syncGrammarParsesPackageNameAndForce() throws {
        let noEnv: (String) -> String? = { _ in nil }
        let invocation = try ArgumentParser.parse(
            ["--wiki", "test", "extractor", "sync", "zotero", "--force"]) { key in noEnv(key) }
        guard case .extractor(.sync(let packageName, let force)) = invocation.command else {
            Issue.record("expected an extractor sync command")
            return
        }
        #expect(packageName == "zotero")
        #expect(force)
    }

    @Test func syncWithoutPackageFailsWithGuidance() throws {
        // `extractor sync` with no package names the static hint — the
        // supported names themselves are catalog data, resolved at
        // execution, so the parse layer cannot enumerate them.
        let noEnv: (String) -> String? = { _ in nil }
        do {
            _ = try ArgumentParser.parse(
                ["--wiki", "test", "extractor", "sync"]) { key in noEnv(key) }
            Issue.record("expected the missing-package usage error")
        } catch let failure as ArgumentParser.Failure {
            #expect(failure.description.contains("name the acquisition package to sync") == true)
        }
    }

    @Test func anyNonFlagNameParses() throws {
        // The parse layer defers name validation: an unknown package name
        // parses fine and fails later, at execution, against the catalog.
        let noEnv: (String) -> String? = { _ in nil }
        let invocation = try ArgumentParser.parse(
            ["--wiki", "test", "extractor", "sync", "notapackage"]) { key in noEnv(key) }
        guard case .extractor(.sync(let packageName, let force)) = invocation.command else {
            Issue.record("expected an extractor sync command")
            return
        }
        #expect(packageName == "notapackage")
        #expect(force == false)
    }
}
