# Vector (semantic) search for sources

## Goal

Add semantic (vector) search for sources, surfaced in two places: (1) a dedicated search box in the Sources sidebar section, mirroring the existing Pages search, and (2) a `wikictl source search` command so the LLM agent can search sources by meaning. This reuses the existing page-embedding pipeline (Apple `NLEmbedding` + `sqlite-vec` cosine) verbatim, applied to sources.

## Implementation Summary

The page pipeline already does everything we need; we mirror it for sources:

- **Embeddings** are computed by `EmbeddingService` (512×Float32 BLOB, macOS 15+, app-bundle-gated) from `title + body` (`Sources/WikiFSCore/EmbeddingService.swift`).
- **Storage** is a per-entity embeddings table with `sqlite-vec`'s `vec_distance_cosine` (`page_embeddings`, schema v7). We add a parallel `source_embeddings` table (schema **v11 → v12**).
- **Write hooks** recompute the embedding when content changes (pages: `PageUpsert` + `recomputeMissingEmbeddings`). For sources the single chokepoint is `appendProcessedMarkdown` (extraction seeding, raw-text seeding, user edits, and revert all funnel through it).
- **Search** is `searchSimilar` (semantic cosine, `LIKE` fallback). We add `searchSimilarSources`.
- **UI** is a debounced search box (`WikiStoreModel.scheduleSearch`, 300 ms). We add the source equivalent in the Sources section.
- **Agent** searches pages via `wikictl search` (`PageCommand.search` → `store.searchSimilar`, documented in `SystemPrompt.swift`). We add `wikictl source search` the same way.

**Embedding content (decided):** each source is embedded on **processed markdown (body) + filename (title)**. A source with no processed markdown yet (un-extracted PDF, binary file) embeds its name only so it still appears. This mirrors pages embedding `title + body`.

### Touch points / scope

- `Sources/WikiFSCore/SQLiteWikiStore.swift` — migration, store methods, re-embed hooks.
- `Sources/WikiFSCore/WikiStore.swift` — protocol additions (update all conformers).
- `Sources/WikiFSCore/WikiStoreModel.swift` — source search query/results + debounce; reindex seeding.
- `Sources/WikiFS/SourcesSectionView.swift`, `Sources/WikiFS/SidebarView.swift` — search box + reindex.
- `Sources/WikiCtlCore/SourceCommand.swift`, `Sources/WikiCtlCore/ArgumentParser.swift` — `source search`.
- `Sources/WikiFSCore/SystemPrompt.swift` — document the new command for the agent.
- Tests + `PROGRESS.md`.

**Non-goals:** no unified/command-palette search, no cross-entity search, no change to page search, no new embedding model.

## Implementation Plan

### Phase 1 — Storage & embeddings (`WikiFSCore`)

**1.1 Schema migration v11 → v12** (`SQLiteWikiStore.swift`, after the v11 block ending ~line 362). Mirror the v7 `page_embeddings` block (lines 268–277):

```swift
// v11 → v12: source embeddings for semantic source search (sqlite-vec).
// Mirrors page_embeddings (v7). ON DELETE CASCADE: removing a source removes
// its embedding. FK target is sources(id) (renamed from ingested_files in v10).
if version < 12 {
    try exec("""
    CREATE TABLE source_embeddings (
        source_id TEXT PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,
        embedding BLOB NOT NULL
    );
    """)
    try exec("PRAGMA user_version=12;")
    version = 12
}
```

**1.2 `storeSourceEmbedding(id:blob:)`** — `INSERT OR REPLACE INTO source_embeddings`, mirroring `storePageEmbedding` (lines 1357–1366).

**1.3 `searchSimilarSources(query:limit:) -> [SourceSummary]`** — mirror `searchSimilar` (1368–1425):
- Semantic path (guarded by `isVecAvailable()` + `EmbeddingService.embeddingBlob(for:)`), reusing the existing `sourceSummary(from:)` fixed-index row reader (line 1087). Enumerate columns explicitly — **never `SELECT s.*`** (see warning below):

```sql
SELECT s.id, s.filename, s.ext, s.mime_type, s.byte_size, s.created_at, s.updated_at,
       s.version, s.zotero_item_key, s.zotero_item_title, s.display_name
FROM sources s
JOIN source_embeddings se ON se.source_id = s.id
ORDER BY vec_distance_cosine(se.embedding, ?1) ASC
LIMIT ?2;
```
  then `out.append(sourceSummary(from: stmt))` per row.
