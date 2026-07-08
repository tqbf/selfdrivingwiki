import Foundation
import SQLite3
import Testing
@testable import WikiFSCore
@testable import WikiFS

/// Tests for the v8 `file_markdown_versions` store API: version chain,
/// revert, cascade, source immutability, seeding, and pre-migration fallback.
struct ProcessedMarkdownTests {

    private func tempStore() throws -> SQLiteWikiStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-pm-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try SQLiteWikiStore(databaseURL: dir.appendingPathComponent("WikiFS.sqlite"))
    }

    /// Create an ingested file row so FK constraints are satisfied for version tests.
    @discardableResult
    private func seedSource(in store: SQLiteWikiStore, filename: String = "test.txt",
                                  data: Data = Data("hello".utf8)) throws -> SourceSummary {
        try store.addSource(filename: filename, data: data)
    }

    /// Build a v7 DB by hand (pages + sources + system_prompt + log +
    /// wiki_index + page_embeddings), then open it with SQLiteWikiStore — the
    /// store runs the v7→v8 migration step. Used to verify stepwise upgrade.
    private func tempV7DatabaseURL() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-pm-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("WikiFS.sqlite")

        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }

        func exec(_ sql: String) {
            #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        }

        exec("""
        CREATE TABLE pages (
            id TEXT PRIMARY KEY, title TEXT NOT NULL, body_markdown TEXT NOT NULL DEFAULT '',
            created_at REAL NOT NULL, updated_at REAL NOT NULL, version INTEGER NOT NULL DEFAULT 1
        );
        """)
        exec("""
        CREATE TABLE ingested_files (
            id TEXT PRIMARY KEY, filename TEXT NOT NULL, ext TEXT NOT NULL DEFAULT '',
            mime_type TEXT, byte_size INTEGER NOT NULL, content BLOB NOT NULL,
            created_at REAL NOT NULL, updated_at REAL NOT NULL, version INTEGER NOT NULL DEFAULT 1,
            ingested_at REAL
        );
        """)
        exec("""
        CREATE TABLE system_prompt (
            id INTEGER PRIMARY KEY CHECK (id = 1),
            body_markdown TEXT NOT NULL DEFAULT '',
            updated_at REAL NOT NULL, version INTEGER NOT NULL DEFAULT 1
        );
        """)
        exec("""
        CREATE TABLE log (
            id TEXT PRIMARY KEY, kind TEXT NOT NULL, title TEXT NOT NULL,
            note TEXT, source_file_id TEXT, created_at REAL NOT NULL
        );
        """)
        exec("""
        CREATE TABLE wiki_index (
            id INTEGER PRIMARY KEY CHECK (id = 1),
            body_markdown TEXT NOT NULL DEFAULT '',
            updated_at REAL NOT NULL, version INTEGER NOT NULL DEFAULT 1
        );
        """)
        exec("""
        CREATE TABLE page_embeddings (
            page_id TEXT PRIMARY KEY REFERENCES pages(id) ON DELETE CASCADE,
            embedding BLOB NOT NULL
        );
        """)
        exec("PRAGMA user_version=7;")
        return url
    }

    // MARK: - Migration

    @Test func freshDBHasV8Schema() throws {
        let store = try tempStore()
        #expect(store.pragmaValue("user_version") == "25")
    }

    @Test func v7DBUpgradesToV8PreservingData() throws {
        let url = try tempV7DatabaseURL()
        // Insert a known file into the v7 DB.
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        #expect(sqlite3_exec(db, """
        INSERT INTO ingested_files (id, filename, ext, byte_size, content, created_at, updated_at, version)
        VALUES ('01J00000000000000000000000', 'legacy.txt', 'txt', 5, X'68656C6C6F', 1.0, 1.0, 1);
        """, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)

        // Opening runs v7→v8→…→v15 migration.
        let store = try SQLiteWikiStore(databaseURL: url)
        #expect(store.pragmaValue("user_version") == "25")
        // Pre-existing file is intact.
        let content = try store.sourceContent(
            id: PageID(rawValue: "01J00000000000000000000000"))
        #expect(content == Data("hello".utf8))
    }

    @Test func reopenIsIdempotent() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-pm-reopen-\(UUID().uuidString).sqlite")
        let store = try SQLiteWikiStore(databaseURL: url)
        let file = try store.addSource(filename: "test.md", data: Data("hello".utf8))
        _ = try store.appendProcessedMarkdown(
            sourceID: file.id, content: "v1", origin: "extraction", note: nil)
        // Reopen — must not fail from duplicate DDL.
        let reopened = try SQLiteWikiStore(databaseURL: url)
        let head = try reopened.processedMarkdownHead(sourceID: file.id)
        #expect(head?.content == "v1")
    }

    // MARK: - Version chain

    @Test func v1HasNullParentID() throws {
        let store = try tempStore()
        let file = try seedSource(in: store)
        let v1 = try store.appendProcessedMarkdown(
            sourceID: file.id, content: "first", origin: "extraction", note: nil)
        #expect(v1.parentID == nil)
        #expect(v1.origin == "extraction")
        #expect(v1.content == "first")
    }

    @Test func v2ParentIsV1() throws {
        let store = try tempStore()
        let file = try seedSource(in: store)
        let v1 = try store.appendProcessedMarkdown(
            sourceID: file.id, content: "one", origin: "extraction", note: nil)
        let v2 = try store.appendProcessedMarkdown(
            sourceID: file.id, content: "two", origin: "user", note: nil)
        #expect(v2.parentID == v1.id)
    }

    @Test func headIsLatestVersion() throws {
        let store = try tempStore()
        let file = try seedSource(in: store)
        _ = try store.appendProcessedMarkdown(
            sourceID: file.id, content: "v1", origin: "extraction", note: nil)
        // Tiny sleep guarantees the next ULID has a strictly later timestamp
        // so ORDER BY id DESC picks it up correctly.
        usleep(2000)
        let v2 = try store.appendProcessedMarkdown(
            sourceID: file.id, content: "v2", origin: "user", note: nil)
        let head = try store.processedMarkdownHead(sourceID: file.id)
        #expect(head?.id == v2.id)
        #expect(head?.content == "v2")
    }

    @Test func processedMarkdownHistoryNewestFirst() throws {
        let store = try tempStore()
        let file = try seedSource(in: store)
        let v1 = try store.appendProcessedMarkdown(
            sourceID: file.id, content: "first", origin: "extraction", note: nil)
        usleep(2000)
        let v2 = try store.appendProcessedMarkdown(
            sourceID: file.id, content: "second", origin: "user", note: nil)
        let history = try store.processedMarkdownHistory(sourceID: file.id)
        #expect(history.count == 2)
        #expect(history[0].id == v2.id)  // newest first
        #expect(history[1].id == v1.id)
    }

    @Test func hasProcessedMarkdownReflectsExistence() throws {
        let store = try tempStore()
        let file = try seedSource(in: store)
        #expect(try store.hasProcessedMarkdown(sourceID: file.id) == false)
        _ = try store.appendProcessedMarkdown(
            sourceID: file.id, content: "x", origin: "extraction", note: nil)
        #expect(try store.hasProcessedMarkdown(sourceID: file.id) == true)
    }

    // MARK: - Revert

    @Test func revertAppendsNewVersionWithOldContent() throws {
        let store = try tempStore()
        let file = try seedSource(in: store)
        let v1 = try store.appendProcessedMarkdown(
            sourceID: file.id, content: "original", origin: "extraction", note: nil)
        usleep(2000)
        _ = try store.appendProcessedMarkdown(
            sourceID: file.id, content: "edit", origin: "user", note: nil)
        usleep(2000)
        let v3 = try store.revertProcessedMarkdown(sourceID: file.id, to: v1.id)
        #expect(v3.content == "original")
        #expect(v3.origin == "revert")
        #expect(v3.parentID != nil)  // parent is the previous head
        // v1 is untouched
        let history = try store.processedMarkdownHistory(sourceID: file.id)
        #expect(history[2].content == "original")  // v1 still there
    }

    @Test func headAfterRevertIsNewest() throws {
        let store = try tempStore()
        let file = try seedSource(in: store)
        _ = try store.appendProcessedMarkdown(
            sourceID: file.id, content: "v1", origin: "extraction", note: nil)
        usleep(2000)
        _ = try store.appendProcessedMarkdown(
            sourceID: file.id, content: "v2", origin: "user", note: nil)
        let v1 = try store.processedMarkdownHistory(sourceID: file.id).last!
        usleep(2000)
        let reverted = try store.revertProcessedMarkdown(sourceID: file.id, to: v1.id)
        let head = try store.processedMarkdownHead(sourceID: file.id)
        #expect(head?.id == reverted.id)
    }

    // MARK: - Cascade

    @Test func deleteSourceRemovesVersions() throws {
        let store = try tempStore()
        let ingested = try store.addSource(filename: "doc.md", data: Data("hello".utf8))
        _ = try store.appendProcessedMarkdown(
            sourceID: ingested.id, content: "v1", origin: "extraction", note: nil)
        _ = try store.appendProcessedMarkdown(
            sourceID: ingested.id, content: "v2", origin: "user", note: nil)
        try store.deleteSource(id: ingested.id)
        #expect(try store.hasProcessedMarkdown(sourceID: ingested.id) == false)
    }

    // MARK: - Source immutability

    @Test func sourceBytesUnchangedAfterEdits() throws {
        let store = try tempStore()
        let original = Data([0x00, 0xFF, 0x42])
        let ingested = try store.addSource(filename: "data.bin", data: original)
        _ = try store.appendProcessedMarkdown(
            sourceID: ingested.id, content: "edit 1", origin: "user", note: nil)
        _ = try store.appendProcessedMarkdown(
            sourceID: ingested.id, content: "edit 2", origin: "user", note: nil)
        let content = try store.sourceContent(id: ingested.id)
        #expect(content == original)
    }

    // MARK: - Seeding

    @Test func nativeMdStoredInSourcesDoesNotAutoSeed() throws {
        let store = try tempStore()
        let ingested = try store.addSource(filename: "notes.md", data: Data("# Notes\ncontent".utf8))
        let head = try store.processedMarkdownHead(sourceID: ingested.id)
        // No version yet — lazy seed happens at WikiStoreModel layer, not store.
        #expect(head == nil)
    }

    @Test func appendIsNotIdempotentAppendsAgain() throws {
        let store = try tempStore()
        let file = try seedSource(in: store)
        let v1 = try store.appendProcessedMarkdown(
            sourceID: file.id, content: "first seed", origin: "extraction", note: nil)
        usleep(2000)
        _ = try store.appendProcessedMarkdown(
            sourceID: file.id, content: "second seed", origin: "extraction", note: nil)
        let history = try store.processedMarkdownHistory(sourceID: file.id)
        // Two versions: the second call appended v2 (parent = v1).
        // The "double-seed guard" is at the caller level (WikiStoreModel).
        #expect(history.count == 2)
        #expect(history[1].id == v1.id)
    }

    // MARK: - Pre-migration fallback

    @Test func readSeamsReturnSafeDefaultsForPreV8DB() throws {
        let url = try tempV7DatabaseURL()
        let store = try SQLiteWikiStore(databaseURL: url)
        let arbitraryID = PageID(rawValue: "01J00000000000000000000000")
        // Read seams must return safe defaults (nil / false / []) without
        // crashing even though file_markdown_versions doesn't exist.
        #expect(try store.processedMarkdownHead(sourceID: arbitraryID) == nil)
        #expect(try store.hasProcessedMarkdown(sourceID: arbitraryID) == false)
        #expect(try store.processedMarkdownHistory(sourceID: arbitraryID).isEmpty)
    }

    // MARK: - Bulk head lookup (processedMarkdownHeadsBySource)

    @Test func processedMarkdownHeadsBySourceReturnsHeadsBySourceID() throws {
        let store = try tempStore()
        let fileA = try seedSource(in: store, filename: "alpha.txt", data: Data("alpha".utf8))
        let fileB = try seedSource(in: store, filename: "beta.txt", data: Data("beta".utf8))
        let fileC = try seedSource(in: store, filename: "gamma.txt", data: Data("gamma".utf8)) // no head
        let headA = try store.appendProcessedMarkdown(
            sourceID: fileA.id, content: "alpha head", origin: "extraction", note: nil)
        usleep(2000)
        let headB = try store.appendProcessedMarkdown(
            sourceID: fileB.id, content: "beta head", origin: "extraction", note: nil)
        let heads = try store.processedMarkdownHeadsBySource()
        #expect(heads.count == 2) // fileC has no head
        #expect(heads[fileA.id.rawValue]?.content == "alpha head")
        #expect(heads[fileB.id.rawValue]?.content == "beta head")
        #expect(heads[fileC.id.rawValue] == nil)
        #expect(heads[fileA.id.rawValue]?.id == headA.id)
        #expect(heads[fileB.id.rawValue]?.id == headB.id)
    }

    @Test func processedMarkdownHeadsBySourceReturnsLatestPerSource() throws {
        let store = try tempStore()
        let file = try seedSource(in: store)
        _ = try store.appendProcessedMarkdown(
            sourceID: file.id, content: "v1", origin: "extraction", note: nil)
        usleep(2000)
        let v2 = try store.appendProcessedMarkdown(
            sourceID: file.id, content: "v2", origin: "user", note: nil)
        let heads = try store.processedMarkdownHeadsBySource()
        #expect(heads.count == 1)
        #expect(heads[file.id.rawValue]?.content == "v2")
        #expect(heads[file.id.rawValue]?.id == v2.id)
    }

    @Test func processedMarkdownHeadsBySourceReturnsEmptyForPreV8DB() throws {
        let url = try tempV7DatabaseURL()
        let store = try SQLiteWikiStore(databaseURL: url)
        let heads = try store.processedMarkdownHeadsBySource()
        #expect(heads.isEmpty)
    }

    // MARK: - Model-level: PDF extraction reuse during ingest

    /// For a PDF file, `processedMarkdownHead` returns nil before any markdown is
    /// extracted. `seedPdfMarkdown` creates the first version. This is the
    /// predicate `AgentOperationRunner.runMultiIngest` uses to decide whether to
    /// skip pdf2md — if a head exists, the runner reuses existing markdown instead
    /// of re-extracting.
    @Test @MainActor func pdfHeadNilBeforeExtraction() throws {
        let store = try tempStore()
        let pdf = try store.addSource(filename: "doc.pdf", data: Data("%PDF-1.4".utf8))
        let model = WikiStoreModel(store: store)
        // Before extraction: no head.
        #expect(model.processedMarkdownHead(for: pdf) == nil)
    }

    @Test @MainActor func seedPdfMarkdownCreatesHead() throws {
        let store = try tempStore()
        let pdf = try store.addSource(filename: "doc.pdf", data: Data("%PDF-1.4".utf8))
        let model = WikiStoreModel(store: store)

        // Simulate extraction output: seed the markdown.
        let seeded = model.seedPdfMarkdown(
            for: pdf.id, content: "# Extracted\ncontent", backend: .anthropic)
        #expect(seeded != nil)
        #expect(seeded?.content == "# Extracted\ncontent")

        // Now the head exists — the runner would skip pdf2md.
        let head = model.processedMarkdownHead(for: pdf)
        #expect(head?.content == "# Extracted\ncontent")
    }

    @Test @MainActor func seedPdfMarkdownDoubleSeedReturnsExisting() throws {
        let store = try tempStore()
        let pdf = try store.addSource(filename: "doc.pdf", data: Data("%PDF-1.4".utf8))
        let model = WikiStoreModel(store: store)

        // First seed.
        let v1 = model.seedPdfMarkdown(for: pdf.id, content: "first extract", backend: .anthropic)
        #expect(v1 != nil)
        #expect(v1?.content == "first extract")

        // Second seed: double-seed guard returns the existing head, does NOT
        // append a duplicate version.
        usleep(2000)
        let v2 = model.seedPdfMarkdown(for: pdf.id, content: "should be ignored", backend: .gemini)
        #expect(v2 != nil)
        #expect(v2?.id == v1?.id)
        #expect(v2?.content == "first extract")

        // Head is still the first extract, unchanged.
        let head = model.processedMarkdownHead(for: pdf)
        #expect(head?.id == v1?.id)
        #expect(head?.content == "first extract")
    }

    // MARK: - Phase 2: CAS, provenance, alternatives

    /// AC.1 — Identical extraction content dedups the blob: two smv rows share
    /// one `blob_hash`, and the `blobs` row count does not increase.
    @Test func identicalExtractionDedupsBlob() throws {
        let store = try tempStore()
        let file = try seedSource(in: store)
        let v1 = try store.recordMarkdownExtraction(
            sourceID: file.id, content: "# Same\nbody",
            backend: .anthropic, sourceVersionID: nil, note: nil, modelVersion: nil)
        let blobsBefore = store.scalarText("SELECT COUNT(*) FROM blobs;")
        usleep(2000)
        let v2 = try store.recordMarkdownExtraction(
            sourceID: file.id, content: "# Same\nbody",
            backend: .gemini, sourceVersionID: nil, note: nil, modelVersion: nil)
        let blobsAfter = store.scalarText("SELECT COUNT(*) FROM blobs;")
        #expect(v1.blobHash != nil)
        #expect(v1.blobHash == v2.blobHash)
        #expect(blobsBefore == blobsAfter)
    }

    /// AC.2 — Revert is a pointer copy: the revert row reuses the target's
    /// `blob_hash`, no new blob bytes are stored, and the revert becomes HEAD.
    @Test func revertIsPointerCopy() throws {
        let store = try tempStore()
        let file = try seedSource(in: store)
        let v1 = try store.recordMarkdownExtraction(
            sourceID: file.id, content: "original body",
            backend: .anthropic, sourceVersionID: nil, note: nil, modelVersion: nil)
        usleep(2000)
        _ = try store.appendProcessedMarkdown(
            sourceID: file.id, content: "edited body", origin: "user", note: nil)
        let blobsBefore = store.scalarText("SELECT COUNT(*) FROM blobs;")
        usleep(2000)
        let reverted = try store.revertProcessedMarkdown(sourceID: file.id, to: v1.id)
        let blobsAfter = store.scalarText("SELECT COUNT(*) FROM blobs;")
        #expect(reverted.blobHash == v1.blobHash)
        #expect(blobsBefore == blobsAfter)
        let head = try store.processedMarkdownHead(sourceID: file.id)
        #expect(head?.id == reverted.id)
        #expect(head?.content == "original body")
    }

    /// AC.3 — Two backends' extractions coexist (distinct agents, no clobber).
    @Test func twoBackendsCoexist() throws {
        let store = try tempStore()
        let file = try seedSource(in: store)
        _ = try store.recordMarkdownExtraction(
            sourceID: file.id, content: "claude output",
            backend: .anthropic, sourceVersionID: nil, note: nil, modelVersion: nil)
        usleep(2000)
        _ = try store.recordMarkdownExtraction(
            sourceID: file.id, content: "gemini output",
            backend: .gemini, sourceVersionID: nil, note: nil, modelVersion: nil)
        let history = try store.processedMarkdownHistory(sourceID: file.id)
        #expect(history.count >= 2)
        let names = try store.processedMarkdownAgentNames(sourceID: file.id)
        let agentNames = Set(names.values)
        #expect(agentNames.contains("claude"))
        #expect(agentNames.contains("gemini"))
    }

    /// AC.4 — setActiveMarkdown repoints the source-derived ref, HEAD follows
    /// it, and the changeToken moves.
    @Test func setActiveMarkdownRepointsRefAndMovesToken() throws {
        let store = try tempStore()
        let file = try seedSource(in: store)
        let first = try store.recordMarkdownExtraction(
            sourceID: file.id, content: "first",
            backend: .anthropic, sourceVersionID: nil, note: nil, modelVersion: nil)
        usleep(2000)
        _ = try store.recordMarkdownExtraction(
            sourceID: file.id, content: "second",
            backend: .gemini, sourceVersionID: nil, note: nil, modelVersion: nil)
        // Default-active: HEAD is the latest (second).
        #expect(try store.processedMarkdownHead(sourceID: file.id)?.content == "second")
        let tokenBefore = try store.changeToken()
        try store.setActiveMarkdown(sourceID: file.id, to: first.id)
        let tokenAfter = try store.changeToken()
        #expect(tokenBefore != tokenAfter)
        #expect(try store.processedMarkdownHead(sourceID: file.id)?.id == first.id)
        #expect(try store.processedMarkdownHead(sourceID: file.id)?.content == "first")
    }

    /// AC.6 — Extraction provenance is recoverable: activity→agent resolves to
    /// the backend name, and source_version_id matches the active content version.
    @Test func extractionProvenanceRecoverable() throws {
        let store = try tempStore()
        let pdf = try store.addSource(filename: "doc.pdf", data: Data("%PDF-1.4".utf8))
        let activeVersion = try store.activeContentVersion(sourceID: pdf.id)
        let version = try store.recordMarkdownExtraction(
            sourceID: pdf.id, content: "# extracted",
            backend: .anthropic, sourceVersionID: nil, note: nil, modelVersion: "claude-x")
        // Re-read to get the persisted activity_id.
        let head = try store.processedMarkdownHead(sourceID: pdf.id)
        #expect(head?.id == version.id)
        #expect(head?.sourceVersionID == activeVersion?.id)
        let names = try store.processedMarkdownAgentNames(sourceID: pdf.id)
        #expect(names[version.id.rawValue] == "claude")
    }

    /// AC.8 (unit) — reExtractMarkdown appends a coexisting alternative via the
    /// model using a fake extractor (does not clobber the existing head).
    @Test @MainActor func reExtractCoexists() async throws {
        let store = try tempStore()
        let pdf = try store.addSource(filename: "doc.pdf", data: Data("%PDF-1.4".utf8))
        let model = WikiStoreModel(store: store)
        // First extraction (the active head).
        _ = model.seedPdfMarkdown(for: pdf.id, content: "first extract", backend: .anthropic)
        // Re-extract with a fake backend that returns different markdown.
        let extractor = FakeMarkdownExtractor(output: "second extract")
        let alt = await model.reExtractMarkdown(
            for: pdf.id, filename: "doc.pdf",
            using: extractor, backend: .gemini, modelVersion: nil)
        #expect(alt != nil)
        let history = try store.processedMarkdownHistory(sourceID: pdf.id)
        #expect(history.count >= 2)
        // Both bodies are present in history.
        let bodies = Set(history.map(\.content))
        #expect(bodies.contains("first extract"))
        #expect(bodies.contains("second extract"))
    }

    // MARK: - Track C: alternatives query + provenance + nominate

    /// AC.1/AC.4 — `processedMarkdownAlternatives` returns each alternative with
    /// resolved backend display name, model version, char count, and the active
    /// HEAD flagged; the first extraction is active by the default-active rule.
    @Test func processedMarkdownAlternativesCarriesProvenance() throws {
        let store = try tempStore()
        let file = try seedSource(in: store)
        let first = try store.recordMarkdownExtraction(
            sourceID: file.id, content: "claude body",
            backend: .anthropic, sourceVersionID: nil, note: nil,
            modelVersion: "claude-opus-4-1")
        usleep(2000)
        _ = try store.recordMarkdownExtraction(
            sourceID: file.id, content: "gemini body",
            backend: .gemini, sourceVersionID: nil, note: nil,
            modelVersion: "gemini-2.5-pro")

        let alts = try store.processedMarkdownAlternatives(sourceID: file.id)
        #expect(alts.count == 2)
        // Newest first.
        #expect(alts[0].agentName == "gemini")
        #expect(alts[0].backendDisplayName == "Gemini (Google AI)")
        #expect(alts[0].modelVersion == "gemini-2.5-pro")
        #expect(alts[0].charCount == "gemini body".count)
        #expect(alts[1].backendDisplayName == "Claude (Anthropic API)")
        #expect(alts[1].modelVersion == "claude-opus-4-1")
        // Default-active rule: no ref written yet → MAX(id) is active (the gemini row).
        #expect(alts[0].isActive)
        #expect(!alts[1].isActive)
        // The resolved body is carried (not the empty CAS column).
        #expect(alts[1].version.content == "claude body")
        #expect(first.blobHash != nil)
    }

    /// AC.4 — legacy/unknown agents resolve to a graceful label, not a crash.
    @Test func alternativeBackendDisplayFallbacks() {
        #expect(ExtractionAlternative.backendDisplayName(agentName: "claude")
               == "Claude (Anthropic API)")
        #expect(ExtractionAlternative.backendDisplayName(agentName: "pdf2md")
               == "Local pdf2md")
        #expect(ExtractionAlternative.backendDisplayName(agentName: "legacy-extraction")
               == "Legacy")
        #expect(ExtractionAlternative.backendDisplayName(agentName: "future-tool")
               == "Future-tool")
    }

    /// AC.4 — `ExtractionBackend.from(agentName:)` round-trip incl. nil cases.
    @Test func extractionBackendFromAgentName() {
        #expect(ExtractionBackend.from(agentName: "claude") == .anthropic)
        #expect(ExtractionBackend.from(agentName: "gemini") == .gemini)
        #expect(ExtractionBackend.from(agentName: "pdf2md") == .localPdf2md)
        #expect(ExtractionBackend.from(agentName: "docling-serve") == .doclingServe)
        #expect(ExtractionBackend.from(agentName: "legacy-extraction") == nil)
        #expect(ExtractionBackend.from(agentName: "nope") == nil)
    }

    /// AC.3 — after `setActiveMarkdown`, `processedMarkdownAlternatives` reports
    /// the nominated row as active (the badge the sheet reads live).
    @Test func setActiveUpdatesAlternativeBadge() throws {
        let store = try tempStore()
        let file = try seedSource(in: store)
        let first = try store.recordMarkdownExtraction(
            sourceID: file.id, content: "first",
            backend: .anthropic, sourceVersionID: nil, note: nil, modelVersion: nil)
        usleep(2000)
        _ = try store.recordMarkdownExtraction(
            sourceID: file.id, content: "second",
            backend: .gemini, sourceVersionID: nil, note: nil, modelVersion: nil)

        // Nominate the OLDER (first) row as active.
        try store.setActiveMarkdown(sourceID: file.id, to: first.id)
        let alts = try store.processedMarkdownAlternatives(sourceID: file.id)
        let active = alts.first { $0.isActive }
        #expect(active?.id == first.id)
        #expect(active?.backendDisplayName == "Claude (Anthropic API)")
    }
}

/// Pure unit tests for the line-diff used by the compare sheet's Diff mode.
struct MarkdownDiffTests {
    @Test func identicalBodiesAreAllEqual() {
        let d = MarkdownDiff.lineDiff("a\nb\nc", "a\nb\nc")
        #expect(d.count == 3)
        #expect(d.allSatisfy { $0.kind == .equal })
    }

    @Test func pureAddition() {
        let d = MarkdownDiff.lineDiff("a\nc", "a\nb\nc")
        // 'a' equal, 'b' added, 'c' equal.
        #expect(d.count == 3)
        #expect(d[0].kind == .equal && d[0].text == "a")
        #expect(d[1].kind == .added && d[1].text == "b")
        #expect(d[2].kind == .equal && d[2].text == "c")
    }

    @Test func pureRemoval() {
        let d = MarkdownDiff.lineDiff("a\nb\nc", "a\nc")
        #expect(d.count == 3)
        #expect(d[1].kind == .removed && d[1].text == "b")
    }

    @Test func replacementGroupsRemovalsBeforeAdditions() {
        let d = MarkdownDiff.lineDiff("x", "y")
        // Single replacement: removed 'x' then added 'y'.
        #expect(d.count == 2)
        #expect(d[0] == DiffLine(kind: .removed, text: "x"))
        #expect(d[1] == DiffLine(kind: .added, text: "y"))
    }

    @Test func emptyInputs() {
        #expect(MarkdownDiff.lineDiff("", "").isEmpty)
        let fromEmpty = MarkdownDiff.lineDiff("", "a\nb")
        #expect(fromEmpty.count == 2)
        #expect(fromEmpty.allSatisfy { $0.kind == .added })
        let toEmpty = MarkdownDiff.lineDiff("a\nb", "")
        #expect(toEmpty.allSatisfy { $0.kind == .removed })
    }

    @Test func handlesTrailingNewline() {
        // No spurious empty trailing line from a terminating newline.
        let d = MarkdownDiff.lineDiff("a\n", "a\n")
        #expect(d.count == 1)
        #expect(d[0].text == "a")
    }

    /// Above the DP cap, the diff degrades to all-removed-then-all-added (the
    /// safety valve that keeps the UI responsive on huge bodies). Correct, just
    /// non-minimal.
    @Test func degradesAboveCellCap() {
        // (n+1)*(m+1) must exceed maxCells (4_000_000): 2003*2003 ≈ 4.01M.
        let n = 2002
        let left = (0..<n).map { "L\($0)" }.joined(separator: "\n")
        let right = (0..<n).map { "R\($0)" }.joined(separator: "\n")
        let d = MarkdownDiff.lineDiff(left, right)
        #expect(d.count == n * 2)
        #expect(d.prefix(n).allSatisfy { $0.kind == .removed })
        #expect(d.suffix(n).allSatisfy { $0.kind == .added })
    }
}

/// Pure unit tests for the split (two-column) alignment used by Diff mode.
struct SplitDiffTests {
    private func rows(_ l: String, _ r: String) -> [SplitRow] {
        SplitDiff.rows(from: MarkdownDiff.lineDiff(l, r))
    }

    @Test func equalRowsCarryBothSidesAndNumbers() {
        let rs = rows("a\nb", "a\nb")
        #expect(rs.count == 2)
        #expect(rs[0].left == SplitCell(number: 1, text: "a", kind: .equal))
        #expect(rs[0].right == SplitCell(number: 1, text: "a", kind: .equal))
        #expect(rs[1].left?.number == 2 && rs[1].right?.number == 2)
        #expect(rs.allSatisfy { !$0.isChange })
    }

    @Test func additionIsRightOnly() {
        let rs = rows("a\nc", "a\nb\nc")
        // a=equal, b=added(right-only), c=equal
        #expect(rs.count == 3)
        #expect(rs[1].left == nil)
        #expect(rs[1].right == SplitCell(number: 2, text: "b", kind: .added))
        #expect(rs[2].left?.number == 2)   // left line count skips the addition
        #expect(rs[2].right?.number == 3)
    }

    @Test func removalIsLeftOnly() {
        let rs = rows("a\nb\nc", "a\nc")
        #expect(rs[1].left == SplitCell(number: 2, text: "b", kind: .removed))
        #expect(rs[1].right == nil)
    }

    @Test func replacementPairsRemovedWithAddedOnSameRow() {
        let rs = rows("x", "y")
        #expect(rs.count == 1)
        #expect(rs[0].left == SplitCell(number: 1, text: "x", kind: .removed))
        #expect(rs[0].right == SplitCell(number: 1, text: "y", kind: .added))
        #expect(rs[0].isChange)
    }

    @Test func unequalRunPairsThenSpills() {
        // 3 removed, 5 added → 3 paired rows, then 2 right-only rows.
        let left = "r1\nr2\nr3"
        let right = "a1\na2\na3\na4\na5"
        let rs = rows(left, right)
        #expect(rs.count == 5)
        #expect(rs.prefix(3).allSatisfy { $0.left != nil && $0.right != nil })
        #expect(rs[3].left == nil && rs[3].right?.text == "a4")
        #expect(rs[4].left == nil && rs[4].right?.text == "a5")
        // Right numbering stays contiguous 1...5.
        #expect(rs.compactMap { $0.right?.number } == [1, 2, 3, 4, 5])
    }

    @Test func collapseHidesLongUnchangedRuns() {
        // 20 equal lines with a single change at the end.
        let base = (0..<20).map { "line\($0)" }.joined(separator: "\n")
        let els = SplitDiff.elements(from: rows(base, base + "\nchanged"),
                                     context: 3, threshold: 4)
        let collapsed = els.compactMap { if case .collapsed(let r) = $0 { return r } else { return nil } }
        #expect(collapsed.count == 1)
        // Only a leading run before the change → context kept at the tail (3),
        // none at the document start.
        let visibleRows = els.filter { if case .row = $0 { return true } else { return false } }
        #expect(visibleRows.count < 21)   // most of the equal run is hidden
    }

    @Test func shortUnchangedRunsAreNotCollapsed() {
        let els = SplitDiff.elements(from: rows("a\nb\nc", "a\nb\nc"),
                                     context: 3, threshold: 4)
        #expect(els.allSatisfy { if case .row = $0 { return true } else { return false } })
    }

    @Test func hunkAnchorsMarkStartsOfChangeBlocks() {
        // equal, change, equal, equal, change → 2 anchors.
        let rs = rows("a\nX\nc\nd\nY", "a\nX2\nc\nd\nY2")
        let anchors = SplitDiff.hunkAnchors(from: rs)
        #expect(anchors.count == 2)
    }
}

/// A trivial `MarkdownExtractor` used by tests: always ready, returns fixed
/// markdown. Conforms to Sendable for use across actor boundaries.
private struct FakeMarkdownExtractor: MarkdownExtractor {
    let output: String
    var displayName: String { "Fake" }
    func readiness() async -> ExtractionReadiness { .ready }
    func convert(pdfData: Data, filename: String,
                 onProgress: (@Sendable (String) -> Void)?) async throws -> String {
        output
    }
}
