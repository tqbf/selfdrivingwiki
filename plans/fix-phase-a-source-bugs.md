# Fix Phase A Source Bugs

**Status:** Ready to implement. Lands on its own branch ahead of
[`phase-b-source-wikilinks.md`](phase-b-source-wikilinks.md). Blocks Phase B.
**Parent design:** [`sources-redesign.md`](sources-redesign.md) (Phase A shipped in PR #31).
**Scope:** bugs already in the tree from Phase A. Nothing from Phase B (link rendering,
parser, resolution normalizer) belongs here — that is Plan 2.

## Goal

Fix the two defects shipped by Phase A before any Phase B work piles on top of them:

- **Bug A — `source_links` has no `ON DELETE CASCADE`.** `deleteSource` will throw an
  FK-constraint violation the moment Phase B writes the first `source_links` row.
- **Bug B — File Provider still projects the sources index as `files.jsonl` under a
  `files/` folder.** The Phase A rename touched the enum cases and `IndexGenerators`
  but not the projected display names, so the on-disk filename the agent sees is stale
  and disagrees with `manifest.json`.

Plus one stale comment.

These are confirmed against the code; see the review in this session's transcript
(`source_links` FK at `SQLiteWikiStore.swift:330`; `files.jsonl`/`files` at
`Projection.swift:407,409`).

---

## Bug A — `source_links` missing `ON DELETE CASCADE`

### Root cause + evidence

- `SQLiteWikiStore.swift:330` declares `to_source_id TEXT NOT NULL REFERENCES sources(id),`
  — **no `ON DELETE` clause.** Contrast `source_markdown_versions.file_id` at line 287,
  which correctly has `REFERENCES ingested_files(id) ON DELETE CASCADE`.
- `deleteSource` (`SQLiteWikiStore.swift:844-849`) is a bare
  `DELETE FROM sources WHERE id = ?1` — no transaction, no manual `source_links` cleanup.
- `PRAGMA foreign_keys` is **ON** (the v7/v8 cascades at lines 271, 287 are actively
  relied on). With FK enforcement on and the cascade missing, deleting a source that has
  any `source_links` row raises `SQLITE_CONSTRAINT ForeignKey`.
- The bug is **latent today** because nothing writes to `source_links` yet —
  `replaceSourceLinks` does not exist (grep: zero hits). It goes live the moment Phase B
  starts populating the table, which is exactly why it must be fixed first.
- The parent design claims cascade delete (`sources-redesign.md:135`), so this is a
  shipped-not-as-specced bug, not a new feature.

### Fix — v11 migration that rebuilds `source_links` with the cascade

SQLite cannot `ALTER` an FK constraint in place, so rebuild the table. Use the
rename→create→copy→drop pattern so it is **data-preserving and idempotent** (safe on a
populated DB if an existing wiki upgrades after Phase B has already run, and a no-op-
effective rebuild on an empty one). No other table references `source_links` (it is a
leaf join table; `source_markdown_versions` references `sources`, not `source_links`), so
the rename does not trigger FK-reference rewrites elsewhere and `legacy_alter_table` is
not required.

Append to `bootstrapSchema()` (`SQLiteWikiStore.swift`, after the `if version < 10` block,
before the closing brace at line 338), matching the existing step style exactly:

```swift
// v10 → v11: add ON DELETE CASCADE to source_links.to_source_id. SQLite cannot ALTER
// an FK constraint in place, so rebuild the table (rename old → create new with the
// cascade → copy rows → drop old). source_links is a leaf join table (nothing FKs to
// it), so the rename is safe without legacy_alter_table. The rebuild is
// data-preserving for DBs that already have Phase B rows, and a no-op rebuild on
// empty ones. Mirrors the cascade already on source_markdown_versions (v8).
if version < 11 {
    try exec("ALTER TABLE source_links RENAME TO source_links_v10;")
    try exec("""
    CREATE TABLE source_links (
        from_page_id TEXT NOT NULL REFERENCES pages(id),
        to_source_id TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
        link_text    TEXT NOT NULL,
        PRIMARY KEY (from_page_id, to_source_id)
    );
    """)
    try exec("""
    INSERT INTO source_links (from_page_id, to_source_id, link_text)
    SELECT from_page_id, to_source_id, link_text FROM source_links_v10;
    """)
    try exec("DROP TABLE source_links_v10;")
    try exec("PRAGMA user_version=11;")
    version = 11
}
```

`deleteSource` (lines 844-849) needs **no change**: once the cascade lands the bare
`DELETE FROM sources` automatically removes the source's `source_links` rows. Do not add
a defensive manual `DELETE FROM source_links` there — the schema cascade is the single
source of truth and a manual delete would just be a second, divergent cleanup path.

> Alternative considered (rejected as primary): add a manual
> `DELETE FROM source_links WHERE to_source_id = ?1` inside `deleteSource`. This papers
> over the missing constraint but leaves the schema wrong, so a future direct `DELETE`
> (a CLI, a vacuum, a refactor) re-introduces the violation. Fixing the schema is
> correct; the manual delete is only a stopgap if we ever ship under a frozen schema.

### Tests (`Tests/WikiFSTests/SQLiteWikiStoreTests.swift`)

The migration ladder is already tested there (lines 64-69 and 238 assert `user_version`;
line 197 already exercises `deleteSource`). Add:

1. **`deleteSource cascades to source_links after v11 migration`** — open a fresh store
   (steps 0→11), add a source, insert a `source_links` row referencing it, then
   `deleteSource(id:)` and assert it does **not** throw and the `source_links` row is gone
   (`SELECT count(*) FROM source_links WHERE to_source_id = ?` == 0). This test fails on
   v10 (FK violation) and passes on v11 — it is the regression guard.
2. **`fresh DB reaches user_version 11`** — extend the existing `user_version` assertion
   (lines 64-69, 238) from 9/10 to 11.
3. **`v10 → v11 migration preserves source_links rows`** — build a DB at v10, hand-insert
   two `source_links` rows, re-open (triggers v11), assert both rows survive and the new
   FK has the cascade (query `sqlite_master` for the `source_links` DDL and assert it
   contains `ON DELETE CASCADE`). Confirms the rebuild is data-preserving.

---

## Bug B — File Provider projects `files.jsonl` / `files/` (stale Phase A rename)

### Root cause + evidence

- `Projection.swift:407` — `Identity.indexSourcesJSONL` case returns
  `indexFileNode(for: id, name: "files.jsonl", parent: Identity.indexes)`.
- `Projection.swift:409` — `Identity.sources` case returns
  `.folder(id: id, parent: .rootContainer, name: "files")`.
- The enum **cases** were renamed in Phase A (`indexSourcesJSONL`, `sources`,
  `sourcesByID`, `sourcesByName`) and `IndexGenerators` was updated
  (`sourceIndexPath = "indexes/sources.jsonl"`, line 78; manifest advertises
  `source_index` → `indexes/sources.jsonl`, lines 99-100, asserted at
  `IndexGeneratorTests.swift:37`). But the **display strings** the File Provider projects
  were not, so the on-disk tree still shows `indexes/files.jsonl` and a top-level `files/`
  folder — contradicting the manifest an agent is told to trust.
- `OperationCommandTests.swift:385` already asserts the agent prompt does **not** contain
  `$WIKI_ROOT/indexes/files.jsonl` (the prompt was fixed in commit `027eb2d`); the
  projection is the last stale surface.

### Fix — update the two projected names

In `Projection.swift`:

```swift
// line 407
case Identity.indexSourcesJSONL:
    return indexFileNode(for: id, name: "sources.jsonl", parent: Identity.indexes)
// line 409
case Identity.sources:
    return .folder(id: id, parent: .rootContainer, name: "sources")
```

### Stale comment (same root cause)

`WikiCtlCore/SourceCommand.swift:73` has a comment `// …to match indexes/files.jsonl.`
Update it to `indexes/sources.jsonl`.

### Tests

- Add a projection-level test asserting the sources index node is named `sources.jsonl`
  under `indexes/`, and the sources root folder is named `sources`. (Find the existing
  File Provider / projection test home — `IndexGeneratorTests.swift` covers the generator
  side; add the projection-name assertion there or in the File Provider test target,
  whichever enumerates projected node names.) `IndexGeneratorTests.swift:37` already
  pins the manifest side; mirror it for the projected filename.
- Grep-confirm no remaining `"files.jsonl"` / top-level `"files"` display strings in
  `Sources/` after the edit (the only remaining hits should be inside code-blocks / the
  `$WIKI_ROOT/files/…` negative assertions in `OperationCommandTests`, which are
  intentional).

---

## Out of scope (belongs to Plan 2 / Phase B)

Do **not** touch here:

- The render-contract contradiction (`isResolved: (String) -> Bool` vs `wiki://source?id=`).
- `WikiLinkParser` `source:` prefix / `LinkType`.
- The shared normalizer / case-insensitive resolution.
- `replaceSourceLinks` / `listAllSourceLinks` / `resolveSourceByName`.
- `selectSource(byDisplayName:)`.
- `links.jsonl` `type` field.
- The Phase B checklist item "Add `source_links` table" — the table already exists; Plan 2
  strikes that line. (This plan only fixes its FK, it does not add or remove the table.)

---

## Gate

- `swift build` clean.
- `swift test` green — specifically the three new `SQLiteWikiStoreTests` (cascade + v11 +
  preservation) and the new projection-name test, with the `user_version` assertions bumped
  to 11.
- Manual (optional, if the mount is signed): drop a source, add a `source_links`-style
  reference row by hand via `sqlite3`, delete the source from the app, confirm no error and
  the row is gone.
