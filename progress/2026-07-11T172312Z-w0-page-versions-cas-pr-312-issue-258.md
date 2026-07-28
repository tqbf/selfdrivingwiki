---
timestamp: 2026-07-11T172312Z
title: "2026-07-11 — W0: Page versions & CAS (PR #312, issue #258)"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-07-11 — W0: Page versions & CAS (PR #312, issue #258)

## Progress


**What shipped.** Phase W0 of the multi-writer concurrency plan:
`page_versions` (append-only, blob-backed page body chain) + CAS
conflict detection. Two writers racing one page → loser gets a
`PageConflictError`, no silent clobber.

**Schema v30:**
- `page_versions` table (mirrors `source_versions`: id, page_id,
  parent_id, merge_parent_id, blob_hash, title, activity_id, saved_at).
- `refs` rebuilt: dropped `owner_id REFERENCES sources(id)` FK, added
  `CHECK (kind IN ('source-content','source-derived','page-content'))`.
  The graph-model plan §4.3 flagged this as the trigger condition for a
  third ref kind.
- Migration seeds one root version per existing page (blob of
  body_markdown, legacy-import activity, no ref row — default-active =
  MAX(id), like sources at v20).

**Store layer** (`SQLiteWikiStore` + `WikiStore` protocol):
- `appendPageVersion` — CAS save: resolve head (ref → version_id, or
  MAX(id)), guard expected == head, insert blob + activity + version,
  update `pages.body_markdown` mirror (keeps FTS triggers working),
  UPSERT `page-content` ref.
- `pageHeadVersionID` — resolve active version (ref or MAX(id)).
- `pageVersionHistory` — full version chain, ULID-ordered.
- `revertPage` — repoint ref + update body mirror from version's blob.
- `PageConflictError` — carries expected + actual version id.
- All routed through `mutate()` (StoreEmissionExhaustivenessTests pass).

**CAS threading:**
- `PageUpsert.upsert` gains `expectedHeadVersionID` (default nil =
  blind write, backward-compatible). `writePage` routes through
  `appendPageVersion` when CAS is active, `updatePage` otherwise.
- `WikiStoreModel.save()` captures `loadedPageHeadVersionID` on page
  load, passes it as the CAS expectation. On `PageConflictError`,
  surfaces "Page Was Updated" alert. `wikictl` passes nil (blind write).

**wikictl:**
- `page history (--title X | --id Y)` — version chain (seq, id, date,
  title, blob hash, parent).
- `page revert (--title X | --id Y) --version V` — repoint ref + body.

**Tests:** 9 `PageVersionTests` (CAS conflict, CAS passes, blind write,
history ordering, parent linkage, revert body, revert head,
default-active, body mirror). `FreshSchemaParityTests` — fresh path
matches ladder (byte-identical). `StoreEmissionExhaustivenessTests` —
new mutators in EMIT partition. Fast tier: 2158 tests pass.

**What's deferred:** workspaces, overlay resolution, merge (W1/W2),
conflict UI (full editor affordance — W0 just shows a StoreError
alert), agent edit lock retirement (W1), `vacuum-pages` GC.

## Verification

Historical verification remains in the progress record above.
