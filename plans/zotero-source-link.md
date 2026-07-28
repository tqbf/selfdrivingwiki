# Handoff: link ingested Zotero files back to their library item

**Status:** investigation + design complete; **not implemented.** Branch not
created. No code changed yet. Pick this up, implement, push a PR (do NOT merge
to `main`).

## Goal

When a file was ingested from Zotero, the **Ingested File Detail View**
(`Sources/WikiFS/IngestedFileDetailView.swift`) should display a tag / link back
to the source Zotero library item — so the user can tell where a source came
from and jump back to Zotero. Files ingested via drag-drop or "Add from URL…"
should show nothing (or a neutral "Imported" tag).

## What I verified (read before starting)

I read every load-bearing file. Nothing here is speculation.

### The detail view today

`Sources/WikiFS/IngestedFileDetailView.swift`:

- `let file: IngestedFileSummary` is the model (line 9). The header section
  (lines 100–178) shows: filename (large title), a status label + size + created
  date row, the action buttons, and an extraction-log strip. **There is no
  "source / origin" display today.** The natural insertion point for a Zotero
  tag/link is in the header's secondary row (around line 113's `HStack(spacing:
  12)`) or as a small tag row just below it.
- `IngestedFileSummary` (`Sources/WikiFSCore/IngestedFileSummary.swift`) carries
  only: `id, filename, ext, mimeType, byteSize, createdAt, updatedAt, version`.
  **There is no origin / source field.** This is the struct that must grow.

### How Zotero ingest lands today (the seam to change)

`WikiStoreModel.ingestFromZotero(_:zoteroDir:)` in
`Sources/WikiFSCore/WikiStoreModel.swift` lines 690–702:

```swift
public func ingestFromZotero(_ attachment: ZoteroAttachment, zoteroDir: URL) async throws {
    switch ZoteroLocalStorage.resolve(attachment, zoteroDir: zoteroDir) {
    case .local(let path):
        let data = try await Task.detached(priority: .userInitiated) {
            try Data(contentsOf: path)
        }.value
        ingestFile(filename: path.lastPathComponent, data: data)   // <-- lands here
    case .unavailable(let reason):
        throw ZoteroIngestError.unavailable(reason)
    }
}
```

It calls `store.ingestFile(filename:data:)`, which is the **same shared seam**
drag-drop, URL ingest, and Markdown-folder import all use. The caller currently
knows the `ZoteroAttachment` (which has `.key`, `.parentItem`, `.filename`,
`.title`, `.linkMode`) AND the parent `ZoteroItem` (`.key`, `.title`,
`.creatorSummary`, `.date`, `.subtitle`) — but throws that provenance away
before the store write, because the store API only takes `filename:data:`.

`AddFromZoteroSheet.addSelected()` (`Sources/WikiFS/AddFromZoteroSheet.swift`
lines 328–348) is the call site that has the parent `ZoteroItem` in scope as
`selectedItem`:

```swift
for attachment in toIngest {
    do {
        try await store.ingestFromZotero(attachment, zoteroDir: zoteroDir)
    } catch { ... }
}
```

So the parent item key + title are available at the exact point ingest is
triggered — they just aren't threaded through.

### Storage layer

`Sources/WikiFSCore/SQLiteWikiStore.swift`:

- **Schema:** `ingested_files` table created at migration **v1→v2** (lines
  157–174). Columns: `id, filename, ext, mime_type, byte_size, content,
  created_at, updated_at, version`. `ingested_at` added at **v5→v6** (line
  259). Latest migration is **v7→v8** (`file_markdown_versions`, line 283–301).
  **Next migration is v8 → v9.**
- **Write:** `ingestFile(filename:data:)` lines 728–757 — INSERTs the row,
  returns `IngestedFileSummary`. This is the one shared write seam.
- **Read:** `listIngestedFiles()` lines 761–772, `getIngestedFile(id:)` lines
  775–784, and the decoder `ingestedSummary(from:)` lines 855–868. All three
  SELECT the same 8-column projection and decode via the private helper.
