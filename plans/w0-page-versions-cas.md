# W0 Implementation Plan — Page versions & CAS

**PR:** [#312](https://github.com/tqbf/selfdrivingwiki/pull/312) — `plans/page-versions-and-workspaces.md`
**Issue:** [#258](https://github.com/tqbf/selfdrivingwiki/issues/258) (page versioning)
**Schema:** v30 (v29 is the ask→edit data-only sweep, already shipped)

**Gate:** Two writers race one page — loser gets a `PageConflictError`, no
silent clobber. Page history browsable. Revert = one-row ref repoint. Token
literals byte-identical.

## Codebase findings (grounding)

### What exists (the substrate W0 builds on)

- **`blobs` (v20):** `hash TEXT PK, byte_size, content BLOB`. Content-addressed,
  `INSERT OR IGNORE` dedup. Used by sources; pages will reuse it.
- **`activities` + `agents` (v20):** PROV substrate. `appendContentVersion`
  creates an agent + activity per version; pages will mirror.
- **`refs` (v20):** `kind, owner_id, version_id, generation, updated_at`. Three
  ref kinds exist today: `source-content`, `source-derived` (source markdown).
  `version_id` is **un-FK'd** (polymorphic — points to `source_versions` or
  `source_markdown_versions` depending on kind).
- **`source_versions` (v20):** `id, source_id, parent_id, blob_hash, activity_id,
  fetched_at`. This is the exact pattern `page_versions` mirrors.
- **`appendContentVersion` (line 3622):** The CAS append protocol for sources —
  insert blob, create activity, insert version (parent = current head), UPSERT
  ref. Reusable as the template for `appendPageVersion`.
- **`setActiveMarkdown` (line 6277):** Ref repoint (revert) pattern for sources.
- **`PageUpsert.upsert` (line 48):** The shared write seam for both the app
  (`WikiStoreModel.save()` line 1031) and `wikictl` (line 168). Currently calls
  `store.updatePage` (blind write, no CAS) → `replaceLinks` → `storePageChunks`.
- **`pages` table:** `id, title, slug, body_markdown (inline), created_at,
  updated_at, version`. `body_markdown` is inline text, not blob-backed.
- **`pages_fts`:** External-content FTS5 over `pages` with triggers
  (`after insert/update/delete` on `pages`). Reads `body_markdown` from the
  `pages` row directly.

### Critical schema issue: `refs.owner_id` FK

The current `refs` table has:
```sql
owner_id TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE
```

This FK **blocks** inserting `page-content` refs (owner_id would be a page ID,
not a source ID). The graph-model plan (§4.3, line 231-238) explicitly noted
this as a trigger condition: *"when a third ref kind lands... evaluate splitting
refs per-kind into typed tables or adding a discriminator + CHECK-enforced
consistency rule."*

**Decision: table rebuild.** SQLite can't `ALTER TABLE DROP CONSTRAINT`, so
the standard rebuild pattern (CREATE _new, copy, DROP, RENAME) is used. This
follows the plan's explicit "CHECK on refs.kind" and the v11/v24 rebuild
precedent. The rebuilt `refs` drops the `owner_id` FK (replaced by a CHECK on
`kind`) and keeps `version_id` un-FK'd (already polymorphic).

### Migration discipline

- **FreshSchemaParityTests** — fresh path must match stepwise ladder. Both
  paths must create `page_versions` and the rebuilt `refs`.
- **StoreEmissionExhaustivenessTests** — every new public mutator must route
  through `mutate()` or be annotated NO-EMIT.
- **FreshSchemaParityTests.freshFastPathMatchesStepwiseLadder** — the new
  v30 step must be in BOTH paths.

## Implementation steps

### Step 1 — Schema: `page_versions` table + `refs` rebuild (v30)

**Fresh path** (`createFreshSchemaV20` or a new `createPageVersionsV30`):
```sql
CREATE TABLE IF NOT EXISTS page_versions (
    id               TEXT PRIMARY KEY,
    page_id          TEXT NOT NULL REFERENCES pages(id) ON DELETE CASCADE,
    parent_id        TEXT,
    merge_parent_id  TEXT,
    blob_hash        TEXT NOT NULL REFERENCES blobs(hash),
    title            TEXT NOT NULL,
    activity_id      TEXT REFERENCES activities(id),
    saved_at         REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS page_versions_page ON page_versions(page_id, id);
```

Rebuild `refs` (drop `owner_id` FK, add CHECK):
```sql
CREATE TABLE _refs_new (
    kind       TEXT NOT NULL CHECK (kind IN ('source-content','source-derived','page-content')),
    owner_id   TEXT NOT NULL,
    version_id TEXT NOT NULL,
    generation INTEGER NOT NULL DEFAULT 1,
    updated_at REAL NOT NULL,
    PRIMARY KEY (kind, owner_id)
);
INSERT INTO _refs_new SELECT * FROM refs;
DROP TABLE refs;
ALTER TABLE _refs_new RENAME TO refs;
```

**Migration ladder** (v29→v30):
- Same DDL as fresh path.
- Seed root version per existing page: for each `pages` row, insert a blob of
  `body_markdown`, insert a `page_versions` row (parent_id NULL, title from
  pages.title, activity_id = the legacy-import agent), write **no** ref row
  (default-active = MAX(id), exactly like sources at v20).

### Step 2 — Store layer (`SQLiteWikiStore`)

New methods + protocol additions:

- `appendPageVersion(pageID:title:body:expectedHeadVersionID:) throws -> PageVersion`
  — the CAS save protocol. Inside `withTransaction` + `mutate`:
  1. Resolve head = active `page-content` ref (or MAX(id) if no ref).
  2. CAS guard: `expectedHeadVersionID == head`, else throw `PageConflictError`.
  3. `INSERT OR IGNORE INTO blobs` (body bytes).
  4. Create legacy-import agent + activity (or reuse if caller provides).
  5. `INSERT INTO page_versions` (parent = head, blob_hash, title, activity_id).
  6. Update `pages.body_markdown` as a denormalized mirror (keeps FTS triggers
     working; reads stay unchanged).
  7. Optionally UPSERT the `page-content` ref (or rely on default-active
     MAX(id) — but the ref is needed for revert to work explicitly; seed it
     lazily: write the ref on the FIRST versioned save, not on the migration
     root versions).

- `pageHeadVersionID(pageID:) throws -> String?` — resolve active version
  (ref → version_id, or MAX(id) from page_versions).

- `pageVersionHistory(pageID:) throws -> [PageVersion]` — SELECT ordered by id.

- `revertPage(pageID:to versionID:) throws` — UPSERT the `page-content` ref to
  point at `versionID`, update `pages.body_markdown` from the version's blob.
  Mirrors `setActiveMarkdown`. Emits a `.page .updated` event.

- `PageConflictError` — new error: `pageID, expectedVersionID, actualVersionID`.

- Modify existing `updatePage`: route through `appendPageVersion` with
  `expectedHeadVersionID = nil` (backward-compatible: nil = skip CAS, blind
  write — the old behavior, so existing callers that don't thread the version
  don't break). This keeps `wikictl` working during the transition.

### Step 3 — `WikiStore` protocol

Add:
- `func appendPageVersion(pageID: PageID, title: String, body: String, expectedHeadVersionID: String?) throws -> String` (returns version ID)
- `func pageHeadVersionID(pageID: PageID) throws -> String?`
- `func pageVersionHistory(pageID: PageID) throws -> [PageVersionSummary]`
- `func revertPage(pageID: PageID, to versionID: String) throws`

### Step 4 — `PageUpsert.upsert` — thread CAS

The shared seam gains an optional `expectedHeadVersionID: String?` parameter:
- `PageUpsert.upsert(in:id:title:body:expectedHeadVersionID:)` — passes it
  through to `store.appendPageVersion`.
- `WikiStoreModel.save()` — reads the page's current head version ID at edit
  start (or at save time), passes it as the CAS expectation.
- `wikictl page upsert` — passes `nil` (backward-compatible blind write; CAS
  is opt-in so the agent doesn't break on a stale version).

### Step 5 — `wikictl page history` + `page revert`

New `PageCommand.Action` cases:
- `.history(Selector)` — prints version chain (version ID, timestamp, title,
  blob hash, 80-char body preview). Plain text, one line per version.
- `.revert(Selector, versionID: String)` — calls `store.revertPage`, didCommit=true.

### Step 6 — `vacuum-pages` (GC)

A new admin command (or fold into existing `vacuum-all`): delete `page_versions`
rows that are (a) not the active ref target AND (b) not an ancestor of the
active version AND (c) not pinned by any workspace ref. Orphaned blobs fall to
the existing `vacuum-blobs`. Defer to end of W0 if time-constrained — the
append-only chain is correct without GC, just grows.

### Step 7 — Tests

- **`FreshSchemaParityTests`** — assert `page_versions` exists + `refs` has
  the CHECK constraint on fresh DBs.
- **`StoreEmissionExhaustivenessTests`** — `appendPageVersion`, `revertPage`
  must appear in the EMIT partition (routed through `mutate`).
- **`PageVersionTests`** (new):
  - CAS conflict: two concurrent saves, second gets `PageConflictError`.
  - History: append 3 versions, verify chain order + parent linkage.
  - Revert: revert to v1, verify body + active version changes.
  - Default-active: no ref row → MAX(id) is head.
  - Migration: seed root versions for existing pages, verify body unchanged.
  - FTS still works after versioned save.

### Step 8 — `PROGRESS.md` + `PLAN.md` updates

## What's NOT in W0 (deferred)

- Workspaces, overlay resolution, merge — that's W1/W2.
- Conflict UI (editor affordance for `PageConflictError`) — minimal in W0:
  catch the error in `WikiStoreModel.save()`, log it, surface a storeError
  alert. Full conflict-view UI is W3.
- The agent edit lock retirement — that's W1 (behind a capability flag).
- `wikictl --workspace` — W1.
