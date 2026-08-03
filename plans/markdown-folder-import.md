# Import Markdown Folder — import an Obsidian vault, LogSeq graph, or any `.md` directory as source material

## Why

The user keeps an Obsidian vault of curated notes (and other Markdown collections)
and wants to bring that content into Self Driving Wiki as source material. The
imported `.md` files land in `ingested_files`, then the agent curates them into
wiki pages via the existing Ingest pipeline — same flow as drag-drop, URL fetch,
and Zotero.

## What it does

A new "Import Markdown Folder…" action opens a directory picker, recursively walks
the chosen folder for `.md` / `.markdown` files, reads their bytes, and stores each
as an `ingested_files` row. Hidden files and directories (prefixed with `.`) are
skipped — this naturally excludes `.obsidian/`, `.git/`, `.trash/`, etc. Duplicate
filenames in different subdirectories get a disambiguating suffix (`Note.md`,
`Note-1.md`, …).

Frontmatter and Obsidian-specific syntax (`[[wikilinks]]`, callouts, `![[embeds]]`,
`#tags`) are preserved verbatim — the agent decides what to do with them during
Ingest. This is a one-shot import, not a sync.

## Approach

Follows the Zotero integration pattern: pure core reader → model seam → SwiftUI
sheet → sidebar entry points.

### Core (WikiFSCore — pure, testable, no UI)

- `MarkdownFolderReader` — static `walk(directory:fileOps:)` that recursively
  discovers `.md` / `.markdown` files, reads their content, and deduplicates
  filenames. The filesystem is behind an injectable `FileOperations` protocol
  (production: `FileManagerFileOperations`; tests: `FakeFileOperations`).
- Result types: `WalkResult`, `MarkdownFile`, `WalkError` (conforms to
  `LocalizedError`).

### Model seam (WikiStoreModel)

- `importFromMarkdownFolder(directory:) async -> (imported: Int, errors: [String])`
  — walks the directory off the main actor via `Task.detached`, then calls the
  shared `store.ingestFile(filename:data:)` seam per file, collecting per-file
  errors without aborting the batch.

### UI (WikiFS)

- `ImportMarkdownSheet` — a sheet following `AddFromURLSheet`'s phase-enum pattern
  and `AddFromZoteroSheet`'s progress + error-collection pattern. Phases: `idle →
  scanning → ready(count) → importing → done(imported, errors) → failed`.
- Entry points in `SidebarView`: toolbar button + Files section header button
  (both always shown, no configuration gate), plus a `.sheet(isPresented:)` binding.

## Critical files

| File | Role |
| --- | --- |
| `Sources/WikiFSCore/MarkdownFolderReader.swift` | Pure recursive walk + dedup + read (injectable filesystem) |
| `Sources/WikiFSCore/WikiStoreModel.swift` | `importFromMarkdownFolder` model seam |
| `Sources/WikiFS/ImportMarkdownSheet.swift` | Sheet UI (phase enum, folder picker, progress, results) |
| `Sources/WikiFS/SidebarView.swift` | Entry point buttons + sheet binding |
| `Tests/WikiFSTests/MarkdownFolderReaderTests.swift` | 14 unit tests (FakeFileOperations) |
| `Tests/WikiFSTests/WikiStoreModelMarkdownImportTests.swift` | 12 integration tests (real SQLite + temp dirs) |

## Verification

- `swift test` — 476 tests green (includes 26 new tests)
- `make check` — compiles clean
- Manual: open app → toolbar "Import Markdown Folder…" → choose an Obsidian vault →
  all `.md` files appear under Files → select one → content renders with
  `[[wikilinks]]` + YAML frontmatter intact → run Ingest → agent processes it
- Works with LogSeq graphs (files in `pages/` and `journals/` subdirectories)
- Works with any directory of `.md` files