- Fallback: the same explicit 11-column list, `WHERE filename LIKE ?1 OR display_name LIKE ?1`, `ORDER BY updated_at DESC`.
- **Why not `SELECT s.*`:** the physical `sources` table (originally `ingested_files`) has a `content` BLOB positioned between `byte_size` and `created_at`. `SELECT s.*` would emit `content` at index 5, shifting every later column so `sourceSummary(from:)` — which reads index 5 as `created_at` via `stmt.double(at: 5)` — would dereference the content BLOB as a Double. `listSources()` (line 948) already avoids this by naming columns; do the same.

**1.4 `recomputeMissingSourceEmbeddings() -> Int`** — mirror `recomputeMissingEmbeddings` (1427–1451), guarded by `isVecAvailable()`. SQL:

```sql
SELECT s.id, s.display_name, s.filename,
       (SELECT content FROM source_markdown_versions smv
        WHERE smv.file_id = s.id ORDER BY smv.id DESC LIMIT 1) AS body
FROM sources s
LEFT JOIN source_embeddings se ON se.source_id = s.id
WHERE se.source_id IS NULL;
```

Per row: `EmbeddingService.embeddingBlob(title: displayName ?? filename, body: body ?? "")` → `storeSourceEmbedding`. Count and return.

**1.5 Re-embed hooks** (keep embeddings fresh without requiring reindex):
- In `appendProcessedMarkdown` (line 1527), after the `INSERT ... step()`, re-embed from the just-written `content` + the source's name. Add a private helper:

```swift
private func reembedSource(sourceID: PageID, body: String) {
    guard isVecAvailable() else { return }
    guard let row = try? statement(
        "SELECT display_name, filename FROM sources WHERE id = ?1;")
    else { return }
    // bind sourceID, step once, read name; then:
    let title = displayName ?? filename
    if let blob = EmbeddingService.embeddingBlob(title: title, body: body) {
        try? storeSourceEmbedding(id: sourceID, blob: blob)
    }
}
```

  Call `reembedSource(sourceID: sourceID, body: content)` at the end of `appendProcessedMarkdown`. This covers extraction seeding, raw-text seeding, user edits, AND `revertProcessedMarkdown` (which appends a new version), so revert is covered automatically. The re-embed is best-effort (`try?`) and not transactionally tied to the version `INSERT` (`appendProcessedMarkdown` autocommits each statement); if it fails or the model is unavailable, the version still commits and the embedding is backfilled by `recomputeMissingSourceEmbeddings` on the next Reindex — mirroring how page embeddings are kept fresh.
- In `renameSource`, after the `display_name` `UPDATE`, call `reembedSource` with the current head content (the title changed). If no markdown head exists, embed name-only.

**1.6 Protocol** (`WikiStore.swift`, after line 171): add

```swift
func storeSourceEmbedding(id: PageID, blob: Data) throws
func searchSimilarSources(query: String, limit: Int) throws -> [SourceSummary]
func recomputeMissingSourceEmbeddings() -> Int
```

**Update every `WikiStore` conformer.** Verified across `Sources/` and `Tests/`: only `SQLiteWikiStore` conforms — there are no `WikiStore` test doubles (all tests, including `ReadOnlyStoreTests`, use a real `SQLiteWikiStore`). Implement the three methods on `SQLiteWikiStore`; a `grep ': WikiStore'` will confirm no others.

### Phase 2 — Model & UI (`WikiFS`)

**2.1 `WikiStoreModel` search state** — mirror pages (lines 27–32, 241–242, 1278–1293):

```swift
public var sourceSearchQuery: String = "" { didSet { scheduleSourceSearch() } }
public private(set) var sourceSearchResults: [SourceSummary] = []
@ObservationIgnored private var sourceSearchTask: Task<Void, Never>?

public func searchSimilarSources(query: String, limit: Int = 20) -> [SourceSummary] {
    (try? store.searchSimilarSources(query: query, limit: limit)) ?? []
}

private func scheduleSourceSearch() {
    sourceSearchTask?.cancel()
    guard !sourceSearchQuery.isEmpty else { sourceSearchResults = []; return }
    sourceSearchTask = Task { [weak self] in
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled, let self else { return }
        let results = (try? self.store.searchSimilarSources(
            query: self.sourceSearchQuery, limit: 20)) ?? []
        guard !Task.isCancelled else { return }
        self.sourceSearchResults = results
    }
}
```

