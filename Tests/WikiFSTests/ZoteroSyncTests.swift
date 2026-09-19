import Foundation
import Testing
@testable import WikiFSCore

/// `ZoteroSync.syncAttachments(store:config:enqueue:force:)` — the config →
/// byteless `.zotero` source → enqueued extraction flow. No network and no
/// real Zotero installation: the sync only writes the plan URLs; the
/// reviewed Zotero package downloads the bytes later. Uses the same
/// temp-directory `GRDBWikiStore` pattern as the other store tests.
struct ZoteroSyncTests {

    private func tempStore() throws -> GRDBWikiStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-zoterosync-\(UUID().uuidString)", isDirectory: true)
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

    private func configuredConfig(attachments: [String] = ["ABCD1234", "WXYZ5678"]) -> ZoteroConfig {
        ZoteroConfig(libraryID: "7089244", attachments: attachments)
    }

    @Test func syncCreatesBytelessZoteroSourcesAndEnqueuesEachInOrder() async throws {
        let store = try tempStore()
        let recorder = EnqueueRecorder()
        let keys = ["ABCD1234", "WXYZ5678"]

        let outcomes = try await ZoteroSync.syncAttachments(
            store: store, config: configuredConfig(attachments: keys)) { id in
            recorder.record(id)
        }

        #expect(outcomes.map(\.attachmentKey) == keys)
        #expect(outcomes.map(\.action) == [.created, .created])
        #expect(recorder.recorded == outcomes.map(\.sourceID))

        for (outcome, key) in zip(outcomes, keys) {
            let summary = try store.getSource(id: outcome.sourceID)
            #expect(summary.byteSize == 0, "byteless source")
            #expect(summary.mimeType == ContentTypeRegistry.zoteroAttachment)
            // `#require` can't wrap a throwing call directly — resolve first.
            let rawOrigin = try store.sourceOrigin(sourceID: summary.id)
            let origin = try #require(rawOrigin)
            #expect(origin.plan == "https://api.zotero.org/users/7089244/items/\(key)/file")
            #expect(origin.externalIdentity == key)
        }
        #expect(try store.listSources().count == 2)
    }

    @Test func rerunSkipsExistingURLsWithoutEnqueueingAgain() async throws {
        let store = try tempStore()
        let recorder = EnqueueRecorder()
        let config = configuredConfig()

        _ = try await ZoteroSync.syncAttachments(store: store, config: config) {
            recorder.record($0)
        }
        let firstRunIDs = recorder.recorded

        let outcomes = try await ZoteroSync.syncAttachments(store: store, config: config) {
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
        let config = configuredConfig()

        _ = try await ZoteroSync.syncAttachments(store: store, config: config) {
            recorder.record($0)
        }
        let firstRunIDs = recorder.recorded

        let outcomes = try await ZoteroSync.syncAttachments(
            store: store, config: config,
            enqueue: { recorder.record($0) },
            force: true)

        #expect(outcomes.map(\.action) == [.reenqueued, .reenqueued])
        #expect(outcomes.map(\.sourceID) == firstRunIDs)
        #expect(recorder.recorded == firstRunIDs + firstRunIDs)
        #expect(try store.listSources().count == 2, "no duplicate sources")
    }

    @Test func unconfiguredLibraryThrowsLibraryNotConfigured() async throws {
        let store = try tempStore()
        let recorder = EnqueueRecorder()
        let config = ZoteroConfig(libraryID: nil, attachments: ["ABCD1234"])

        await #expect(throws: ZoteroSyncError.libraryNotConfigured) {
            try await ZoteroSync.syncAttachments(store: store, config: config) {
                recorder.record($0)
            }
        }
        #expect(recorder.recorded.isEmpty)
    }

    @Test func emptyAttachmentsThrowsNoAttachments() async throws {
        let store = try tempStore()
        let recorder = EnqueueRecorder()
        let config = ZoteroConfig(libraryID: "7089244", attachments: [])

        await #expect(throws: ZoteroSyncError.noAttachments) {
            try await ZoteroSync.syncAttachments(store: store, config: config) {
                recorder.record($0)
            }
        }
        #expect(recorder.recorded.isEmpty)
    }

    /// The config seam that feeds the sync: `validatedAttachments` preserves
    /// input order, so the configured order is the sync (and enqueue) order.
    @Test func validatedAttachmentOrderDrivesSyncOrder() async throws {
        let keys = ["ZZZZ9999", "AAAA0000", "Q7W8E9R0"]
        let validated = try ZoteroConfig.validatedAttachments(keys)
        #expect(validated == keys)

        let store = try tempStore()
        let recorder = EnqueueRecorder()
        let outcomes = try await ZoteroSync.syncAttachments(
            store: store,
            config: ZoteroConfig(libraryID: "7089244", attachments: validated)) {
            recorder.record($0)
        }
        #expect(outcomes.map(\.attachmentKey) == keys)
        #expect(recorder.recorded == outcomes.map(\.sourceID))
    }
}
