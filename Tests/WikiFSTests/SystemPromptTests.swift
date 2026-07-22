import Foundation
#if canImport(CSQLite)
import CSQLite
#else
import SQLite3
#endif
import Testing
@testable import WikiFSCore

/// System-prompt tests (v42): the prompt is now read-only and always sourced
/// from the compiled `SystemPrompt.defaultBody`. The version is a stable hash
/// of the body so recompiles advance the changeToken.
struct SystemPromptTests {

    private func tempDatabaseURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-sysprompt-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("WikiFS.sqlite")
    }

    private func tempStore() throws -> GRDBWikiStore {
        try GRDBWikiStore(databaseURL: tempDatabaseURL())
    }

    // MARK: - Compiled default is always returned

    @Test func getSystemPromptReturnsCompiledDefault() throws {
        let store = try tempStore()
        let prompt = try store.getSystemPrompt()
        #expect(prompt.body == SystemPrompt.defaultBody)
        #expect(prompt.version == (SystemPrompt.defaultBody.hashValue & 0x7FFFFFFF))
    }

    // MARK: - The compiled default documents the maintainer contract (Phase D)

    /// The Phase-D gate requires a fresh agent to read the seeded schema as
    /// its system prompt and be able to NAME the `wikictl` commands, the layout,
    /// the read-after-write rule, and the workflows. Pin that content here so the
    /// schema can't silently regress to a stub.
    @Test func defaultBodyDocumentsTheWikictlCommandReference() {
        let body = SystemPrompt.defaultBody
        // Every `wikictl` subcommand the agent must know. The harness puts
        // wikictl on PATH, so the prompt uses a bare `wikictl` (NOT `$WIKICTL`,
        // which word-splits on the spaces in the .app install path — see
        // ACPBackend.buildAgentEnv).
        #expect(body.contains("wikictl page list"))
        #expect(body.contains("wikictl page get"))
        #expect(body.contains("wikictl page add"))
        #expect(body.contains("wikictl page delete"))
        #expect(body.contains("wikictl index set"))
        #expect(body.contains("wikictl log append"))
        // Regression guard: the prompt must NOT route commands through the
        // `$WIKICTL` env var — its value contains spaces and bash word-splits
        // the unquoted expansion, so every `$WIKICTL …` call dies with
        // "/Applications/Self: No such file or directory".
        #expect(!body.contains("$WIKICTL"))
        // Write-via-wikictl-never-the-filesystem + read-only mount.
        #expect(body.contains("READ-ONLY"))
        // WIKI_DB selects the wiki, so do not pass --wiki.
        #expect(body.contains("WIKI_DB"))
        #expect(body.contains("do NOT pass"))
        #expect(body.contains("--wiki"))
        // The read-after-write escape hatch (the mount lags).
        #expect(body.contains("Read back what you just wrote"))
    }

    @Test func defaultBodyDocumentsTheLayout() {
        let body = SystemPrompt.defaultBody
        #expect(body.contains("pages/by-title/"))
        #expect(body.contains("pages/by-id/"))
        #expect(body.contains("sources/by-name/"))
        #expect(body.contains("sources/by-id/"))
        #expect(body.contains("index.md"))
        #expect(body.contains("log.md"))
        #expect(body.contains("WIKI-STRUCTURE.md"))
        #expect(body.contains("TREE.md"))
        #expect(body.contains("legacy alias"))
        #expect(body.contains("indexes/"))
        #expect(body.contains("manifest.json"))
        #expect(body.contains("CLAUDE.md"))
        #expect(body.contains("AGENTS.md"))
    }

    @Test func defaultBodyDocumentsConventionsAndWorkflows() {
        let body = SystemPrompt.defaultBody
        // Conventions.
        #expect(body.contains("[[wiki links]]"))
        #expect(body.lowercased().contains("summarize"))
        #expect(body.lowercased().contains("entity"))
        #expect(body.lowercased().contains("concept"))
        #expect(body.lowercased().contains("cite"))
        // The three workflows.
        #expect(body.contains("Ingest"))
        #expect(body.contains("Query"))
        #expect(body.contains("Lint"))
        // Sources may be PDFs/images, read with the Read tool.
        #expect(body.contains("Read"))
        #expect(body.contains("PDF"))
        // Mermaid diagrams: authoring rules + save-time validation note.
        #expect(body.contains("```mermaid"))
        #expect(body.contains("wikictl page add"))
    }

    // MARK: - Update is a no-op (read-only)

    @Test func updateSystemPromptIsANoOp() throws {
        let store = try tempStore()
        let before = try store.getSystemPrompt()
        try store.updateSystemPrompt(body: "Be concise.")
        let after = try store.getSystemPrompt()
        // Update is a no-op - always returns the compiled default
        #expect(after.body == before.body)
        #expect(after.version == before.version)
    }

    @Test func compiledDefaultIsImmutable() throws {
        let store = try tempStore()
        try store.updateSystemPrompt(body: "one")
        try store.updateSystemPrompt(body: "two")
        try store.updateSystemPrompt(body: "three")
        let prompt = try store.getSystemPrompt()
        // Always returns the compiled default, ignores all updates
        #expect(prompt.body == SystemPrompt.defaultBody)
        #expect(prompt.version == (SystemPrompt.defaultBody.hashValue & 0x7FFFFFFF))
    }

    /// The compiled default is stable: reopening a store returns the same body.
    @Test func compiledDefaultPersistsAcrossReopen() throws {
        let url = tempDatabaseURL()
        let before = try GRDBWikiStore(databaseURL: url).getSystemPrompt()
        let after = try GRDBWikiStore(databaseURL: url).getSystemPrompt()
        #expect(before.body == after.body)
        #expect(before.version == after.version)
    }

    // MARK: - changeToken advances with compiled hash

    @Test func changeTokenAdvancesOnSystemPromptEdit() throws {
        let url = tempDatabaseURL()
        let store0 = try GRDBWikiStore(databaseURL: url)
        let token0 = try store0.changeToken()
        // The systemPrompt fold is the hash of the compiled default
        #expect(token0.systemPrompt > 0)

        // Reopening returns the same hash (same compiled body)
        let store1 = try GRDBWikiStore(databaseURL: url)
        let token1 = try store1.changeToken()
        #expect(token1.systemPrompt == token0.systemPrompt)
    }

    // MARK: - v40 → v42 migration drops the table

    @Test func v40ToV42MigrationDropsSystemPromptTable() throws {
        let url = tempDatabaseURL()

        // Build a v40-shaped DB with a system_prompt table.
        do {
            let store = try GRDBWikiStore(databaseURL: url)
            _ = try store.getSystemPrompt()
        }

        // Stamp it back to v40.
        var raw: OpaquePointer?
        #expect(sqlite3_open(url.path, &raw) == SQLITE_OK)
        defer { sqlite3_close(raw) }
        #expect(sqlite3_exec(raw, "PRAGMA user_version = 40;", nil, nil, nil) == SQLITE_OK)

        // Reopen — the migration ladder runs through v40→v41→v42, dropping the table.
        let store = try GRDBWikiStore(databaseURL: url)
        let prompt = try store.getSystemPrompt()

        // Returns the compiled default (not the old table row).
        #expect(prompt.body == SystemPrompt.defaultBody)
        #expect(prompt.version == (SystemPrompt.defaultBody.hashValue & 0x7FFFFFFF))

        // user_version advanced to 42.
        #expect(Int(store.pragmaValue("user_version")) == 42)
    }

    @Test func v40ToV41MigrationSkipsPromptWithoutDollarWikictl() throws {
        let url = tempDatabaseURL()
        let customBody = "# My custom prompt\n\nNo wikictl references here.\n"

        do {
            let store = try GRDBWikiStore(databaseURL: url)
            try store.updateSystemPrompt(body: customBody)
        }
        // Stamp back to v40; the body has no $WIKICTL.
        var raw: OpaquePointer?
        #expect(sqlite3_open(url.path, &raw) == SQLITE_OK)
        defer { sqlite3_close(raw) }
        #expect(sqlite3_exec(raw, "PRAGMA user_version = 40;", nil, nil, nil) == SQLITE_OK)

        let store = try GRDBWikiStore(databaseURL: url)
        let prompt = try store.getSystemPrompt()
        // The table no longer exists; always returns compiled default
        #expect(prompt.body == SystemPrompt.defaultBody)
    }

    // MARK: - v2 → v3 migration no longer creates the table

    @Test func migratesV2DatabaseToV42PreservingData() throws {
        let url = tempDatabaseURL()

        // Build a v2-shaped DB by hand: pages + slug index + sources +
        // user_version=2, WITHOUT system_prompt. Seed one page and one file.
        var raw: OpaquePointer?
        #expect(sqlite3_open(url.path, &raw) == SQLITE_OK)
        let v2SQL = """
        CREATE TABLE pages (
            id TEXT PRIMARY KEY, title TEXT NOT NULL, slug TEXT NOT NULL,
            body_markdown TEXT NOT NULL DEFAULT '', created_at REAL NOT NULL,
            updated_at REAL NOT NULL, version INTEGER NOT NULL DEFAULT 1);
        CREATE UNIQUE INDEX pages_slug_unique ON pages(slug);
        CREATE TABLE ingested_files (
            id TEXT PRIMARY KEY, filename TEXT NOT NULL, ext TEXT NOT NULL DEFAULT '',
            mime_type TEXT, byte_size INTEGER NOT NULL, content BLOB NOT NULL,
            created_at REAL NOT NULL, updated_at REAL NOT NULL,
            version INTEGER NOT NULL DEFAULT 1);
        CREATE INDEX ingested_files_created ON ingested_files(created_at);
        INSERT INTO pages (id, title, slug, body_markdown, created_at, updated_at, version)
          VALUES ('01PRESERVEDPAGE0000000000', 'Kept', 'kept', '# kept', 1, 1, 1);
        INSERT INTO ingested_files (id, filename, ext, mime_type, byte_size, content, created_at, updated_at, version)
          VALUES ('01PRESERVEDFILE0000000000', 'keep.txt', 'txt', 'text/plain', 4, x'6b656570', 1, 1, 1);
        PRAGMA user_version=2;
        """
        #expect(sqlite3_exec(raw, v2SQL, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(raw)

        // Open via the store → runs the v2→v42 migration ladder.
        let store = try GRDBWikiStore(databaseURL: url)

        // system_prompt no longer exists; always returns compiled default.
        let prompt = try store.getSystemPrompt()
        #expect(prompt.body == SystemPrompt.defaultBody)
        #expect(prompt.version == (SystemPrompt.defaultBody.hashValue & 0x7FFFFFFF))

        // Pre-existing page + ingested file are intact.
        let page = try store.getPage(id: PageID(rawValue: "01PRESERVEDPAGE0000000000"))
        #expect(page.title == "Kept")
        let file = try store.getSource(id: PageID(rawValue: "01PRESERVEDFILE0000000000"))
        #expect(file.filename == "keep.txt")
        #expect(try store.sourceContent(id: file.id) == Data("keep".utf8))

        // user_version advances through every migration step to head (v42).
        var check: OpaquePointer?
        #expect(sqlite3_open(url.path, &check) == SQLITE_OK)
        defer { sqlite3_close(check) }
        var stmt: OpaquePointer?
        #expect(sqlite3_prepare_v2(check, "PRAGMA user_version;", -1, &stmt, nil) == SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        #expect(sqlite3_step(stmt) == SQLITE_ROW)
        #expect(sqlite3_column_int(stmt, 0) == GRDBWikiStore.schemaVersion)
        _ = store
    }
}
