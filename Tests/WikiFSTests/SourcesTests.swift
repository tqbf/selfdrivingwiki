import CryptoKit
import CoreGraphics
import Foundation
import SQLite3
import Testing
import WikiFS
@testable import WikiFSCore

/// Phase 5 file-ingestion tests: ingest/list/get/delete, byte-identical content
/// round-trip, ext/mime derivation, the soft size cap, the stepwise v1→2
/// migration (pages preserved), and duplicate-content detection (issue #126).
struct SourcesTests {

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
        let summary = try store.addSource(filename: "blob.bin", data: bytes)
        #expect(summary.byteSize == bytes.count)
        #expect(summary.filename == "blob.bin")
        #expect(summary.version == 1)

        // byte_size column == length(content) in SQLite.
        let row = try store.getSource(id: summary.id)
        #expect(row.byteSize == bytes.count)
        #expect(try store.sourceContent(id: summary.id).count == bytes.count)
    }

    @Test func extAndMimeDerivedFromFilename() throws {
        let store = try tempStore()
        let pdf = try store.addSource(filename: "Report.PDF", data: Data("%PDF".utf8))
        #expect(pdf.ext == "pdf")  // lowercased
        #expect(pdf.mimeType == "application/pdf")

        let noExt = try store.addSource(filename: "README", data: Data("x".utf8))
        #expect(noExt.ext == "")
        #expect(noExt.mimeType == nil)
    }

    // MARK: - MIME from content sniff (content-type-over-extension plan)

    @Test func mimeFromContentSniffPDFBytesWithTextExtension() throws {
        // PDF bytes with a .txt filename → mime_type is "application/pdf" from the
        // magic-byte sniff, not "text/plain" from the extension.
        let store = try tempStore()
        let source = try store.addSource(filename: "renamed.txt", data: Data("%PDF-1.4\n%binary".utf8))
        #expect(source.mimeType == "application/pdf")
    }

    @Test func mimeFromContentSniffPNGBytesNoExtension() throws {
        // Real PNG magic bytes with no extension → sniffed as image/png.
        let store = try tempStore()
        let pngMagic = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let source = try store.addSource(filename: "noext", data: pngMagic)
        #expect(source.ext == "")
        #expect(source.mimeType == "image/png")
    }

    @Test func mimeExplicitParamOverridesSniff() throws {
        // Explicit mimeType parameter wins over both byte sniff and ext fallback.
        let store = try tempStore()
        let source = try store.addSource(
            filename: "data.pdf", data: Data("%PDF-1.4\ncontent".utf8),
            zoteroItemKey: nil, zoteroItemTitle: nil,
            mimeType: "application/custom")
        #expect(source.mimeType == "application/custom")
    }

    @Test func mimeFallsBackToExtWhenSniffInconclusive() throws {
        // Bytes that don't match any magic number fall back to ext-derived MIME.
        let store = try tempStore()
        let source = try store.addSource(filename: "notes.md", data: Data("# Hello".utf8))
        // UTType(filenameExtension: "md")?.preferredMIMEType returns a markdown
        // variant; accept either.
        #expect(source.mimeType?.hasPrefix("text/") == true)
        #expect(source.mimeType?.contains("markdown") == true)
    }

    // MARK: - Zotero provenance (v8 → v9)

    /// A drag-drop / URL ingest passes no Zotero provenance, so the two new
    /// columns stay NULL and round-trip as nil through the read path.
    @Test func ingestWithoutZoteroProvenanceRoundTripsNil() throws {
        let store = try tempStore()
        let summary = try store.addSource(
            filename: "drop.pdf", data: Data("%PDF".utf8),
            zoteroItemKey: nil, zoteroItemTitle: nil)
        #expect(summary.zoteroItemKey == nil)
        #expect(summary.zoteroItemTitle == nil)

        let readBack = try store.getSource(id: summary.id)
        #expect(readBack.zoteroItemKey == nil)
        #expect(readBack.zoteroItemTitle == nil)

        let listed = try store.listSources()
        #expect(listed.first?.zoteroItemKey == nil)
        #expect(listed.first?.zoteroItemTitle == nil)
    }

    /// The Zotero seam writes the item key + title and they survive a read-back.
    @Test func ingestWithZoteroProvenanceRoundTripsKeyAndTitle() throws {
        let store = try tempStore()
        let summary = try store.addSource(
            filename: "paper.pdf", data: Data("%PDF".utf8),
            zoteroItemKey: "ABC123", zoteroItemTitle: "A Study in Scarlet")
        #expect(summary.zoteroItemKey == "ABC123")
        #expect(summary.zoteroItemTitle == "A Study in Scarlet")

        let readBack = try store.getSource(id: summary.id)
        #expect(readBack.zoteroItemKey == "ABC123")
        #expect(readBack.zoteroItemTitle == "A Study in Scarlet")
    }

    // MARK: - Content is byte-identical (== and sha256)

    @Test func ingestedContentRoundTripsByteIdentical() throws {
        let store = try tempStore()
        // Include non-text bytes + a NUL to prove this is raw, not text handling.
        var original = Data("header\u{0}".utf8)
        original.append(contentsOf: (0..<300).map { UInt8(($0 * 7) % 256) })
        let summary = try store.addSource(filename: "data.bin", data: original)

        let fetched = try store.sourceContent(id: summary.id)
        #expect(fetched == original)
        #expect(SHA256.hash(data: fetched) == SHA256.hash(data: original))
    }

    @Test func zeroByteFileIsAllowedWithSizeZero() throws {
        let store = try tempStore()
        let summary = try store.addSource(filename: "empty.txt", data: Data())
        #expect(summary.byteSize == 0)
        #expect(try store.sourceContent(id: summary.id) == Data())
    }

    // MARK: - Soft cap

    @Test func oversizeFileIsRejected() throws {
        let store = try tempStore()
        // One byte past the cap. (Allocating exactly cap+1 of zeros is cheap.)
        let huge = Data(count: SQLiteWikiStore.ingestByteCap + 1)
        #expect(throws: (any Error).self) {
            _ = try store.addSource(filename: "huge.bin", data: huge)
        }
        #expect(try store.listSources().isEmpty)
    }

    // MARK: - Delete

    @Test func deleteRemovesRow() throws {
        let store = try tempStore()
        let summary = try store.addSource(filename: "x.txt", data: Data("x".utf8))
        try store.deleteSource(id: summary.id)
        #expect(try store.listSources().isEmpty)
        #expect(throws: (any Error).self) {
            _ = try store.getSource(id: summary.id)
        }
    }

    // MARK: - Duplicate content detection (issue #126)

    @Test func byteIdenticalContentThrowsDuplicateContent() throws {
        // Same bytes, same filename: rejected — the whole point of the check.
        let store = try tempStore()
        let a = try store.addSource(filename: "same.txt", data: Data("same".utf8))
        #expect(throws: WikiStoreError.self) {
            try store.addSource(filename: "same.txt", data: Data("same".utf8))
        }
        #expect(try store.listSources().count == 1)

        do {
            _ = try store.addSource(filename: "same.txt", data: Data("same".utf8))
            Issue.record("expected duplicateContent to be thrown")
        } catch WikiStoreError.duplicateContent(let existing) {
            #expect(existing.id == a.id)
        }
    }

    @Test func byteIdenticalContentUnderADifferentFilenameStillThrows() throws {
        // The hash is over CONTENT only — a renamed re-drop of the same bytes
        // is still a duplicate (issue #126's proposal: content-only, filename
        // is irrelevant to the hash).
        let store = try tempStore()
        _ = try store.addSource(filename: "original.txt", data: Data("same".utf8))
        #expect(throws: WikiStoreError.self) {
            try store.addSource(filename: "renamed.txt", data: Data("same".utf8))
        }
        #expect(try store.listSources().count == 1)
    }

    @Test func distinctContentIsNotFlaggedAsDuplicate() throws {
        let store = try tempStore()
        let a = try store.addSource(filename: "1.txt", data: Data("one".utf8))
        let b = try store.addSource(filename: "2.txt", data: Data("two".utf8))
        #expect(a.id != b.id)
        #expect(try store.listSources().count == 2)
    }

    // MARK: - Ordering (most-recent-first for the UI list)

    @Test func listIsMostRecentFirst() throws {
        let store = try tempStore()
        let first = try store.addSource(filename: "1.txt", data: Data("1".utf8))
        let second = try store.addSource(filename: "2.txt", data: Data("2".utf8))
        let list = try store.listSources()
        // created_at DESC, id DESC: the later (larger ULID) sorts first.
        #expect(list.first?.id == second.id)
        #expect(list.last?.id == first.id)
    }

    @MainActor
    @Test func modelTracksWhetherFileHasBeenAgentIngested() throws {
        let store = try tempStore()
        let raw = try store.addSource(filename: "source.pdf", data: Data("%PDF".utf8))
        let untouched = try store.addSource(filename: "notes.txt", data: Data("notes".utf8))

        let model = WikiStoreModel(store: store)
        #expect(model.isSourceIngested(raw) == false)
        #expect(model.isSourceIngested(untouched) == false)

        try store.appendLog(kind: .ingest, title: "files/by-id/\(raw.id.rawValue).pdf", note: nil)
        model.reloadFromStore()

        #expect(model.isSourceIngested(raw) == true)
        #expect(model.isSourceIngested(untouched) == false)
    }

    // MARK: - Stepwise migration (v1 DB with pages → v2, pages intact)

    @Test func migratesV1DatabaseToV2PreservingPages() throws {
        let url = tempDatabaseURL()

        // Build a v1-shaped DB by hand: pages + slug index + user_version=1,
        // WITHOUT sources. Seed one page.
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

        // sources now exists and is usable.
        let summary = try store.addSource(filename: "after.txt", data: Data("after".utf8))
        #expect(summary.byteSize == 5)

        // The pre-existing page is intact.
        let page = try store.getPage(id: PageID(rawValue: "01PRESERVEDPAGE0000000000"))
        #expect(page.title == "Kept")
        #expect(page.bodyMarkdown == "# kept")

        // user_version advances through every migration step to head (v9 after the
        // v8→v9 Zotero-provenance step).
        var check: OpaquePointer?
        #expect(sqlite3_open(url.path, &check) == SQLITE_OK)
        defer { sqlite3_close(check) }
        var stmt: OpaquePointer?
        #expect(sqlite3_prepare_v2(check, "PRAGMA user_version;", -1, &stmt, nil) == SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        #expect(sqlite3_step(stmt) == SQLITE_ROW)
        #expect(sqlite3_column_int(stmt, 0) == 28)
        _ = store
    }

    // MARK: - DisplayNameResolver

    @Test func displayNameFromZoteroTitle() {
        let result = DisplayNameResolver.resolve(
            filename: "abc123.pdf", data: Data(),
            mimeType: "application/pdf",
            zoteroItemTitle: "A Study in Scarlet")
        #expect(result == "A Study in Scarlet")
    }

    @Test func displayNameNilWhenZoteroTitleIsWhitespace() {
        let result = DisplayNameResolver.resolve(
            filename: "abc123.pdf", data: Data(),
            mimeType: "application/pdf",
            zoteroItemTitle: "   ")
        #expect(result == nil)
    }

    @Test func displayNameFromMarkdownFrontMatterDoubleQuoted() {
        let md = """
        ---
        title: "Hello World"
        ---
        # Content
        """
        let result = DisplayNameResolver.resolve(
            filename: "note.md", data: Data(md.utf8),
            mimeType: nil, zoteroItemTitle: nil)
        #expect(result == "Hello World")
    }

    @Test func displayNameFromMarkdownFrontMatterSingleQuoted() {
        let md = """
        ---
        title: 'Single Quoted Title'
        ---
        # Body
        """
        let result = DisplayNameResolver.resolve(
            filename: "doc.md", data: Data(md.utf8),
            mimeType: nil, zoteroItemTitle: nil)
        #expect(result == "Single Quoted Title")
    }

    @Test func displayNameFromMarkdownFrontMatterUnquoted() {
        let md = """
        ---
        title: Plain Title
        author: Someone
        ---
        """
        let result = DisplayNameResolver.resolve(
            filename: "page.md", data: Data(md.utf8),
            mimeType: nil, zoteroItemTitle: nil)
        #expect(result == "Plain Title")
    }

    @Test func displayNameFromMarkdownH1WithoutFrontMatter() {
        let md = "# Just a heading\n\nSome content."
        let result = DisplayNameResolver.resolve(
            filename: "plain.md", data: Data(md.utf8),
            mimeType: nil, zoteroItemTitle: nil)
        #expect(result == "Just a heading")
    }

    @Test func displayNameFromMarkdownH1WithLeadingBlankLines() {
        let md = "\n\n\n# Heading After Blanks\n\nBody."
        let result = DisplayNameResolver.resolve(
            filename: "plain.md", data: Data(md.utf8),
            mimeType: nil, zoteroItemTitle: nil)
        #expect(result == "Heading After Blanks")
    }

    @Test func displayNameFromMarkdownH1WhenFrontMatterHasNoTitle() {
        let md = """
        ---
        author: Someone
        ---
        # Fallback Heading
        """
        let result = DisplayNameResolver.resolve(
            filename: "page.md", data: Data(md.utf8),
            mimeType: nil, zoteroItemTitle: nil)
        #expect(result == "Fallback Heading")
    }

    @Test func displayNameNilForMarkdownH2Only() {
        let md = "## Not An H1\n\nSome content."
        let result = DisplayNameResolver.resolve(
            filename: "plain.md", data: Data(md.utf8),
            mimeType: nil, zoteroItemTitle: nil)
        #expect(result == nil)
    }

    @Test func displayNameFromMarkdownH1WithInlineFormatting() {
        let md = "# `Code` in a Title\n\nBody."
        let result = DisplayNameResolver.resolve(
            filename: "plain.md", data: Data(md.utf8),
            mimeType: nil, zoteroItemTitle: nil)
        #expect(result == "`Code` in a Title")
    }

    @Test func displayNameFromMarkdownMimeTypeNotExtension() {
        let md = """
        ---
        title: "From MIME"
        ---
        """
        let result = DisplayNameResolver.resolve(
            filename: "file.txt", data: Data(md.utf8),
            mimeType: "text/markdown", zoteroItemTitle: nil)
        #expect(result == "From MIME")
    }

    @Test func displayNameFromPDFTitle() throws {
        // Core no longer links PDFKit (it would pull AppKit into the File
        // Provider extension). Install the app-only extractor so this test
        // exercises the real PDF-title path, then restore the nil default.
        DisplayNameResolver.pdfTitleExtractor = PDFTitleExtractor.extract
        defer { DisplayNameResolver.pdfTitleExtractor = { _ in nil } }

        // Build a minimal valid PDF with a /Title entry.
        let title = "My PDF Document"
        let pdfData = try minimalPDF(title: title)
        let result = DisplayNameResolver.resolve(
            filename: "report.pdf", data: pdfData,
            mimeType: "application/pdf", zoteroItemTitle: nil)
        #expect(result == "My PDF Document")
    }

    @Test func displayNameNilForInvalidPDF() {
        let result = DisplayNameResolver.resolve(
            filename: "corrupt.pdf", data: Data("not a pdf".utf8),
            mimeType: "application/pdf", zoteroItemTitle: nil)
        #expect(result == nil)
    }

    @Test func displayNameNilForPDFWithoutTitle() throws {
        // Minimal PDF with no /Title entry.
        let pdfData = try minimalPDF()
        let result = DisplayNameResolver.resolve(
            filename: "untitled.pdf", data: pdfData,
            mimeType: nil, zoteroItemTitle: nil)
        #expect(result == nil)
    }

    @Test func displayNameNilForPlainTextFile() {
        let result = DisplayNameResolver.resolve(
            filename: "readme.txt", data: Data("Hello".utf8),
            mimeType: "text/plain", zoteroItemTitle: nil)
        #expect(result == nil)
    }

    @Test func zoteroTitleTakesPriorityOverPDFTitle() throws {
        let pdfData = try minimalPDF(title: "PDF Title")
        let result = DisplayNameResolver.resolve(
            filename: "doc.pdf", data: pdfData,
            mimeType: "application/pdf",
            zoteroItemTitle: "Zotero Title")
        #expect(result == "Zotero Title")
    }

    @Test func zoteroTitleTakesPriorityOverMarkdownTitle() {
        let md = """
        ---
        title: "MD Title"
        ---
        """
        let result = DisplayNameResolver.resolve(
            filename: "note.md", data: Data(md.utf8),
            mimeType: "text/markdown",
            zoteroItemTitle: "Zotero Title")
        #expect(result == "Zotero Title")
    }

    // MARK: - resolvedDisplayName bypass (issue #229)

    @Test func resolvedDisplayNameBypassesInMethodResolve() throws {
        // PDF data WITH a /Title — DisplayNameResolver.resolve would return
        // "My PDF Document" if called. Passing resolvedDisplayName: .some("Pre")
        // must bypass that entirely and use the pre-resolved value.
        let pdfData = try minimalPDF(title: "My PDF Document")
        let store = try tempStore()
        let summary = try store.addSource(
            filename: "report.pdf", data: pdfData,
            zoteroItemKey: nil, zoteroItemTitle: nil,
            mimeType: "application/pdf", provenance: nil, role: .primary,
            originalPath: nil, activityID: nil,
            resolvedDisplayName: .some("Pre-Resolved Title"))
        #expect(summary.displayName == "Pre-Resolved Title")
    }

    @Test func resolvedDisplayNameNilBypassSkipsResolve() throws {
        // PDF data WITH a /Title, but caller passes .some(nil) → store must
        // NOT call DisplayNameResolver.resolve (which would return "My PDF
        // Document"); it uses nil → display_name stays NULL (filename fallback).
        let pdfData = try minimalPDF(title: "My PDF Document")
        let store = try tempStore()
        let summary = try store.addSource(
            filename: "report.pdf", data: pdfData,
            zoteroItemKey: nil, zoteroItemTitle: nil,
            mimeType: "application/pdf", provenance: nil, role: .primary,
            originalPath: nil, activityID: nil,
            resolvedDisplayName: .some(nil))
        #expect(summary.displayName == nil)
    }

    @Test func resolvedDisplayNameDefaultsToInMethodResolve() throws {
        // resolvedDisplayName: nil (default) → resolve in-method as before.
        let md = "# Inline Title\nbody"
        let store = try tempStore()
        let summary = try store.addSource(
            filename: "note.md", data: Data(md.utf8),
            zoteroItemKey: nil, zoteroItemTitle: nil,
            mimeType: nil, provenance: nil, role: .primary,
            originalPath: nil, activityID: nil)
        #expect(summary.displayName == "Inline Title")
    }

    // MARK: - DisplayNameResolver helpers

    /// Build a minimal valid PDF with an optional /Title in the Info dict,
    /// using CoreGraphics to produce a structurally correct PDF that PDFKit
    /// can parse.
    private func minimalPDF(title: String? = nil) throws -> Data {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData)
        else { throw NSError(domain: "test", code: 1) }
        var mediaBox = CGRect(origin: .zero, size: CGSize(width: 612, height: 792))

        var auxInfo: [String: Any] = [:]
        auxInfo[kCGPDFContextTitle as String] = title as Any?

        guard let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, auxInfo as CFDictionary) else {
            throw NSError(domain: "test", code: 2)
        }
        ctx.beginPDFPage(nil)
        ctx.endPDFPage()
        ctx.closePDF()

        return data as Data
    }
}