**2.2 Reindex seeds sources** — extend the "Reindex" path so text sources get content embeddings. In `WikiStoreModel`, add a `recomputeMissingSourceEmbeddings()` that, before calling `store.recomputeMissingSourceEmbeddings()`, iterates sources lacking an embedding and lacking processed markdown and calls `processedMarkdownHead(for:)` on markdown-native (`mimeType` `text/…`) ones (this seeds v1 → triggers the 1.5 hook → embeds content). PDFs/un-extracted sources fall through to the store recompute (name-only).

**2.3 Sources search box** (`SourcesSectionView.swift`) — add a `sourceSearchBar` mirroring `SidebarView.searchBar` (lines 236–248), bound to `store.sourceSearchQuery`. In the list body: when `store.sourceSearchQuery` is non-empty, iterate `store.sourceSearchResults` (show "No matching sources" when empty); otherwise keep `filteredSources`. Place the bar between the filter picker and the rows (matching the Pages section's layout).

**2.4 Reindex button** (`SidebarView.swift` toolsSection, ~lines 178–185): the existing "Reindex Search" button calls `store.recomputeMissingEmbeddings()`; add `store.recomputeMissingSourceEmbeddings()` immediately after.

### Phase 3 — Agent CLI (`WikiCtlCore`) + system prompt

**3.1 `SourceCommand.Action`** (line 38) — add `case search(query: String, limit: Int)`.

**3.2 `SourceCommand.run`** (line 59) — dispatch `.search` → a `search(query:limit:in:)` mirroring `PageCommand.search` (lines 198–207): `store.searchSimilarSources(query:limit:)`, output TSV `id\teffectiveName` (`displayName ?? filename`), `didCommit: false`.

**3.3 `ArgumentParser.parseSourceCommand`** (line 207) — add:

Add inside the existing `switch sub` in `parseSourceCommand` (after `options` is created at line 210), matching the `parseSearchCommand` idiom (lines 190–205). There is no shared `Options.requireValue`/`limit` helper, so inline the validation:

```swift
case "search":
    guard let query = options.value("--query") else {
        throw Failure.usage("source search: --query is required")
    }
    let limit: Int
    if let raw = options.value("--limit") {
        guard let n = Int(raw), n > 0, n <= 100 else {
            throw Failure.usage("source search: --limit must be 1–100")
        }
        limit = n
    } else {
        limit = 10
    }
    return .source(.search(query: query, limit: limit))
```

**3.4 `ArgumentParser.usageText`** (after line 94) — add:

```
source search --query X [--limit N]         semantic search of sources (cosine; LIKE fallback)
```

**3.5 No `main.swift` change required** — `source search` routes through the existing `case .source(let action)` handler (line 93) → `SourceCommand.run`. (Unlike `edit-markdown`/`rename`, there's no deferred stdin/file body to resolve.)

**3.6 `SystemPrompt.swift`** — in the tooling command list (near lines 172–176) add:

```
$WIKICTL source search --query "…" [--limit N]   semantic search of sources — find source material by meaning
```

and add a short note in the navigation/guidance text (near lines 186–190, where `sources.jsonl`/`has_markdown` are described) that source *content* is searchable via `source search`, complementing `sources.jsonl` (metadata) and `source cat` (raw bytes).

## Acceptance Criteria

- **AC.1** — In the running app, typing a meaning-based query in the Sources search box returns sources ranked by semantic similarity. Verify with an extracted PDF: a query paraphrasing its content surfaces it even with zero keyword overlap.
- **AC.2** — When the embedding model is unavailable, Sources search falls back to filename/name matching; shows "No matching sources" when nothing matches.
- **AC.3** — After extracting a PDF (or first-viewing a text source, which seeds it), the source's content embedding is computed automatically — no manual reindex needed (search by content finds it).
- **AC.4** — "Reindex Search" backfills missing source embeddings; a second run is a no-op (idempotent).
- **AC.5** — `wikictl source search --query "…" [--limit N]` prints ranked `id<TAB>name` lines; `--limit` validated 1–100 (default 10); missing `--query` prints a usage error and exits non-zero.
- **AC.6** — With the updated system prompt, the agent runs `wikictl source search` during an Ask/Edit session to find sources by meaning (demonstrable end-to-end).
- **AC.7** — Deleting a source removes its embedding (cascade); renaming a source updates the embedding's title (search by new name works).
- **AC.8** — `swift build` and `swift test` pass.

## Test Strategy

**Swift unit tests** (new `Tests/WikiFSTests/SourceEmbeddingSearchTests.swift`, mirroring the existing page/`wikictl` test style):
- Migration: open a fresh DB, assert `source_embeddings` exists at v12; assert `page_embeddings` path unchanged.
- `storeSourceEmbedding` round-trip; `searchSimilarSources` **LIKE fallback** returns the expected source by filename.
- `recomputeMissingSourceEmbeddings` is idempotent and fills gaps; name-only embedding for a source with no processed markdown.
- `SourceCommand.run(.search(...))`: TSV output shape, `--limit` clamping, missing-`--query` usage error (mirror the `WikiCtlCommandTests` / `SourceCommand` tests).
- Cascade: deleting a source removes its `source_embeddings` row. First confirm the writer connection sets `PRAGMA foreign_keys=ON` (the v7 `page_embeddings` cascade relies on the same pragma); the test asserts the `source_embeddings` row is gone after `deleteSource`.

**Model-gating caveat:** `EmbeddingService.model()` returns `nil` unless `Bundle.main.bundlePath.hasSuffix(".app")`, so the cosine-ranking semantic path cannot run under `swift test`. Tests cover the store SQL, the LIKE fallback, wiring, and the CLI — exactly the same limitation the page pipeline has. **AC.1, AC.3, AC.6 must be validated manually in the running app** following `docs/skills/reproducing-live-ui-bugs/SKILL.md` (instrument via `DebugLog`/`os_log`, subsystem `com.selfdrivingwiki.debug`; never `print`).

**Full suite:** run `swift test`; update any `WikiStore` test doubles that the Phase 1 protocol changes break.

## Review Strategy

- **Plan-mode review:** run the `plan-reviewer` subagent on this plan before handoff; fix or rebut all critical/high findings (re-run if any remain).
- **Implementation review:** after `swift test` passes, dispatch a `general-purpose` subagent (read-only review) against the diff; follow any repo-local review guidance. Fix or rebut every finding; re-review if critical findings remain.

## Documentation Strategy

- **Agent-facing:** `SystemPrompt.swift` (Phase 3.6) is the agent's primary documentation — the command list is what it reads.
- **Repo:** append a short entry to `PROGRESS.md` (repo convention: keep `PLAN.md`/`PROGRESS.md` current).
- **CLI:** `usageText` (Phase 3.4) documents `source search` for human users.
- The sidebar search box is self-evident; no separate user-facing doc page is warranted. No `AGENTS.md` change required unless repo guidance says otherwise.

## Risks, Blockers, and Required Decisions

- **`WikiStore` protocol changes are breaking for conformers.** Verified: only `SQLiteWikiStore` conforms (no test doubles exist — all tests use a real store). Execute agent adds the three new methods to `SQLiteWikiStore`; a `grep ': WikiStore'` confirms no others. (Resolved as a concrete step, not an open blocker.)
- **Embedding model is app-gated** → semantic cosine ranking is not unit-testable; mitigated by LIKE-fallback tests + manual validation of AC.1/AC.3/AC.6.
- **sqlite-vec availability** is unchanged from the page pipeline — semantic search degrades to LIKE when the extension/model is unavailable; no new risk.
- **Reindex cost** for large source libraries computes many on-device embeddings (NLEmbedding is local/fast); acceptable, user-initiated, same cost profile as pages.
- **Embedding staleness** is handled by hooks (`appendProcessedMarkdown`, `renameSource`) plus reindex backfill; a markdown-native source not yet viewed embeds name-only until first view seeds its content (then re-embeds). Acceptable and documented.

**Decisions already made (no open blockers):**
- Dedicated Sources search box (not unified/palette).
- Embed on processed-markdown content + filename; name-only fallback for un-extracted/binary sources.
- Agent access via `wikictl source search` (mirroring `wikictl search`).
