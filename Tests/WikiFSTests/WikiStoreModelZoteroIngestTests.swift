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

    @Test func localAttachmentLandsInIngestedFilesList() async throws {
        let store = try tempStore()
        let model = WikiStoreModel(store: store)
        var didSignal = false
        model.onPageDidChange = { didSignal = true }

        let zoteroDir = try tempZoteroDir()
        var pdf = Data("%PDF-1.7".utf8)
        pdf.append(contentsOf: [0x00, 0xFF, 0x10])
        try writeFixture(zoteroDir: zoteroDir, key: "DJLXA7DG", filename: "report.pdf", data: pdf)

        try await model.ingestFromZotero(
            attachment(key: "DJLXA7DG", filename: "report.pdf"), zoteroDir: zoteroDir)

        #expect(model.ingestedFiles.count == 1)
        #expect(model.ingestedFiles.first?.filename == "report.pdf")
        #expect(didSignal)

        let id = model.ingestedFiles.first!.id
        #expect(try store.ingestedFileContent(id: id) == pdf)  // byte-identical
    }

    @Test func missingLocalFileThrowsUnavailableAndLeavesListUnchanged() async throws {
        let store = try tempStore()
        let model = WikiStoreModel(store: store)
        let zoteroDir = try tempZoteroDir()  // no fixture written — file doesn't exist

        await #expect(throws: ZoteroIngestError.self) {
            try await model.ingestFromZotero(
                attachment(key: "MISSING1", filename: "ghost.pdf"), zoteroDir: zoteroDir)
        }
        #expect(model.ingestedFiles.isEmpty)
    }

    @Test func linkedModeThrowsUnavailableEvenIfFileHappensToExist() async throws {
        let store = try tempStore()
        let model = WikiStoreModel(store: store)
        let zoteroDir = try tempZoteroDir()
        try writeFixture(
            zoteroDir: zoteroDir, key: "L1", filename: "stray.pdf", data: Data("%PDF".utf8))

        await #expect(throws: ZoteroIngestError.self) {
            try await model.ingestFromZotero(
                attachment(key: "L1", linkMode: "linked_file", filename: "stray.pdf"), zoteroDir: zoteroDir)
        }
        #expect(model.ingestedFiles.isEmpty)
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
            attachment(key: "K1", filename: "paper.pdf"), zoteroDir: zoteroDir)
        try await model.ingestFromZotero(
            attachment(key: "K1", filename: "notes.md"), zoteroDir: zoteroDir)

        #expect(model.ingestedFiles.count == 2)
        let filenames = Set(model.ingestedFiles.map(\.filename))
        #expect(filenames == ["paper.pdf", "notes.md"])
    }

    // MARK: - ZoteroIngestError

    @Test func zoteroIngestErrorDescriptionReturnsReason() {
        let error = ZoteroIngestError.unavailable("Not synced to this Mac yet")
        #expect(error.errorDescription == "Not synced to this Mac yet")
    }

    @Test func zoteroIngestErrorIsEquatable() {
        let a = ZoteroIngestError.unavailable("msg")
        let b = ZoteroIngestError.unavailable("msg")
        let c = ZoteroIngestError.unavailable("different")
        #expect(a == b)
        #expect(a != c)
    }
}
