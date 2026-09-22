import Foundation
import Testing
import WikiCtlCore
import WikiFSCore

/// AC.6, CLI layer: `wikictl extractor sync zotero` against a temp store with an
/// injected enqueue closure. Source creation, dedupe, `--force`, enqueue
/// call recording, and hard-failure messages (unconfigured library, no
/// attachments, missing API key). The drain side is covered by the
/// queue-extraction provider-route tests in the app-target suite.
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

    private func tempStore() throws -> GRDBWikiStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-zotero-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try GRDBWikiStore(databaseURL: dir.appendingPathComponent("WikiFS.sqlite"))
    }

    private func writeConfig(
        _ directory: URL,
        libraryID: String?,
        attachments: [String]
    ) throws {
        let config = ZoteroConfig(libraryID: libraryID, attachments: attachments)
        try config.save(to: directory)
    }

    @Test func createsOneSourcePerAttachmentAndEnqueuesInOrder() async throws {
        let store = try tempStore()
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("zotero-cfg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        try writeConfig(container, libraryID: "12345", attachments: ["ABCD1234", "WXYZ9876"])

        final class EnqueueLog: @unchecked Sendable {
            var ids: [SourceID] = []
        }
        let log = EnqueueLog()

        let output = try await ExtractorSyncCommand.run(
            package: .zotero,
            force: false,
            in: store,
            containerDirectory: container,
            credentials: CredentialDouble(configured: true),
            enqueue: { sourceID in log.ids.append(sourceID) })

        let sources = try store.listSources()
        #expect(sources.count == 2)
        #expect(log.ids.count == 2)
        #expect(output.contains("created  ABCD1234"))
        #expect(output.contains("created  WXYZ9876"))
        for source in sources {
            let origin = try store.sourceOrigin(sourceID: source.id)
            #expect(origin?.provider == .zotero)
            #expect(source.mimeType == ContentTypeRegistry.zoteroAttachment)
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
            .appendingPathComponent("zotero-cfg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        try writeConfig(container, libraryID: "12345", attachments: ["ABCD1234"])

        final class EnqueueLog: @unchecked Sendable { var ids: [SourceID] = [] }
        let log = EnqueueLog()
        _ = try await ExtractorSyncCommand.run(
            package: .zotero, force: false, in: store, containerDirectory: container,
            credentials: CredentialDouble(configured: true),
            enqueue: { log.ids.append($0) })
        #expect(log.ids.count == 1)

        let second = try await ExtractorSyncCommand.run(
            package: .zotero, force: false, in: store, containerDirectory: container,
            credentials: CredentialDouble(configured: true),
            enqueue: { log.ids.append($0) })
        #expect(log.ids.count == 1) // no new enqueue
        #expect(second.contains("skipped  ABCD1234"))
        #expect(try store.listSources().count == 1)
    }

    @Test func forceReenqueuesExistingSources() async throws {
        let store = try tempStore()
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("zotero-cfg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        try writeConfig(container, libraryID: "12345", attachments: ["ABCD1234"])

        final class EnqueueLog: @unchecked Sendable { var ids: [SourceID] = [] }
        let log = EnqueueLog()
        _ = try await ExtractorSyncCommand.run(
            package: .zotero, force: false, in: store, containerDirectory: container,
            credentials: CredentialDouble(configured: true),
            enqueue: { log.ids.append($0) })
        let original = log.ids

        let output = try await ExtractorSyncCommand.run(
            package: .zotero, force: true, in: store, containerDirectory: container,
            credentials: CredentialDouble(configured: true),
            enqueue: { log.ids.append($0) })

        #expect(output.contains("re-enqueued  ABCD1234"))
        #expect(log.ids.count == 2)
        #expect(log.ids[1] == original[0])
        #expect(try store.listSources().count == 1) // no duplicate source
    }

    @Test func unconfiguredLibraryFailsHard() async throws {
        let store = try tempStore()
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("zotero-cfg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        try writeConfig(container, libraryID: nil, attachments: ["ABCD1234"])

        await #expect(throws: ZoteroSyncError.libraryNotConfigured) {
            _ = try await ExtractorSyncCommand.run(
                package: .zotero, force: false, in: store, containerDirectory: container,
                credentials: CredentialDouble(configured: true),
                enqueue: { _ in })
        }
    }

    @Test func noAttachmentsFailsHard() async throws {
        let store = try tempStore()
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("zotero-cfg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        try writeConfig(container, libraryID: "12345", attachments: [])

        await #expect(throws: ZoteroSyncError.noAttachments) {
            _ = try await ExtractorSyncCommand.run(
                package: .zotero, force: false, in: store, containerDirectory: container,
                credentials: CredentialDouble(configured: true),
                enqueue: { _ in })
        }
    }

    @Test func unknownPackageFailsWithSupportedList() throws {
        // Parse-level grammar: an unrecognized package name is a usage
        // error naming the supported set, never a half-run sync. The
        // `--wiki` prefix selects a wiki first so the failure is the
        // package parse's, not the wiki-selection gate (both throw
        // ArgumentParser.Failure — without it this test would pass even
        // with the package branch deleted).
        let noEnv: (String) -> String? = { _ in nil }
        do {
            _ = try ArgumentParser.parse(
                ["--wiki", "test", "extractor", "sync", "notapackage"]) { key in noEnv(key) }
            Issue.record("expected the unknown-package usage error")
        } catch let failure as ArgumentParser.Failure {
            #expect(failure.description.contains("Unknown extraction package") == true)
            #expect(failure.description.contains("zotero") == true)
        }
    }

    @Test func syncWithoutPackageFailsWithGuidance() throws {
        // `extractor sync` with no package names the supported set too.
        let noEnv: (String) -> String? = { _ in nil }
        do {
            _ = try ArgumentParser.parse(
                ["--wiki", "test", "extractor", "sync"]) { key in noEnv(key) }
            Issue.record("expected the missing-package usage error")
        } catch let failure as ArgumentParser.Failure {
            #expect(failure.description.contains("supported: zotero") == true)
        }
    }

    @Test func syncGrammarParsesPackageAndForce() throws {
        let noEnv: (String) -> String? = { _ in nil }
        let invocation = try ArgumentParser.parse(
            ["--wiki", "test", "extractor", "sync", "zotero", "--force"]) { key in noEnv(key) }
        guard case .extractor(.sync(let package, let force)) = invocation.command else {
            Issue.record("expected an extractor sync command")
            return
        }
        #expect(package == .zotero)
        #expect(force)
    }

    @Test func missingAPIKeyFailsHardWithSetupGuidance() async throws {
        let store = try tempStore()
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("zotero-cfg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        try writeConfig(container, libraryID: "12345", attachments: ["ABCD1234"])

        do {
            _ = try await ExtractorSyncCommand.run(
                package: .zotero, force: false, in: store, containerDirectory: container,
                credentials: CredentialDouble(configured: false),
                enqueue: { _ in })
            Issue.record("expected ZoteroSyncError.apiKeyNotConfigured")
        } catch let error as ZoteroSyncError {
            // The API-key gate is package-scoped: the zotero entry throws it,
            // not the generic command (whose Failure knows only unknownPackage).
            #expect(error == .apiKeyNotConfigured)
            #expect(error.errorDescription?.contains("API key") == true)
        }
        #expect(try store.listSources().isEmpty)
    }

    @Test func unreadableAPIKeyDefersTheCheckToTheDrainingHost() async throws {
        // verificationFailed (not "unset") must NOT fail the sync: the
        // entitled host draining the job re-checks the key. The command
        // proceeds, creates the sources, and says it deferred the check.
        let store = try tempStore()
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("zotero-cfg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        try writeConfig(container, libraryID: "12345", attachments: ["ABCD1234"])

        let output = try await ExtractorSyncCommand.run(
            package: .zotero, force: false, in: store, containerDirectory: container,
            credentials: CredentialDouble(configured: false, verificationFailed: true),
            enqueue: { _ in })
        #expect(output.contains("could not be verified from this process"))
        #expect(try store.listSources().count == 1)
    }
}
