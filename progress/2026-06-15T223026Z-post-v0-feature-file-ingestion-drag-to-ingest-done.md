---
timestamp: 2026-06-15T223026Z
title: "2026-06-15 — Post-v0 feature: File ingestion (drag-to-ingest) — DONE ✅"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-06-15 — Post-v0 feature: File ingestion (drag-to-ingest) — DONE ✅

## Progress


Dragging a file into the app **ingests** it: stores the **raw bytes + metadata**
in SQLite as a NEW object kind (NOT a wiki page) and surfaces it read-only under
a new `files/` File Provider tree, so Unix tools/agents can read the verbatim
file. A removable "Files" section lists ingested files. Branch
`phase-5-file-ingest` (stacked on `phase-4-agent-wiki`, unmerged).

**User-chosen scope (locked):** raw bytes only (NO text extraction/conversion —
a PDF stays a PDF); instant synchronous ingest with a managed removable list (NO
async pipeline / status states). Types: md/txt/PDF, but any file stored
generically.

**Added / changed**
- **New `ingested_files` table** (id ULID, filename, ext, mime_type, byte_size,
  content BLOB, timestamps, version) — separate from `pages` and from the
  page-tied `attachments`. `bootstrapSchema()` is now a **stepwise idempotent
  migration**: existing v1 DBs (with pages) get only the v1→2 step that adds the
  table — pages data preserved (test-proven). `SQLiteStatement` gained a BLOB
  binder/reader (`SQLITE_TRANSIENT`).
- **Store API** (`SQLiteWikiStore` + minimal `WikiStore` protocol additions):
  `ingestFile(filename:data:)` (ext via pathExtension, mime via UTType,
  **100 MB soft cap**, ULID id), `listIngestedFiles`, `getIngestedFile`,
  `ingestedFileContent` (BLOB read on demand only), `deleteIngestedFile`.
  Metadata queries never load the BLOB.
- **⚠️ `changeToken()` now folds in files** → `"pCount:pSum:fCount:fSum"`, so an
  ingest/remove advances the sync anchor and `files/` (and the indexes) refresh.
  Without this the mount would never reflect ingested files. Regression-tested.
- **`files/` projection**: `files/by-id/<ulid>.<ext>` + `files/by-name/
  <escaped-stem>--<shortid>.<ext>` (original extension preserved; identical raw
  bytes). New identities + `WikiFSContainerID` constants; wired into
  `node`/`children`/`contents`/`.workingSet`. Extension reads are **resilient to
  the table not existing yet** (pre-migration → empty, never error). A
  **dedicated ingested-file `contentType` branch** (UTType by ext, `.data`
  fallback) — the page/`.json`/`.jsonl` type logic is untouched (no regression).
- **Agent-facing index**: `manifest.json` gains `file_count` + `files_by_id` +
  `file_index`; new `indexes/files.jsonl` (`{id,name,path,size,mime}` per line),
  token-cached like the other indexes.
- **`signalChange()`** signals the `files` containers (plus root + `indexes`,
  already there) on ingest AND removal.
- **Model**: `ingestedFiles` list (rebuilt from source); `ingest(fileURLs:)`
  (off-main byte read, rejects directories, batches, single signal) + sync
  `ingestFile`/`deleteIngestedFile` seams — the drop UI is a thin shell over
  these, so ingestion is testable/Bash-verifiable without a drag gesture.
- **UI**: sectioned sidebar (`Pages` / `Files`, Files shown only when non-empty);
  `IngestedFileRow` (SF-symbol-by-ext + size, Remove via context menu + swipe,
  no `.tag` so it can't collide with page selection); whole-window
  `.dropDestination(for: URL.self)` with a Reduce-Motion-aware accent highlight.
- Tests: 47 → **63** (ingest round-trip + byte-identity, ext/mime derivation,
  delete, the v1→2 migration, `changeToken` advancing on ingest/delete,
  `filesJSONL`, manifest `file_count`, by-name escaping, duplicate drops).

**Verified — real Finder drag of an 8 MB PDF (`[MS-NRPC] (1).pdf`), then Bash**
- SQLite row: ext `pdf`, mime `application/pdf`, `byte_size == length(content)
  == 7,970,045`.
- Served at `files/by-id/01KV6PAD….pdf` and `files/by-name/[MS-NRPC] (1)--
  01KV6PAD.pdf`; **byte-identical** to the SQLite blob (sha256 `b1b07a28…`,
  all 7,970,045 bytes) — raw bytes stored + served verbatim.
- `indexes/files.jsonl` + `manifest.json` `file_count` reflect it (after the
  ~5 s eventual-consistency settle). Read-only enforced (write rejected; SQLite
  untouched). Pages / Phases 1–4 not regressed. 63/63 tests; real-signed.

**Notes / known gaps**
- Generated indexes (`files.jsonl`, `manifest`) trail the raw `files/`
  enumeration by the usual ~5 s eventual-consistency window after a change.
- `files/` is a new top-level folder; on an already-materialized (upgraded)
  domain it needs a one-shot `WIKIFS_REENUMERATE=1` launch to appear (same as
  `indexes/` in Phase 4); fresh installs are fine.
- The drag gesture + ingest were confirmed via a real user drag; the sidebar
  **Remove** affordance is unit-tested + harness-verified at the store layer but
  was not visually gate-confirmed (user opted to finalize).
- Out of scope: text extraction, async/status queue, OCR, thumbnails, file
  detail view, linking files to pages, dedup, recursive directory ingest.

## Verification

Historical verification remains in the progress record above.