- **Projection:** `listAllIngestedFilesOrderedByID()` lines 828+ feeds
  `indexes/files.jsonl` and the File Provider mount as `IndexGenerators.FileRow`.
  Read the `IndexGenerators.FileRow` struct and the `files_by-{id,name}` path
  generators before deciding whether to surface the Zotero key on the mount
  too (see Open Question below).

### The `WikiStore` protocol

`Sources/WikiFSCore/WikiStore.swift` lines 53–54 — `ingestFile(filename:data:)`
is the only ingest method on the protocol. The read helpers
(`getIngestedFile`, `ingestedFileContent`) are on the protocol too. Any new
column read should land on the protocol (or stay concrete — see the note in the
protocol comment at lines 43–49 about read helpers staying concrete on
`SQLiteWikiStore`).

## Recommended implementation plan

This is the design I'd execute. It's additive and mirrors the exact patterns
already in the file (a nullable column added via migration, threaded through the
summary struct, decoded with NULL→nil handling, written from the one Zotero
seam).

### 1. Schema migration v8 → v9

In `SQLiteWikiStore.swift`'s migration ladder, after the `version < 8` block:

```swift
if version < 9 {
    try exec("ALTER TABLE ingested_files ADD COLUMN zotero_item_key TEXT;")
    try exec("ALTER TABLE ingested_files ADD COLUMN zotero_item_title TEXT;")
    try exec("PRAGMA user_version=9;")
    version = 9
}
```

Two columns (key + title) because the detail view will want to show the item
title, not just the key, and re-fetching from the API at view time is wrong (the
item could be renamed/deleted in Zotero between ingest and view). The key is
what the "View in Zotero" link needs.

### 2. Grow `IngestedFileSummary`

Add two nullable `String?` fields: `zoteroItemKey`, `zoteroItemTitle`. Update
the `init` and the doc comment (origin provenance is exactly the kind of
metadata this struct exists to carry — the raw `content` BLOB is deliberately
excluded, but these are small scalars).

### 3. Thread through the store write

- Add an overload or an extra defaulted parameter to `ingestFile` so the Zotero
  path can pass provenance without changing drag-drop/URL/folder callers. Two
  clean options:
  - **Option A (recommended):** a new store method
    `ingestFile(filename:data:zoteroItemKey:zoteroItemTitle:)` on the protocol,
    defaulting the two new params to `nil` for the existing callers — but the
    protocol's `ingestFile(filename:data:)` is already established. Cleanest is
    to add the two params to the existing signature with `nil` defaults so
    every caller keeps compiling and only `ingestFromZotero` passes non-nil.
  - **Option B:** keep `ingestFile(filename:data:)` unchanged and add a
    separate `ingestZoteroFile(filename:data:itemKey:itemTitle:)` on
    `SQLiteWikiStore` (concrete only, like the read helpers). `WikiStoreModel`
    calls it directly from `ingestFromZotero`.
  - Prefer **A** unless the defaulted-protocol-parameter feels wrong in review.
- `WikiStoreModel.ingestFromZotero` must receive the parent `ZoteroItem` (or
  at least its `key` + `title`). Update its signature to
  `ingestFromZotero(_ attachment: ZoteroAttachment, parentItem: ZoteroItem,
  zoteroDir: URL)`. `AddFromZoteroSheet.addSelected()` already has
  `selectedItem` in scope — pass it through.

### 4. Update the read path

`ingestedSummary(from:)` decoder (lines 855–868): add the two new columns,
reading NULL → nil with the same `sqlite3_column_type(...) == SQLITE_NULL` check
already used for `mime_type`. Update the SELECT column lists in
`listIngestedFiles`, `getIngestedFile`, and `listAllIngestedFilesOrderedByID`
(all currently select the same 8 columns in the same order — the decoder is
column-index-sensitive, so every SELECT must be extended in lockstep).

### 5. Surface in the detail view

In `IngestedFileDetailView.headerSection`, add a small origin tag row when
`file.zoteroItemKey != nil`:

- A tag/badge like `Label("Zotero", systemImage: "books.vertical")` + the
  item title (e.g. `file.zoteroItemTitle`) as a secondary line.
