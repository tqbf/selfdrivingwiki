import Foundation
import Testing
@testable import WikiFSCore
import WikiFSTypes

/// `ExtractorPackageSync.syncItems(store:declaration:packageIdentity:config:enqueue:force:)`
/// — the declared config → byteless source → enqueued extraction flow, fully
/// generic. No network and no real package installation: the sync only
/// writes the interpolated plan URLs; the package downloads the bytes later.
/// Uses the same temp-directory `GRDBWikiStore` pattern as the other store
/// tests.
struct ExtractorPackageSyncTests {

    private func tempStore() throws -> GRDBWikiStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-packagesync-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try GRDBWikiStore(databaseURL: dir.appendingPathComponent("WikiFS.sqlite"))
    }

    /// Records `enqueue` calls without an actor — the sync is plain async,
    /// so a lock-guarded box is enough (`enqueue` runs sequentially).
    private final class EnqueueRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var ids: [SourceID] = []
        func record(_ id: SourceID) { lock.withLock { ids.append(id) } }
        var recorded: [SourceID] { lock.withLock { ids } }
    }

    /// A zotero-shaped declaration: same template and MIME as the reviewed
    /// package, different package identity (the engine must not care).
    private let declaration = try! ExtractorSyncDeclaration(
        configFileName: "sync-config.json",
        urlTemplate: "https://api.example.org/users/{libraryID}/items/{itemKey}/file",
        fields: [
            ExtractorSyncFieldDeclaration(name: "libraryID", required: true),
            ExtractorSyncFieldDeclaration(name: "items", required: true, isList: true),
        ],
        itemValidation: ExtractorSyncItemValidation(
            minimumLength: 8, maximumLength: 8,
            alphabet: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"))

    private let identity = ExtractorSyncPackageIdentity(
        packageID: try! ExtractorPackageID(validating: "org.example.attachment"),
        displayName: "Example Attachment")

    private let sourceMIMEType = try! ExtractorMIMEType(validating: "application/x-attachment")

    private func configuredValues(items: [String] = ["ABCD1234", "WXYZ5678"]) -> ExtractorSyncSidecarValues {
        ExtractorSyncSidecarValues(
            fieldValues: ["libraryID": "7089244"], items: items)
    }

    @Test func syncCreatesBytelessSourcesAndEnqueuesEachInOrder() async throws {
        let store = try tempStore()
        let recorder = EnqueueRecorder()
        let items = ["ABCD1234", "WXYZ5678"]

        let outcomes = try await ExtractorPackageSync.syncItems(
            store: store,
            declaration: declaration,
            packageIdentity: identity,
            config: configuredValues(items: items),
            sourceMIMEType: sourceMIMEType) { id in
            recorder.record(id)
        }

        #expect(outcomes.map(\.itemKey) == items)
        #expect(outcomes.map(\.action) == [.created, .created])
        #expect(recorder.recorded == outcomes.map(\.sourceID))

        for (outcome, key) in zip(outcomes, items) {
            let summary = try store.getSource(id: outcome.sourceID)
            #expect(summary.byteSize == 0, "byteless source")
            #expect(summary.mimeType == "application/x-attachment")
            // `#require` can't wrap a throwing call directly — resolve first.
            let rawOrigin = try store.sourceOrigin(sourceID: summary.id)
            let origin = try #require(rawOrigin)
            #expect(origin.plan == "https://api.example.org/users/7089244/items/\(key)/file")
            #expect(origin.externalIdentity == key)
            // The provenance agent name is package data: the ID's last label.
            // An agent name the origin-provider table does not know degrades
            // to nil (generic origin chip), never a failure — known names
            // like the reviewed zotero package's resolve as display data.
            #expect(origin.provider == nil)
        }
        #expect(try store.listSources().count == 2)
    }

    @Test func rerunSkipsExistingURLsWithoutEnqueueingAgain() async throws {
        let store = try tempStore()
        let recorder = EnqueueRecorder()
        let config = configuredValues()

        _ = try await ExtractorPackageSync.syncItems(
            store: store, declaration: declaration, packageIdentity: identity,
            config: config, sourceMIMEType: sourceMIMEType) {
            recorder.record($0)
        }
        let firstRunIDs = recorder.recorded

        let outcomes = try await ExtractorPackageSync.syncItems(
            store: store, declaration: declaration, packageIdentity: identity,
            config: config, sourceMIMEType: sourceMIMEType) {
            recorder.record($0)
        }

        #expect(outcomes.map(\.action) == [.skipped, .skipped])
        #expect(outcomes.map(\.sourceID) == firstRunIDs)
        #expect(recorder.recorded == firstRunIDs, "no new enqueue calls")
        #expect(try store.listSources().count == 2)
    }

    @Test func forceReenqueuesExistingSourcesAndCreatesNoDuplicates() async throws {
        let store = try tempStore()
        let recorder = EnqueueRecorder()
        let config = configuredValues()

        _ = try await ExtractorPackageSync.syncItems(
            store: store, declaration: declaration, packageIdentity: identity,
            config: config, sourceMIMEType: sourceMIMEType) {
            recorder.record($0)
        }
        let firstRunIDs = recorder.recorded

        let outcomes = try await ExtractorPackageSync.syncItems(
            store: store, declaration: declaration, packageIdentity: identity,
            config: config, sourceMIMEType: sourceMIMEType,
            enqueue: { recorder.record($0) },
            force: true)

        #expect(outcomes.map(\.action) == [.reenqueued, .reenqueued])
        #expect(outcomes.map(\.sourceID) == firstRunIDs)
        #expect(recorder.recorded == firstRunIDs + firstRunIDs)
        #expect(try store.listSources().count == 2, "no duplicate sources")
    }

    /// URL-identity dedupe: the same URL from a DIFFERENT item key (the
    /// template collapses them) still resolves to the existing source —
    /// the engine's dedupe key is the URL identity, not the item key.
    @Test func urlIdentityDedupeMatchesAcrossItemKeys() async throws {
        let store = try tempStore()
        let recorder = EnqueueRecorder()

        _ = try await ExtractorPackageSync.syncItems(
            store: store, declaration: declaration, packageIdentity: identity,
            config: configuredValues(items: ["ABCD1234"]),
            sourceMIMEType: sourceMIMEType) { recorder.record($0) }

        // A different declaration (different field name) that produces the
        // SAME URL proves the dedupe key is the URL identity, not the
        // declaration or the item key.
        let aliasDeclaration = try ExtractorSyncDeclaration(
            configFileName: "alias-config.json",
            urlTemplate: "https://api.example.org/users/{accountID}/items/{itemKey}/file",
            fields: [
                ExtractorSyncFieldDeclaration(name: "accountID", required: true),
                ExtractorSyncFieldDeclaration(name: "items", required: true, isList: true),
            ],
            itemValidation: ExtractorSyncItemValidation(
                minimumLength: 8, maximumLength: 8,
                alphabet: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"))
        let outcomes = try await ExtractorPackageSync.syncItems(
            store: store, declaration: aliasDeclaration, packageIdentity: identity,
            config: ExtractorSyncSidecarValues(
                fieldValues: ["accountID": "7089244"], items: ["ABCD1234"]),
            sourceMIMEType: sourceMIMEType) { recorder.record($0) }

        #expect(outcomes.map(\.action) == [.skipped])
        #expect(try store.listSources().count == 1)
        #expect(recorder.recorded.count == 1, "no new enqueue calls")
    }

    /// An item that cannot form a valid URL is a typed engine failure. The
    /// practical trigger: a template references an OPTIONAL field the
    /// config does not carry — the interpolated template has no value for
    /// the placeholder, so no URL can form.
    @Test func invalidItemFailsWithTypeError() async throws {
        let store = try tempStore()
        let recorder = EnqueueRecorder()
        let optionalRegionDeclaration = try ExtractorSyncDeclaration(
            configFileName: "region-config.json",
            urlTemplate: "https://api.example.org/{region}/users/{libraryID}/items/{itemKey}",
            fields: [
                ExtractorSyncFieldDeclaration(name: "libraryID", required: true),
                ExtractorSyncFieldDeclaration(name: "region", required: false),
                ExtractorSyncFieldDeclaration(name: "items", required: true, isList: true),
            ])

        await #expect(throws: ExtractorSyncEngineError.invalidItem(itemKey: "ABCD1234")) {
            _ = try await ExtractorPackageSync.syncItems(
                store: store, declaration: optionalRegionDeclaration,
                packageIdentity: identity,
                config: ExtractorSyncSidecarValues(
                    fieldValues: ["libraryID": "7089244"], items: ["ABCD1234"]),
                sourceMIMEType: sourceMIMEType) {
                recorder.record($0)
            }
        }
        #expect(recorder.recorded.isEmpty)
    }

    /// An empty item list produces zero outcomes — the required-list gate
    /// lives in the sidecar, so the engine's contract is simply "sync what
    /// is configured".
    @Test func emptyItemsSyncNothing() async throws {
        let store = try tempStore()
        let recorder = EnqueueRecorder()

        let outcomes = try await ExtractorPackageSync.syncItems(
            store: store, declaration: declaration, packageIdentity: identity,
            config: ExtractorSyncSidecarValues(fieldValues: ["libraryID": "7089244"], items: []),
            sourceMIMEType: sourceMIMEType) {
            recorder.record($0)
        }

        #expect(outcomes.isEmpty)
        #expect(recorder.recorded.isEmpty)
        #expect(try store.listSources().isEmpty)
    }
}
