import Foundation
import SQLite3
import Testing
@testable import WikiFSCore

/// System-prompt singleton tests (v3): the document is seeded on a fresh DB,
/// edits bump the version and advance the change token (so the projected
/// `CLAUDE.md`/`AGENTS.md` refresh), and the v2→3 migration adds + seeds the
/// table while preserving existing pages and ingested files.
struct SystemPromptTests {

    private func tempDatabaseURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-sysprompt-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("WikiFS.sqlite")
    }

    private func tempStore() throws -> SQLiteWikiStore {
        try SQLiteWikiStore(databaseURL: tempDatabaseURL())
    }

    // MARK: - Seeded default on a fresh DB

    @Test func freshDatabaseSeedsDefaultPrompt() throws {
        let store = try tempStore()
        let prompt = try store.getSystemPrompt()
        #expect(prompt.body == SystemPrompt.defaultBody)
        #expect(prompt.version == 1)
    }

    // MARK: - The seeded schema documents the maintainer contract (Phase D)

    /// The Phase-D gate requires a fresh agent to read the seeded schema as
    /// its system prompt and be able to NAME the `wikictl` commands, the layout,
    /// the read-after-write rule, and the workflows. Pin that content here so the
    /// schema can't silently regress to a stub.
    @Test func defaultBodyDocumentsTheWikictlCommandReference() {
        let body = SystemPrompt.defaultBody
        // Every `wikictl` subcommand the agent must know — invoked via $WIKICTL so
        // resolution does not depend on the agent's shell preserving PATH.
        #expect(body.contains("$WIKICTL page list"))
        #expect(body.contains("$WIKICTL page get"))
        #expect(body.contains("$WIKICTL page upsert"))
        #expect(body.contains("$WIKICTL page delete"))
        #expect(body.contains("$WIKICTL index set"))
        #expect(body.contains("$WIKICTL log append"))
        // $WIKICTL holds wikictl's absolute path (PATH-independent resolution).
        #expect(body.contains("$WIKICTL"))
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
        #expect(body.contains("$WIKICTL page upsert"))
    }

    // MARK: - Update persists + bumps version

    @Test func updatePersistsBodyAndBumpsVersion() throws {
        let url = tempDatabaseURL()
        do {
            let store = try SQLiteWikiStore(databaseURL: url)
            try store.updateSystemPrompt(body: "Be concise.")
            let after = try store.getSystemPrompt()
            #expect(after.body == "Be concise.")
            #expect(after.version == 2)   // seeded at 1, +1 on edit
        }
        // Persists across reopen (a new connection).
        let reopened = try SQLiteWikiStore(databaseURL: url)
        let prompt = try reopened.getSystemPrompt()
        #expect(prompt.body == "Be concise.")
        #expect(prompt.version == 2)
    }

    @Test func repeatedEditsKeepBumpingVersion() throws {
        let store = try tempStore()
        try store.updateSystemPrompt(body: "one")
        try store.updateSystemPrompt(body: "two")
        try store.updateSystemPrompt(body: "three")
        let prompt = try store.getSystemPrompt()
        #expect(prompt.body == "three")
        #expect(prompt.version == 4)   // 1 (seed) + 3 edits
    }

    /// Phase-D migration invariant: changing the `defaultBody` constant seeds NEW
    /// wikis with the new schema but must NEVER rewrite an EXISTING wiki's row. A
    /// pre-existing body (e.g. the prior schema, or a user's co-evolved version)
    /// rides through reopen untouched — the seed runs only when the table is first
    /// created, never on a subsequent open.
    @Test func existingSystemPromptRowIsNotOverwrittenOnReopen() throws {
        let url = tempDatabaseURL()
        // First open seeds the row with the current defaultBody.
        do {
            let store = try SQLiteWikiStore(databaseURL: url)
            #expect(try store.getSystemPrompt().body == SystemPrompt.defaultBody)
        }
        // Simulate a wiki carrying a DIFFERENT body than today's default (an older
        // seed, or the user's edits).
        let preExisting = "# My co-evolved schema\n\nDo not clobber me.\n"
        do {
            let store = try SQLiteWikiStore(databaseURL: url)
            try store.updateSystemPrompt(body: preExisting)
        }
        // Reopening must NOT reset it back to defaultBody — the seed is create-only.
        let reopened = try SQLiteWikiStore(databaseURL: url)
        let prompt = try reopened.getSystemPrompt()
        #expect(prompt.body == preExisting)
        #expect(prompt.body != SystemPrompt.defaultBody)
    }

    // MARK: - Change token advances on a prompt-only edit

    @Test func changeTokenAdvancesOnSystemPromptEdit() throws {
        let store = try tempStore()
        // No pages, no sources: only the system-prompt version moves.
        let token0 = try store.changeToken()
        #expect(token0.pages == .init(count: 0, versionSum: 0))
        #expect(token0.sourceTable == .init(count: 0, versionSum: 0))
        #expect(token0.systemPrompt == 1)
        #expect(token0.log == 0)
        #expect(token0.wikiIndex == 1)
        #expect(token0.sourceMarkdownVersions == 0)
        #expect(token0.sourceGraph == .init())
        #expect(token0.bookmarks == 0)
        #expect(token0.chat == .init())
        try store.updateSystemPrompt(body: "edited")
        let token1 = try store.changeToken()
        #expect(token1.systemPrompt == 2)
        // No other fold moved.
        #expect(token1.pages == token0.pages)
        #expect(token1.sourceTable == token0.sourceTable)
        #expect(token1.log == token0.log)
        #expect(token1.wikiIndex == token0.wikiIndex)
        #expect(token1.sourceMarkdownVersions == token0.sourceMarkdownVersions)
        #expect(token1.sourceGraph == token0.sourceGraph)
        #expect(token1.bookmarks == token0.bookmarks)
        #expect(token1.chat == token0.chat)
    }

    // MARK: - UPSERT recreates a missing singleton row (defensive)

    @Test func updateRecreatesRowIfDeleted() throws {
        let url = tempDatabaseURL()
        let store = try SQLiteWikiStore(databaseURL: url)

        // Hard-delete the seeded row via a raw connection.
        var raw: OpaquePointer?
        #expect(sqlite3_open(url.path, &raw) == SQLITE_OK)
        #expect(sqlite3_exec(raw, "DELETE FROM system_prompt;", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(raw)

        // With no row, getSystemPrompt falls back to the default (version 0).
        #expect(try store.getSystemPrompt().version == 0)

        // UPSERT recreates it at version 1.
        try store.updateSystemPrompt(body: "rebuilt")
        let prompt = try store.getSystemPrompt()
        #expect(prompt.body == "rebuilt")
        #expect(prompt.version == 1)
    }

    // MARK: - v2 → v3 migration (table added + seeded, data preserved)

    @Test func migratesV2DatabaseToV3PreservingData() throws {
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

        // Open via the store → runs the v2→3 step (and the later v3→4 + v4→5
        // steps up to head).
        let store = try SQLiteWikiStore(databaseURL: url)

        // system_prompt now exists, seeded with the default.
        let prompt = try store.getSystemPrompt()
        #expect(prompt.body == SystemPrompt.defaultBody)
        #expect(prompt.version == 1)

        // Pre-existing page + ingested file are intact.
        let page = try store.getPage(id: PageID(rawValue: "01PRESERVEDPAGE0000000000"))
        #expect(page.title == "Kept")
        let file = try store.getSource(id: PageID(rawValue: "01PRESERVEDFILE0000000000"))
        #expect(file.filename == "keep.txt")
        #expect(try store.sourceContent(id: file.id) == Data("keep".utf8))

        // user_version advances through every migration step to head (v9).
        var check: OpaquePointer?
        #expect(sqlite3_open(url.path, &check) == SQLITE_OK)
        defer { sqlite3_close(check) }
        var stmt: OpaquePointer?
        #expect(sqlite3_prepare_v2(check, "PRAGMA user_version;", -1, &stmt, nil) == SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        #expect(sqlite3_step(stmt) == SQLITE_ROW)
        #expect(sqlite3_column_int(stmt, 0) == SQLiteWikiStore.currentSchemaVersion)
        _ = store
    }
}
