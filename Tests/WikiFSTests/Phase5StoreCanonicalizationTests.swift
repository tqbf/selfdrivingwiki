import Foundation
#if canImport(CSQLite)
import CSQLite
#else
import SQLite3
#endif
import Testing
@testable import WikiFSCore

/// Integration tests for Phase 5 link canonicalization against a temp-DB store.
/// Covers: save-time canonicalization through the shared `PageUpsert` seam
/// (AC.1), forward links left verbatim (AC.3), the v22→v23 body migration
/// (AC.8), page-rename self-heals at render with zero body writes (AC.6),
/// source-rename self-heals (AC.9), and the ULID-shaped-title collision
/// fallback (5.1.4).
struct Phase5StoreCanonicalizationTests {

    private func tempDatabaseURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-p5-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("WikiFS.sqlite")
    }

    // MARK: - AC.1 — save canonicalizes (the shared PageUpsert seam)

    @Test func upsertCanonicalizesPageAndSourceLinks() throws {
        let store = try GRDBWikiStore(databaseURL: tempDatabaseURL())
        // Create the targets first so the link resolvers find them.
        let target = try PageUpsert.upsert(in: store, id: nil, title: "Some Page", body: "")
        let source = try store.addSource(filename: "a-paper.pdf", data: Data("%PDF".utf8))
        try store.renameSource(id: source.id, to: "A Paper")

        // Now save a page whose body uses human titles — both should canonicalize.
        let outcome = try PageUpsert.upsert(in: store, id: nil, title: "Linker",
            body: "See [[Some Page]] and [[source:A Paper]].")

        let stored = try store.getPage(id: outcome.id)
        #expect(stored.bodyMarkdown.contains("[[page:\(target.id.rawValue)|Some Page]]"))
        #expect(stored.bodyMarkdown.contains("[[source:\(source.id.rawValue)|A Paper]]"))
        #expect(!stored.bodyMarkdown.contains("[[Some Page]]"))
        #expect(!stored.bodyMarkdown.contains("[[source:A Paper]]"))

        // Link rows exist (validate-by-id resolved the canonical targets).
        let pageLinks = try store.listAllLinks().filter { $0.from == outcome.id.rawValue }
        #expect(pageLinks.contains { $0.to == target.id.rawValue })
        let sourceLinks = try store.listAllSourceLinks().filter { $0.from == outcome.id.rawValue }
        #expect(sourceLinks.contains { $0.to == source.id.rawValue })
    }

    // MARK: - AC.3 — forward link stored verbatim, no edge

    @Test func unresolvedForwardLinkStoredVerbatim() throws {
        let store = try GRDBWikiStore(databaseURL: tempDatabaseURL())
        let outcome = try PageUpsert.upsert(in: store, id: nil, title: "Page",
            body: "Link to [[No Such Page]] here.")

        let stored = try store.getPage(id: outcome.id)
        #expect(stored.bodyMarkdown == "Link to [[No Such Page]] here.")
        // No page_links row for the unresolved target.
        let links = try store.listAllLinks().filter { $0.from == outcome.id.rawValue }
        #expect(links.isEmpty)
    }

    // MARK: - 5.1.4 — ULID-shaped title resolves by name (collision fallback)

    @Test func ulidShapedTitleResolvesByNameFallback() throws {
        let store = try GRDBWikiStore(databaseURL: tempDatabaseURL())
        // A page whose TITLE is a valid 26-char Crockford string. After
        // canonicalization, a link to it is `[[page:ULID|ULID]]`. The validate-
        // -by-id path finds no row by that id (it's a title, not an id), so it
        // must fall back to name resolution so the edge isn't dropped.
        let ulidTitle = "01H0ABCDEFGHJKMNPQRSTVWXYZ"  // 26 valid Crockford chars
        let target = try PageUpsert.upsert(in: store, id: nil, title: ulidTitle, body: "")

        // Save a linker via the raw path (bypass canonicalization) with the
        // ULID-title as a plain wiki link, then replaceLinks by name.
        let linker = try store.createPage(title: "Linker")
        try store.updatePage(id: linker.id, title: "Linker",
            body: "See [[\(ulidTitle)]].")
        try store.replaceLinks(from: linker.id,
            parsedLinks: WikiLinkParser.parse("See [[\(ulidTitle)]]."))

        let links = try store.listAllLinks().filter { $0.from == linker.id.rawValue }
        #expect(links.contains { $0.to == target.id.rawValue },
                "ULID-shaped title must resolve by name, not be dropped")
    }

    // MARK: - AC.6 — rename self-heals at render, zero body writes

    @Test func pageRenameSelfHealsAtRenderWithNoBodyRewrite() throws {
        let store = try GRDBWikiStore(databaseURL: tempDatabaseURL())
        let target = try PageUpsert.upsert(in: store, id: nil, title: "Old Title", body: "content")

        // 50 inbound links from 50 pages, canonicalized on save.
        var linkerIDs: [PageID] = []
        var before: [(id: PageID, version: Int, updatedAt: Date, body: String)] = []
        for i in 0..<50 {
            let outcome = try PageUpsert.upsert(in: store, id: nil, title: "Linker \(i)",
                body: "Links [[Old Title]].")
            linkerIDs.append(outcome.id)
            let p = try store.getPage(id: outcome.id)
            before.append((outcome.id, p.version, p.updatedAt, p.bodyMarkdown))
            // Each body is now canonical: [[page:<id>|Old Title]].
            #expect(p.bodyMarkdown.contains("[[page:\(target.id.rawValue)|Old Title]]"))
        }

        // Rename the target page (re-title via updatePage on the existing row).
        try store.updatePage(id: target.id, title: "New Title", body: "content")

        // Render an inbound-link page: the stale alias "Old Title" must display
        // the CURRENT title "New Title" (display-at-render self-heal).
        let displayName: (PageID, ParsedLink.LinkType) -> String? = { id, kind in
            guard kind == .page, id == target.id else { return nil }
            return "New Title"
        }
        let rendered = WikiLinkMarkdown.linkified(before[0].body,
            isResolved: { _, _ in true }, displayName: displayName)
        #expect(rendered.contains("New Title"))
        #expect(!rendered.contains("Old Title"))

        // Zero body writes: every linking page's version + updated_at unchanged.
        for (i, id) in linkerIDs.enumerated() {
            let after = try store.getPage(id: id)
            #expect(after.version == before[i].version)
            #expect(after.updatedAt == before[i].updatedAt)
            #expect(after.bodyMarkdown == before[i].body)
        }
    }

    // MARK: - AC.9 — source rename self-heals, no body rewrite

    @Test func sourceRenameSelfHealsAtRenderNoBodyRewrite() throws {
        let store = try GRDBWikiStore(databaseURL: tempDatabaseURL())
        let source = try store.addSource(filename: "paper.pdf", data: Data("%PDF".utf8))
        try store.renameSource(id: source.id, to: "Old Paper")

        // A canonical source link: [[source:<id>|Old Paper]].
        let outcome = try PageUpsert.upsert(in: store, id: nil, title: "Linker",
            body: "See [[source:Old Paper]].")
        let before = try store.getPage(id: outcome.id)
        #expect(before.bodyMarkdown.contains("[[source:\(source.id.rawValue)|Old Paper]]"))

        // Rename the source — NO body rewrite (Phase 5.3.3).
        try store.renameSource(id: source.id, to: "New Paper")
        let after = try store.getPage(id: outcome.id)
        #expect(after.bodyMarkdown == before.bodyMarkdown)
        #expect(after.version == before.version)
        #expect(after.updatedAt == before.updatedAt)

        // The stale alias "Old Paper" self-heals to "New Paper" at render.
        let displayName: (PageID, ParsedLink.LinkType) -> String? = { id, kind in
            guard kind == .source, id == source.id else { return nil }
            return "New Paper"
        }
        let rendered = WikiLinkMarkdown.linkified(after.bodyMarkdown,
            isResolved: { _, _ in true }, displayName: displayName)
        #expect(rendered.contains("New Paper"))
    }

    // MARK: - AC.8 — v22→v23 body migration

    /// Build a v23 DB, plant a legacy (raw, uncanonicalized) body, then rewind
    /// the stamp to v22 so reopening runs the v23 sweep. Returns the URL + the
    /// linker page id + the target id + the pre-migration token/version.
    private func buildRewoundV22DB() throws -> (url: URL, linkerID: PageID, targetID: PageID,
                                                 token: ChangeToken, version: Int) {
        let url = tempDatabaseURL()
        let targetID: PageID
        let linkerID: PageID
        let token: ChangeToken
        let version: Int
        do {
            let store = try GRDBWikiStore(databaseURL: url)
            targetID = try PageUpsert.upsert(in: store, id: nil, title: "Target", body: "").id
            // Raw updatePage (no canonicalization) plants a legacy body.
            let linker = try store.createPage(title: "Linker")
            try store.updatePage(id: linker.id, title: "Linker",
                body: "See [[Target]] and [[Ghost]].")
            try store.replaceLinks(from: linker.id,
                parsedLinks: WikiLinkParser.parse("See [[Target]] and [[Ghost]]."))
            linkerID = linker.id
            token = try store.changeToken()
            version = try store.getPage(id: linker.id).version
        } // store deinit closes the connection
        var db: OpaquePointer?
        sqlite3_open(url.path, &db)
        sqlite3_exec(db, "PRAGMA user_version=22;", nil, nil, nil)
        sqlite3_close(db)
        return (url, linkerID, targetID, token, version)
    }

    @Test func migrateV22ToV23CanonicalizesBodiesAndAdvancesToken() throws {
        let (url, linkerID, targetID, tokenBefore, versionBefore) = try buildRewoundV22DB()

        // Reopen → v23 sweep runs.
        let reopened = try GRDBWikiStore(databaseURL: url)
        #expect(reopened.pragmaValue("user_version") == "\(GRDBWikiStore.schemaVersion)")

        let migrated = try reopened.getPage(id: linkerID)
        // Resolvable link canonicalized; forward link left verbatim.
        #expect(migrated.bodyMarkdown.contains("[[page:\(targetID.rawValue)|Target]]"))
        #expect(migrated.bodyMarkdown.contains("[[Ghost]]"))

        // Token advanced + version/updated_at bumped (the File Provider sync anchor).
        let tokenAfter = try reopened.changeToken()
        #expect(tokenAfter != tokenBefore)
        #expect(migrated.version > versionBefore)
    }

    @Test func migrateV22ToV23IsIdempotent() throws {
        let (url, linkerID, targetID, _, _) = try buildRewoundV22DB()

        // First reopen: migrates.
        let first = try GRDBWikiStore(databaseURL: url)
        let afterFirst = try first.getPage(id: linkerID)
        #expect(afterFirst.bodyMarkdown.contains("[[page:\(targetID.rawValue)|Target]]"))
        let tokenAfterFirst = try first.changeToken()
        let bodyAfterFirst = afterFirst.bodyMarkdown

        // Second reopen: no-op (already v23).
        let second = try GRDBWikiStore(databaseURL: url)
        let afterSecond = try second.getPage(id: linkerID)
        #expect(afterSecond.bodyMarkdown == bodyAfterFirst)
        #expect(try second.changeToken() == tokenAfterFirst)
    }

    // MARK: - Issue #619 — pipe in source display_name, end-to-end through PageUpsert

    @Test func upsertCanonicalizesSourceLinkWithPipeInDisplayName() throws {
        // The issue's repro: a source whose `display_name` contains a literal
        // `|`. Under the app's normal ingestion flow, `WikiNameRules.sanitized`
        // (called by `addSource`/`renameSource` at every write boundary, and by
        // the v17→v18 migration for pre-existing rows) replaces `|` → `-` so
        // the invariant "every stored name is linkable" holds. To stage the rare
        // but reachable state where a `|` survives into the DB (manual SQL
        // edit, a future code path that bypasses sanitization, …), this test
        // plants the row directly via raw `sqlite3_exec` — the same bypass
        // pattern `buildRewoundV22DB()` uses to rewind `user_version`.
        let url = tempDatabaseURL()
        let displayName = "But what is cross-entropy? | Compression is Intelligence Part 2"
        // 26-char Crockford Base32 ID (X/Y/Z are valid; I/L/O/U are excluded).
        let sourceID = "01HXXXXXXXXXXXXXXXXXXXXXXX"

        // 1) Initialize schema (fresh, at the current schema version). Deinit
        //    closes the connection.
        _ = try GRDBWikiStore(databaseURL: url)

        // 2) Plant a `sources` row with a literal `|` in `display_name`,
        //    bypassing the sanitization the public API enforces. Single-quote
        //    safe (the title has no apostrophes). The rest of the NOT NULL
        //    columns get sensible values; defaults cover the rest.
        var db: OpaquePointer?
        sqlite3_open(url.path, &db)
        let now = Date().timeIntervalSince1970
        let insertSQL = """
        INSERT INTO sources (id, filename, byte_size, created_at, updated_at, display_name, role)
        VALUES ('\(sourceID)', 'video-dQw4w9WgXcQ-transcript.md', 0, \(now), \(now), '\(displayName)', 'primary');
        """
        sqlite3_exec(db, insertSQL, nil, nil, nil)
        sqlite3_close(db)

        // 3) Reopen through the store. Schema is already at the current
        //    version, so no migration runs and the planted row survives
        //    verbatim (with its `|`).
        let store = try GRDBWikiStore(databaseURL: url)

        // Sanity: the planted source resolves by its whole `|`-bearing name
        // (Pass 1: exact case-insensitive `display_name` match).
        let resolved = try store.resolveSourceByName(displayName)
        #expect(resolved?.rawValue == sourceID,
                "planted source with `|` in display_name must resolve by name")

        // 4) Save a page whose body cites the source by its whole display name.
        //    Without the issue #619 fix, the regex splits `[[source:Name | p…]]`
        //    into target=`Name ` + alias=`p…` (truncated) and the resolver would
        //    never match the truncated `Name` — the link stays a forward link.
        //    With the try-resolve-whole branch at the canonicalize seam, the
        //    reconstituted whole name resolves against the store and the link
        //    canonicalizes as `[[source:<ULID>|<whole name with pipe>]]`.
        let outcome = try PageUpsert.upsert(in: store, id: nil, title: "Linker",
            body: "Cite [[source:\(displayName)]].")

        let stored = try store.getPage(id: outcome.id)
        let expectedCanonical = "[[source:\(sourceID)|\(displayName)]]"
        #expect(stored.bodyMarkdown.contains(expectedCanonical),
                "expected canonical form in stored body, got: \(stored.bodyMarkdown)")
        #expect(!stored.bodyMarkdown.contains("[[source:\(displayName)]]"),
                "raw display-name form should be gone: \(stored.bodyMarkdown)")

        // 5) Re-parse: the canonical body yields a `source_links` edge pointing
        //    at the embedded-pipe source id (the ULID target survives parse).
        let links = try store.listAllSourceLinks().filter { $0.from == outcome.id.rawValue }
        #expect(links.contains { $0.to == sourceID },
                "source_links edge should point at the embedded-pipe source id")

        // 6) Idempotency: re-saving the canonical body is a no-op. The target
        //    slice is now a 26-char ULID, which trips the idempotency fast path
        //    (WikiLinkRewriter.swift, `isCanonicalULID`), so neither the
        //    try-resolve-whole branch nor the regular resolve block fires.
        let before = stored.bodyMarkdown
        _ = try PageUpsert.upsert(in: store, id: outcome.id, title: "Linker",
            body: stored.bodyMarkdown)
        let after = try store.getPage(id: outcome.id)
        #expect(after.bodyMarkdown == before,
                "re-saving a canonical embedded-pipe body must be a no-op")
    }
}
