import Foundation
import Testing
@testable import WikiFSCore

/// Verifies `WikiStoreModel.ingestFromZotero` lands a local Zotero attachment
/// through the SAME store path as drag-ingest and URL-ingest, byte-identical, and
/// throws a clear error when the attachment isn't synced locally. Uses a real temp
/// directory standing in for `~/Zotero` — no real Zotero installation or network.
@MainActor
struct WikiStoreModelZoteroIngestTests {

    private func tempStore() throws -> SQLiteWikiStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-zoteroingest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try SQLiteWikiStore(databaseURL: dir.appendingPathComponent("WikiFS.sqlite"))
    }

    /// A fake `~/Zotero` with `storage/<key>/<filename>` fixtures pre-populated.
    private func tempZoteroDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fake-zotero-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeFixture(zoteroDir: URL, key: String, filename: String, data: Data) throws {
        let dir = zoteroDir.appendingPathComponent("storage/\(key)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: dir.appendingPathComponent(filename))
    }

    private func attachment(key: String, linkMode: String = "imported_file", filename: String?) -> ZoteroAttachment {
        ZoteroAttachment(
            key: key, parentItem: "PARENT1", linkMode: linkMode,
            filename: filename, contentType: "application/pdf", title: nil)
    }

    private func parentItem(key: String = "PARENT1", title: String? = "Sample Paper") -> ZoteroItem {
        ZoteroItem(
            key: key, version: 1, itemType: "journalArticle",
            title: title, creatorSummary: "Ito, K.", date: "2016")
    }

    @Test func localAttachmentLandsInSourcesList() async throws {
        let store = try tempStore()
        let model = WikiStoreModel(store: store)
        var didSignal = false
        model.onPageDidChange = { didSignal = true }

        let zoteroDir = try tempZoteroDir()
        var pdf = Data("%PDF-1.7".utf8)
        pdf.append(contentsOf: [0x00, 0xFF, 0x10])
        try writeFixture(zoteroDir: zoteroDir, key: "DJLXA7DG", filename: "report.pdf", data: pdf)

        try await model.ingestFromZotero(
            attachment(key: "DJLXA7DG", filename: "report.pdf"),
            parentItem: parentItem(), zoteroDir: zoteroDir)

        #expect(model.sources.count == 1)
        #expect(model.sources.first?.filename == "report.pdf")
        #expect(didSignal)

        let id = model.sources.first!.id
        #expect(try store.sourceContent(id: id) == pdf)  // byte-identical
    }

    /// The Zotero ingest seam threads the parent item's key + title into the
    /// ingested-file row so the detail view can show "From Zotero" + link back.
    @Test func zoteroIngestThreadsItemKeyAndTitleIntoSummary() async throws {
        let store = try tempStore()
        let model = WikiStoreModel(store: store)
        let zoteroDir = try tempZoteroDir()
        try writeFixture(zoteroDir: zoteroDir, key: "DJLXA7DG", filename: "report.pdf", data: Data("pdf".utf8))

        try await model.ingestFromZotero(
            attachment(key: "DJLXA7DG", filename: "report.pdf"),
            parentItem: parentItem(key: "PARENT1", title: "The Road Not Taken"), zoteroDir: zoteroDir)

        #expect(model.sources.count == 1)
        let summary = model.sources.first!
        #expect(summary.zoteroItemKey == "PARENT1")
        #expect(summary.zoteroItemTitle == "The Road Not Taken")

        // The stored row round-trips the provenance too (read-back path).
        let readBack = try store.getSource(id: summary.id)
        #expect(readBack.zoteroItemKey == "PARENT1")
        #expect(readBack.zoteroItemTitle == "The Road Not Taken")
    }

    @Test func missingLocalFileThrowsUnavailableAndLeavesListUnchanged() async throws {
        let store = try tempStore()
        let model = WikiStoreModel(store: store)
        let zoteroDir = try tempZoteroDir()  // no fixture written — file doesn't exist

        await #expect(throws: ZoteroFetchError.self) {
            try await model.ingestFromZotero(
                attachment(key: "MISSING1", filename: "ghost.pdf"),
                parentItem: parentItem(), zoteroDir: zoteroDir)
        }
        #expect(model.sources.isEmpty)
    }

    @Test func linkedModeThrowsUnavailableEvenIfFileHappensToExist() async throws {
        let store = try tempStore()
        let model = WikiStoreModel(store: store)
        let zoteroDir = try tempZoteroDir()
        try writeFixture(
            zoteroDir: zoteroDir, key: "L1", filename: "stray.pdf", data: Data("%PDF".utf8))

        await #expect(throws: ZoteroFetchError.self) {
            try await model.ingestFromZotero(
                attachment(key: "L1", linkMode: "linked_file", filename: "stray.pdf"),
                parentItem: parentItem(), zoteroDir: zoteroDir)
        }
        #expect(model.sources.isEmpty)
    }

    @Test func ingestingTwoAttachmentsAddsBothToList() async throws {
        let store = try tempStore()
        let model = WikiStoreModel(store: store)
        let zoteroDir = try tempZoteroDir()
        try writeFixture(
            zoteroDir: zoteroDir, key: "K1", filename: "paper.pdf", data: Data("pdf-content".utf8))
        try writeFixture(
            zoteroDir: zoteroDir, key: "K1", filename: "notes.md", data: Data("# Notes".utf8))

        try await model.ingestFromZotero(
            attachment(key: "K1", filename: "paper.pdf"), parentItem: parentItem(), zoteroDir: zoteroDir)
        try await model.ingestFromZotero(
            attachment(key: "K1", filename: "notes.md"), parentItem: parentItem(), zoteroDir: zoteroDir)

        #expect(model.sources.count == 2)
        let filenames = Set(model.sources.map(\.filename))
        #expect(filenames == ["paper.pdf", "notes.md"])
    }

    // MARK: - ZoteroFetchError

    @Test func zoteroFetchErrorDescriptionReturnsReason() {
        let error = ZoteroFetchError.unavailable("Not synced to this Mac yet")
        #expect(error.errorDescription == "Not synced to this Mac yet")
    }

    @Test func zoteroFetchErrorIsEquatable() {
        let a = ZoteroFetchError.unavailable("msg")
        let b = ZoteroFetchError.unavailable("msg")
        let c = ZoteroFetchError.unavailable("different")
        #expect(a == b)
        #expect(a != c)
    }
}
