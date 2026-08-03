---
timestamp: 2026-07-08T221243Z
title: "2026-07-08 — #242: Bookmark created/updated timestamps"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-07-08 — #242: Bookmark created/updated timestamps

## Progress


Bookmarks now carry `createdAt`/`updatedAt` so the UI can show "date added"/"date
updated" (the companion sort/filter is #241). New **schema v27** migration adds
`created_at`/`updated_at REAL NOT NULL DEFAULT 0` to `bookmark_nodes`, backfilling
every legacy row to the migration time (legacy nodes have no recorded creation time).

**Reorder semantics (the issue's open question):** a **cross-folder move** bumps
`updatedAt`; a **pure same-parent reorder does NOT** (organizing siblings shouldn't
reshuffle a "date updated" view). Label rename also bumps. `moveBookmarkNode`
already computes `sameParent`, so the bump is conditional on `!sameParent`.

**What shipped:**
- **`BookmarkNode`** — `createdAt`/`updatedAt` fields (epoch defaults so existing
  in-memory test fixtures keep compiling; the store always stamps real values).
- **`SQLiteWikiStore`** — fresh schema + v26→v27 ladder step (ALTER + backfill,
  `pragma_table_info`-guarded; also tolerates a missing `bookmark_nodes` table so
  a hand-crafted minimal fixture can't crash mid-migration). `createBookmarkNode`
  stamps both on insert; `updateBookmarkNode` and cross-folder `moveBookmarkNode`
  bump `updatedAt`; `listBookmarkNodes` selects/decodes them.
- **`EditBookmarkSheet`** — read-only "Added …"/"Updated …" relative dates
  (absolute date as tooltip), mirroring `RecentChatRow`'s `chat.updatedAt`.
  "Updated" only appears when the node has actually changed.
- **Schema-version assertions** across the test suite bumped 26→27 (ULID
  `.count == 26` and the FileProvider UserDefaults version left untouched).
- **Tests (6 new):** create stamps both; rename bumps `updatedAt` not `createdAt`;
  cross-folder move bumps; same-parent reorder doesn't; the v26→v27 migration adds
  the columns + backfills a legacy row to ~now (parity-checked NOT NULL DEFAULT 0).
  1979 tests green.

## Verification

Historical verification remains in the progress record above.