- A "View in Zotero" link button that opens
  `https://www.zotero.org/users/<libraryID>/items/<itemKey>/` in the default
  browser (`NSWorkspace.shared.open(_:)`). The `libraryID` lives in
  `ZoteroConfig` (`Sources/WikiFSCore/ZoteroConfig.swift`, `libraryID: String?`).
  The detail view will need the library ID plumbed in — either read
  `ZoteroConfig.load(from:)` (the view already has `store`, and
  `WikiStoreModel` holds the container directory) or pass it down from
  `WikiDetailView` (line 65 constructs the detail view). Check what's cheapest.
- Files with no Zotero key show nothing (or a neutral "Imported" tag — see
  Open Question).

### 6. Tests

- `Tests/WikiFSTests/IngestedFilesTests.swift` — existing ingest tests; extend
  with a row that writes via the Zotero seam and asserts the summary carries the
  key + title, and a NULL round-trip (drag-drop ingest → both fields nil).
- `Tests/WikiFSTests/WikiStoreModelZoteroIngestTests.swift` — update for the new
  `ingestFromZotero(_:parentItem:zoteroDir:)` signature.
- Run `swift test --filter IngestedFilesTests` and
  `--filter WikiStoreModelZoteroIngestTests`.

### 7. Build + gate

```
swift build          # compiles
swift test           # full suite
make check           # compile-only gate
```

Then push a PR. **Do not merge to `main`** (per `CLAUDE.md`).

## Open questions for the user (decide before/during implementation)

1. **Link target.** Open the Zotero **web** library
   (`zotero.org/users/<id>/items/<key>`) or the **local Zotero app** via the
   `zotero://select/library/items/<key>` URL scheme? The web URL is universal and
   needs no Zotero install; the `zotero://` scheme jumps straight into the
   desktop app but only works if Zotero is installed and registered. Web is the
   safer default; offer the app scheme as a stretch.
2. **Non-Zotero files.** Should drag-drop / URL / folder-imported files show a
   neutral "Imported" tag for symmetry, or stay empty? Empty keeps the header
   clean; a tag makes the origin row predictable in layout.
3. **Mount / `files.jsonl` projection.** Should the Zotero item key also appear
   in `IndexGenerators.FileRow` and `indexes/files.jsonl` so the File Provider
   mount exposes provenance to agents/Unix tools? That's a bigger surface change
   (read `IndexGenerators.FileRow`'s shape and the `files_by-*` generators
   first). Default: **no**, keep it UI-only for v1; revisit if the agent would
   benefit.

## Critical files (touch list)

| File | Change |
| --- | --- |
| `Sources/WikiFSCore/SQLiteWikiStore.swift` | v8→v9 migration; `ingestFile` signature; `listIngestedFiles`/`getIngestedFile`/`listAllIngestedFilesOrderedByID` SELECTs; `ingestedSummary` decoder |
| `Sources/WikiFSCore/IngestedFileSummary.swift` | add `zoteroItemKey`, `zoteroItemTitle` |
| `Sources/WikiFSCore/WikiStore.swift` | protocol `ingestFile` signature (if Option A) |
| `Sources/WikiFSCore/WikiStoreModel.swift` | `ingestFromZotero` signature + threading; `ingestFile` callers stay nil |
| `Sources/WikiFS/AddFromZoteroSheet.swift` | `addSelected()` passes `selectedItem` into `ingestFromZotero` |
| `Sources/WikiFS/IngestedFileDetailView.swift` | origin tag + "View in Zotero" link in `headerSection` |
| `Tests/WikiFSTests/IngestedFilesTests.swift` | NULL round-trip + Zotero-seam write |
| `Tests/WikiFSTests/WikiStoreModelZoteroIngestTests.swift` | updated signature |

## Skills to run (per `CLAUDE.md`)

- `swiftui-pro` before/after deciding the detail-view tag UI.
- `typography-designer` for the tag/title type scale (it sits in the header next
  to the `.callout` status row — match that weight).
- `macos-design` to keep the link/tag native and simple.

## Reference docs

- `plans/zotero-integration.md` — the original Zotero integration plan (the
  ingest seam, config, credential store, picker UI).
- `progress/` § "2026-06-17 — Zotero integration" — what shipped and how.
- `CLAUDE.md` — PR/merge rules, test commands.