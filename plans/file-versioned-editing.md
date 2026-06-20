# Design: file browsing/editing + git-lite versioned processed markdown

**Status:** Implemented 2026-06-20.
This is **PR2** of the File-Provider decouple effort (see
`plans/inline-file-view-and-provider-decouple.md`); it depends on nothing in PR1
(`plans/wikictl-file-reads.md`) and can land independently.

All file/line references verified against `main` @ `1d9b6a4` (schema at
`user_version = 7`).

## Goals

1. **Browse ingested files inline** in `IngestedFileDetailView`: render markdown,
   inline-preview PDFs, and a tabbed markdown⇄PDF view when both exist.
2. **Edit the *processed markdown*** with a reader/editor flip mirroring
   `PageDetailView` (Cmd-E), saving into a versioned store.
3. **Git-lite internal versioning:** the original source stays immutable; every
   edit to the processed markdown is appended as a new version, so we can revert
   to any earlier version. **Not exposed to the user yet** — but the data model
   and store API support it from day one.

## The core idea: immutable source + append-only version chain

Two distinct things, cleanly separated:

- **Source (immutable).** `ingested_files.content` already holds the verbatim
  bytes (PDF binary, or the original `.md`/`.txt` text) and is *never* edited.
  Keep it that way — it is the ground truth.
- **Processed markdown (versioned, editable).** A new append-only table holds a
  chain of full-text markdown snapshots per file. Version 1 is the
  extraction/derivation output; every user (or agent) edit appends a new version.
  "Go back to an earlier file" = revert, which itself appends.

This is "git-lite": an append-only object log with a `parent_id` lineage and a
HEAD that is always the latest version. No mutation, no deletion of history.

### Why full snapshots, not deltas

Store each version as the **complete markdown text**, not a diff. Markdown
documents are small, SQLite TEXT storage is cheap, reads and reverts are O(1)
with no patch-reconstruction chain, and the logic is trivial to reason about and
test. Delta/Δ compression can be added later *behind the same store API* (callers
never see whether a version is a snapshot or a reconstructed delta) if storage
ever matters — note it as a future optimization, don't build it now.

## Schema — migration v7 → v8

Append the next step to the ladder in `SQLiteWikiStore.bootstrapSchema()`
(`SQLiteWikiStore.swift:108`), following the existing pattern (guarded by
`if version < 8`, bump `PRAGMA user_version=8` at the end):

```sql
CREATE TABLE file_markdown_versions (
    id          TEXT PRIMARY KEY,        -- ULID → sorts == chronological == HEAD ordering
    file_id     TEXT NOT NULL REFERENCES ingested_files(id) ON DELETE CASCADE,
    parent_id   TEXT,                    -- previous version's id; NULL for v1 (the lineage)
    content     TEXT NOT NULL,           -- FULL markdown snapshot (never a delta)
    origin      TEXT NOT NULL,           -- 'extraction' | 'user' | 'agent' | 'revert'
    note        TEXT,                    -- optional edit summary (unused by UI for now)
    created_at  REAL NOT NULL
);
CREATE INDEX file_markdown_versions_file ON file_markdown_versions(file_id, id);
```

**Design decisions:**

- **HEAD = `MAX(id)` for a `file_id`.** ULIDs sort chronologically, so the latest
  version is the head. No separate head-pointer column is needed, which keeps the
  table strictly append-only. *(If a later feature wants "view an old version
  without committing to it," add `head_version_id` to `ingested_files` then — not
  now.)*
- **Append-only invariant:** never `UPDATE` or `DELETE` a version row (except the
  `ON DELETE CASCADE` when the whole file is removed). Every save is an `INSERT`
  with `parent_id` = the current head.
- **Revert = git-revert, not reset:** reverting to version *N* `INSERT`s a *new*
  version whose `content` copies *N*, with `parent_id` = current head and
  `origin = 'revert'`. History is never lost and "HEAD = latest" always holds.
