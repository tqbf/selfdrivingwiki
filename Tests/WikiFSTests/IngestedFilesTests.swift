import CryptoKit
import Foundation
import SQLite3
import Testing
@testable import WikiFSCore

/// Phase 5 file-ingestion tests: ingest/list/get/delete, byte-identical content
/// round-trip, ext/mime derivation, the soft size cap, the stepwise v1→2
/// migration (pages preserved), and distinct ULIDs for duplicate drops.
struct IngestedFilesTests {

    private func tempDatabaseURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-ingest-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("WikiFS.sqlite")
    }

    private func tempStore() throws -> SQLiteWikiStore {
        try SQLiteWikiStore(databaseURL: tempDatabaseURL())
    }

    // MARK: - Ingest inserts a row with the right metadata

    @Test func ingestInsertsRowWithByteSizeMatchingData() throws {
        let store = try tempStore()
        let bytes = Data((0..<512).map { UInt8($0 % 256) })
        let summary = try store.ingestFile(filename: "blob.bin", data: bytes)
        #expect(summary.byteSize == bytes.count)
        #expect(summary.filename == "blob.bin")
        #expect(summary.version == 1)

        // byte_size column == length(content) in SQLite.
        let row = try store.getIngestedFile(id: summary.id)
        #expect(row.byteSize == bytes.count)
        #expect(try store.ingestedFileContent(id: summary.id).count == bytes.count)
    }

    @Test func extAndMimeDerivedFromFilename() throws {
        let store = try tempStore()
        let pdf = try store.ingestFile(filename: "Report.PDF", data: Data("%PDF".utf8))
        #expect(pdf.ext == "pdf")  // lowercased
        #expect(pdf.mimeType == "application/pdf")

        let noExt = try store.ingestFile(filename: "README", data: Data("x".utf8))
        #expect(noExt.ext == "")
        #expect(noExt.mimeType == nil)
    }

    // MARK: - Content is byte-identical (== and sha256)

    @Test func ingestedContentRoundTripsByteIdentical() throws {
        let store = try tempStore()
        // Include non-text bytes + a NUL to prove this is raw, not text handling.
        var original = Data("header\u{0}".utf8)
        original.append(contentsOf: (0..<300).map { UInt8(($0 * 7) % 256) })
        let summary = try store.ingestFile(filename: "data.bin", data: original)

        let fetched = try store.ingestedFileContent(id: summary.id)
        #expect(fetched == original)
        #expect(SHA256.hash(data: fetched) == SHA256.hash(data: original))
    }

    @Test func zeroByteFileIsAllowedWithSizeZero() throws {
        let store = try tempStore()
        let summary = try store.ingestFile(filename: "empty.txt", data: Data())
        #expect(summary.byteSize == 0)
        #expect(try store.ingestedFileContent(id: summary.id) == Data())
    }

    // MARK: - Soft cap

    @Test func oversizeFileIsRejected() throws {
        let store = try tempStore()
        // One byte past the cap. (Allocating exactly cap+1 of zeros is cheap.)
        let huge = Data(count: SQLiteWikiStore.ingestByteCap + 1)
        #expect(throws: (any Error).self) {
            _ = try store.ingestFile(filename: "huge.bin", data: huge)
        }
        #expect(try store.listIngestedFiles().isEmpty)
    }

    // MARK: - Delete

    @Test func deleteRemovesRow() throws {
        let store = try tempStore()
        let summary = try store.ingestFile(filename: "x.txt", data: Data("x".utf8))
        try store.deleteIngestedFile(id: summary.id)
        #expect(try store.listIngestedFiles().isEmpty)
        #expect(throws: (any Error).self) {
            _ = try store.getIngestedFile(id: summary.id)
        }
    }

    // MARK: - Duplicate drops → distinct ULIDs

    @Test func duplicateDropsGetDistinctIDs() throws {
        let store = try tempStore()
        let a = try store.ingestFile(filename: "same.txt", data: Data("same".utf8))
        let b = try store.ingestFile(filename: "same.txt", data: Data("same".utf8))
        #expect(a.id != b.id)
        #expect(try store.listIngestedFiles().count == 2)
    }

    // MARK: - Ordering (most-recent-first for the UI list)

    @Test func listIsMostRecentFirst() throws {
        let store = try tempStore()
        let first = try store.ingestFile(filename: "1.txt", data: Data("1".utf8))
        let second = try store.ingestFile(filename: "2.txt", data: Data("2".utf8))
        let list = try store.listIngestedFiles()
        // created_at DESC, id DESC: the later (larger ULID) sorts first.
        #expect(list.first?.id == second.id)
        #expect(list.last?.id == first.id)
    }

    @MainActor
    @Test func modelTracksWhetherFileHasBeenAgentIngested() throws {
        let store = try tempStore()
        let raw = try store.ingestFile(filename: "source.pdf", data: Data("%PDF".utf8))
        let untouched = try store.ingestFile(filename: "notes.txt", data: Data("notes".utf8))

        let model = WikiStoreModel(store: store)
        #expect(model.hasIngestedFile(raw) == false)
        #expect(model.hasIngestedFile(untouched) == false)

        try store.appendLog(kind: .ingest, title: "files/by-id/\(raw.id.rawValue).pdf", note: nil)
        model.reloadFromStore()

        #expect(model.hasIngestedFile(raw) == true)
        #expect(model.hasIngestedFile(untouched) == false)
    }

    // MARK: - Stepwise migration (v1 DB with pages → v2, pages intact)

    @Test func migratesV1DatabaseToV2PreservingPages() throws {
        let url = tempDatabaseURL()

        // Build a v1-shaped DB by hand: pages + slug index + user_version=1,
        // WITHOUT ingested_files. Seed one page.
        var raw: OpaquePointer?
        #expect(sqlite3_open(url.path, &raw) == SQLITE_OK)
        let v1SQL = """
        CREATE TABLE pages (
            id TEXT PRIMARY KEY, title TEXT NOT NULL, slug TEXT NOT NULL,
            body_markdown TEXT NOT NULL DEFAULT '', created_at REAL NOT NULL,
            updated_at REAL NOT NULL, version INTEGER NOT NULL DEFAULT 1);
        CREATE UNIQUE INDEX pages_slug_unique ON pages(slug);
        INSERT INTO pages (id, title, slug, body_markdown, created_at, updated_at, version)
          VALUES ('01PRESERVEDPAGE0000000000', 'Kept', 'kept', '# kept', 1, 1, 1);
        PRAGMA user_version=1;
        """
        #expect(sqlite3_exec(raw, v1SQL, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(raw)

        // Open via the store → runs the v1→2 step (and the later v2→3 step).
        let store = try SQLiteWikiStore(databaseURL: url)

        // ingested_files now exists and is usable.
        let summary = try store.ingestFile(filename: "after.txt", data: Data("after".utf8))
        #expect(summary.byteSize == 5)

        // The pre-existing page is intact.
        let page = try store.getPage(id: PageID(rawValue: "01PRESERVEDPAGE0000000000"))
        #expect(page.title == "Kept")
        #expect(page.bodyMarkdown == "# kept")

        // user_version is now 6 (migration runs through every step to head).
        var check: OpaquePointer?
        #expect(sqlite3_open(url.path, &check) == SQLITE_OK)
        defer { sqlite3_close(check) }
        var stmt: OpaquePointer?
        #expect(sqlite3_prepare_v2(check, "PRAGMA user_version;", -1, &stmt, nil) == SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        #expect(sqlite3_step(stmt) == SQLITE_ROW)
        #expect(sqlite3_column_int(stmt, 0) == 7)
        _ = store
    }
}