- **Migration is additive** (new table + index only) — no change to existing
  tables, so existing v7 DBs upgrade safely and read connections opened
  pre-migration fall back gracefully, exactly like `page_embeddings` (v6→7).
- **No backfill in the migration.** Existing ingested files get versions lazily
  (see seeding). A migration can't run `pdf2md`, and decoding every stored blob
  inside the migration is needless weight.

## Seeding version 1 (`origin = 'extraction'`)

Where the first version comes from depends on the file kind:

- **Native markdown/text (`ext ∈ {md, markdown, txt}`):** decode
  `ingested_files.content` as UTF-8 and append v1 **at first need** (when the
  detail view opens and `processedMarkdownHead` is nil). Cheap and synchronous.
- **PDF:** capture `PdfExtractionService.convert` output. Two capture points,
  do **both**:
  1. **At the existing ingest-run conversion** (`AgentOperationRunner.swift:70-101`):
     the markdown is produced there and currently **discarded after staging** —
     persist it as v1 instead (and if v1 already exists, *reuse it* rather than
     re-running pdf2md, saving the VLM cost).
  2. **A standalone "Extract Markdown" action** in the detail view (and/or lazy
     on first open) so a PDF can have processed markdown **without** a full agent
     ingest. Runs the same `convert`, appends v1.
  Guard both against double-seeding (if a head exists, don't create another v1).
- **Other binaries (no markdown form):** no versions; the markdown tab is hidden.

## Store API (new seams)

Add to `WikiStore` (protocol, `WikiStore.swift`) + `SQLiteWikiStore` +
`WikiStoreModel`, mirroring the existing ingested-file seams
(`ingestFile`, `ingestedFileContent`):

```swift
struct FileMarkdownVersion: Identifiable, Hashable, Sendable {
    let id: PageID            // ULID (reuse PageID like IngestedFileSummary does)
    let fileID: PageID
    let parentID: PageID?
    let content: String
    let origin: String        // consider a Swift enum mapped to the TEXT column
    let note: String?
    let createdAt: Date
}

func processedMarkdownHead(fileID: PageID) throws -> FileMarkdownVersion?
func hasProcessedMarkdown(fileID: PageID) throws -> Bool
func processedMarkdownHistory(fileID: PageID) throws -> [FileMarkdownVersion]   // newest first
@discardableResult
func appendProcessedMarkdown(fileID: PageID, content: String,
                             origin: String, note: String?) throws -> FileMarkdownVersion
@discardableResult
func revertProcessedMarkdown(fileID: PageID, to versionID: PageID) throws -> FileMarkdownVersion
```

- `appendProcessedMarkdown` reads the current head, mints a new ULID, sets
  `parent_id` = head?.id, inserts. Returns the new version.
- Like other ingested-file reads on a not-yet-migrated DB, the read seams must
  fall back (empty/nil) when `file_markdown_versions` doesn't exist yet
  (`SQLiteWikiStore` already has this pattern — see the `ingested_files`
  table-absent fallbacks around `SQLiteWikiStore.swift:461-493`).
- `WikiStoreModel` wraps these as `@MainActor` conveniences (mirror
  `ingestedSourceBytes(id:)` at `WikiStoreModel.swift:802`).

## UI — rework `IngestedFileDetailView`

Today the view (`Sources/WikiFS/IngestedFileDetailView.swift`) shows metadata +
an "Ingest into Wiki" / "Open File" header and a `ContentUnavailableView`
("Raw Source") placeholder. Replace the placeholder with inline content; keep the
header.

**Content area by file kind:**

| File kind | Content |
| --- | --- |
| `md` / `markdown` / `txt` | Render head processed markdown via `MarkdownPreview` (the `PageReaderView` path). Cmd-E flips to a `TextEditor` over the head content (mirror `PageDetailView`/`PageEditorView`). |
| PDF **with** processed markdown | **Tabbed view:** "Markdown" tab (render head, editable via the same flip) + "PDF" tab (inline preview of the immutable source). |
| PDF **without** processed markdown | Inline PDF preview + an "Extract Markdown" action (when `PdfExtractionService.checkReady()`); shows readiness/progress like the existing extraction log. |
| Other binary | Keep the metadata + "Open File" fallback. |

**Editor flip** mirrors `PageDetailView` (`Sources/WikiFS/PageDetailView.swift`):
a toolbar `Edit`/`Done` button with `.keyboardShortcut("e", modifiers: .command)`,
`isEditing` state, reset `isEditing = false` on file-selection change and when an
agent run starts.

**Editing target = the versioned processed markdown** (the user's explicit
choice). The source bytes are never touched.

**Version granularity — one version per edit session, not per keystroke.** Unlike
`PageEditorView` (which debounce-autosaves into a single draft buffer), here each
*commit* should append exactly one version. Load head into a `@State` string,
edit freely, and `appendProcessedMarkdown(origin: "user")` **only on "Done
Editing"** (or view dismissal / selection change) **and only if the text differs
from head**. This keeps history meaningful (real edits) instead of keystroke
spam. Don't reuse `store.draftTitle/draftBody` — those are the page-selection
buffers; a file is not a page selection.

**PDFKit.** Inline PDF preview needs `PDFKit` (no current usage — confirmed).
Wrap `PDFView` in an `NSViewRepresentable`. Feed it the source bytes from
`store.ingestedSourceBytes(id:)` via `PDFDocument(data:)`. This is the project's
first PDFKit dependency — add the `import` and the small representable.

## Testing

- **Migration:** fresh DB reaches v8 with the table; an existing v7 DB upgrades,
  preserving all prior data; re-open is a no-op (idempotent). Mirror the existing
  migration tests.
- **Version chain:** v1 has `parent_id` NULL; v2's parent = v1; head = latest;
  `processedMarkdownHistory` is newest-first.
- **Revert:** reverting to v1 appends a v3 whose content == v1, head invariant
  holds, and v1/v2 rows are untouched (history preserved).
- **Cascade:** deleting an ingested file removes its `file_markdown_versions`
  rows.
- **Source immutability:** after any number of edits, `ingestedFileContent(id:)`
  returns the original bytes byte-for-byte.
- **Seeding:** native md/txt → v1 content == decoded source; PDF capture path
  stores v1; the double-seed guard prevents a second v1.
- **Pre-migration fallback:** read seams return nil/empty against a v7 store.

## Out of scope (note, don't build)

- **Exposing version history to the user** (a history/restore UI). The store API
  supports it; the UI is deferred per the user.
- **Delta compression** of versions — future optimization behind the same API.
- **Agent access to processed markdown** (e.g. `wikictl file cat --markdown`, or
  the agent preferring extracted `.md` over the raw PDF). A natural follow-up to
  PR1's `wikictl file` family, but separate.
- **Mount projection of processed markdown.** `plans/pdf-extraction.md` earlier
  envisioned extracted markdown as a *sibling `ingested_files` row projected on
  the mount*; **this design supersedes that** — a dedicated versioned table is
  cleaner, and the decouple effort is moving *off* the mount, so no projection.
  Reconcile/annotate `plans/pdf-extraction.md` so the two don't conflict.

## Definition of done

- v7→8 migration adds `file_markdown_versions`; all store seams implemented with
  pre-migration fallbacks.
- `IngestedFileDetailView` renders inline (markdown / inline PDF / tabbed), with a
  Cmd-E reader/editor flip that appends one processed-markdown version per edit
  session; source bytes never change.
- PDFs get v1 from the ingest-run conversion (reused, not re-run) and from a
  standalone "Extract Markdown" action; native md/txt seed v1 from source.
- New migration + store + version-chain + revert tests green; full `swift test`
  green.
- Apply the `swiftui-pro`, `typography-designer`, and `macos-design` skills to the
  detail-view rework (per `CLAUDE.md`).
- Update `PROGRESS.md` (newest-first) and this doc is linked from `PLAN.md`'s
  documentation index.
