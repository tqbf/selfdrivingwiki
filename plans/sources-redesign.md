# Sources Redesign

**Status:** Design phase — fleshing out before implementation.

## Overview

Four interrelated features that together rebrand "ingested files" as first-class **sources**:

1. **Wiki links to sources** — `[[source:display-name]]` syntax for linking from wiki pages to sources
2. **Source markdown in the File Provider** — project processed markdown alongside verbatim originals
3. **Editable display names** — human-readable titles separate from filenames, with link-updating on rename
4. **Full rename: "ingested file" → "source"** — types, tables, paths, CLI, UI, docs

## Decisions Locked In

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Link syntax | `[[source:display-name]]` prefix | Explicit, unambiguous, parseable |
| File Provider writes | Read-only view + app edit | Preserves the "SQLite is source of truth, mount is read-only" invariant |
| Title model | Separate `display_name` field | Preserves original filename provenance; default = filename |
| Link stability on rename | Update all referring `[[source:...]]` links | Same model as page renames; consistent mental model |
| Rename scope | Full rename + DB migration (v9→v10) | Clean break, no legacy naming |

---

## Feature 1: Wiki Links to Sources

### Syntax

```
[[source:My Paper]]            → link to source with display name "My Paper"
[[source:My Paper|my notes]]   → same, with alias "my notes"
[[source:paper.pdf]]           → link to source with display name "paper.pdf" (default)
```

The `source:` prefix is part of the wikilink target namespace — it's not a separate bracket syntax. The existing `[[...]]` grammar handles it; the parser extracts the prefix.

### Parser: `WikiLinkParser`

`ParsedLink` gains a `linkType` field:

```swift
public struct ParsedLink: Equatable, Sendable {
    public enum LinkType: Equatable, Sendable {
        case page       // [[Title]]
        case source     // [[source:Title]]
    }
    public let linkType: LinkType
    public let target: String       // without the "source:" prefix
    public let linkText: String
}
```

The regex stays the same. After extracting the raw target, if it starts with `source:`, strip the prefix and mark the type as `.source`. Everything else stays `.page`.

### Resolution

`[[source:display-name]]` resolves by:

1. **Display name match** — exact match against `sources.display_name` (case-insensitive, whitespace-collapsed)
2. **Filename fallback** — if no display name matches, try `sources.filename`
3. **Ambiguity** — if multiple sources match, pick the most recently updated; log a warning
4. **Unresolved** — rendered dimmed (same as unresolved page links today)

Resolution happens at:
- **Preview time** — `WikiLinkMarkdown.linkified()` calls an injected `isResolved: (String, LinkType) -> Bool` closure
- **Save time** — `PageUpsert.upsert()` parses links and writes to `source_links` table (see below)

### Markdown Rendering: `WikiLinkMarkdown`

Source links generate `wiki://source?id=<ulid>` URLs:

```swift
// Resolved source link:
[my notes](wiki://source?id=01ARZ3NDEKTSV4RRFFQ69G5FAV)

// Unresolved:
[Missing Source](wiki://missing?title=Missing%20Source)
```

The `target(from:)` helper and `isResolvedURL(_:)` are extended to handle the `source` host. A new helper extracts the source ID:

```swift
public static func sourceID(from url: URL) -> String? {
    guard url.scheme == scheme, url.host == "source",
          let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
          let id = components.queryItems?.first(where: { $0.name == "id" })?.value
    else { return nil }
    return id
}
```

### Navigation: `MarkdownPreview`

The `OpenURLAction` is extended:

```swift
.environment(\.openURL, OpenURLAction { url in
    if let title = WikiLinkMarkdown.target(from: url) {
        if WikiLinkMarkdown.isResolvedURL(url) {
            store.selectPage(byTitle: title)
        }
        return .handled
    }
    if let sourceID = WikiLinkMarkdown.sourceID(from: url) {
        store.selectSource(byID: sourceID)
        return .handled
    }
    // ... footnotes, systemAction ...
})
```

### Link Persistence: `source_links` Table

A new table mirrors `page_links` but references sources:

```sql
CREATE TABLE source_links (
    from_page_id TEXT NOT NULL REFERENCES pages(id),
    to_source_id TEXT NOT NULL REFERENCES sources(id),
    link_text   TEXT NOT NULL,
    PRIMARY KEY (from_page_id, to_source_id)
);
```

`PageUpsert.upsert()`:
1. Parses all links from body
2. Resolves page links → `page_links` table (existing behavior)
3. Resolves source links → `source_links` table (new)
4. Deletes old links of both types for this page, then inserts fresh

SQLiteWikiStore gains:
- `replaceSourceLinks(fromPageID:links:)` — mirror of `replaceLinks`
- `listSourceLinks()` → `[(from, to, linkText)]`
- Cascade delete: when a source is deleted, its `source_links` rows are removed

### Link Index: `indexes/links.jsonl`

Extended with a `type` field so agents see the unified link graph:

```jsonl
{"from":"<page-ulid>","to":"<page-ulid>","link_text":"alias","type":"page"}
{"from":"<page-ulid>","to":"<source-ulid>","link_text":"my notes","type":"source"}
```

`IndexGenerators.LinkRow` gains a `type: String` field. `linksJSONL` includes it.

### Rename Propagation

When a source's `display_name` changes:

1. Find all `[[source:<old-name>]]` occurrences in all page bodies
2. Rewrite to `[[source:<new-name>]]`
3. Re-save each affected page (bumping version, updating timestamps)
4. `source_links.link_text` is NOT updated (it stores the alias at link creation time, which may differ from the display name)

Same mechanism will apply to page renames (pre-existing gap) — the rename-update scan is a general capability, not source-specific.

---

## Feature 2: Source Markdown in the File Provider

### What Changes

Currently the File Provider projects verbatim bytes under `files/by-id/<ulid>.<ext>`. Processed markdown (the `file_markdown_versions` chain, from PDF extraction or user editing) is NOT projected.

After this change, when a source has processed markdown, a `.md` sibling is projected alongside the original:

```
sources/
  by-id/
    01ARZ3....pdf          ← verbatim original (always exists)
    01ARZ3....md           ← processed markdown (exists when hasProcessedMarkdown is true)
    01ARZ4....md           ← a markdown-only source: .md == original, .md also as processed
  by-name/
    My Paper--01ARZ3....pdf
    My Paper--01ARZ3....md
```

### Rules

- The `.md` sibling only appears when `store.hasProcessedMarkdown(fileID:)` returns true
- It serves the HEAD of the `source_markdown_versions` chain (née `file_markdown_versions`)
- It is **read-only** — consistent with the entire mount
- The original verbatim bytes are always projected regardless of markdown status
- For a source that IS markdown (`.md` ingested directly), the verbatim original IS markdown; a `.md` sibling still appears if there's a processed version chain (e.g., user edits) — the sibling content is the HEAD of the chain, which may differ from the original

### Projection Implementation

`Projection` gains:
- `sourceMarkdownNode(for:file:)` — creates a `ProjectedNode` for the `.md` sibling
- In `children(of: filesByID)` / `children(of: filesByName)`: when a source has processed markdown, include the `.md` sibling in the enumeration
- `contents(for:)` — when the identifier is a markdown sibling, serve the HEAD of the version chain

New identity prefix:
```swift
static let sourceMarkdownByIDPrefix = "source-markdown-by-id:"
```

### Editing Path

Editing stays through the app UI:
1. User opens source detail → clicks "Edit Markdown"
2. App shows the processed markdown in an editor
3. On save → `wikictl source edit-markdown <id> <content>` appends to the version chain
4. Change bridge signals → File Provider refreshes the `.md` sibling

A new `wikictl source edit-markdown` command is added (extends the existing `FileMarkdownVersion` append path).

---

## Feature 3: Editable Display Names

### Schema

`display_name TEXT` column added to `sources` (v10 migration):

```sql
ALTER TABLE sources ADD COLUMN display_name TEXT;
UPDATE sources SET display_name = filename;  -- backfill
```

### Default

Display name defaults to whatever filename was passed in at ingest time — which naturally includes the extension when the original file had one: `my-paper.pdf`, `notes.md`, `dataset.csv`. No transformation is applied; the user edits it if they want something different.

### Resolution

`[[source:My Paper]]` resolution:
1. Match `display_name` (case-insensitive, whitespace-collapsed)
2. Fall back to `filename` match
3. Multiple matches → most recently updated; log ambiguity

### Editing Surfaces

1. **Sidebar inline rename** — select source, press Enter, type new name (like Finder)
2. **Detail view** — editable title field at the top of `SourceDetailView`
3. **CLI** — `wikictl source rename <id> <new-display-name>`

### Rename → Link Update

```
wikictl source rename 01ARZ3... "My Renamed Paper"
  → scans all page bodies for [[source:My Old Name]]
  → rewrites to [[source:My Renamed Paper]]
  → re-saves affected pages
```

Implementation: a new `WikiStoreModel.renameSource(id:newDisplayName:)` method that:
1. Gets the old display name
2. Updates `sources.display_name`
3. Scans all pages via `store.listPages()` for `[[source:<old-name>]]`
4. Rewrites and re-saves affected pages
5. Posts change notification

---

## Feature 4: Full Rename — "Ingested File" → "Source"

### Database Migration (v9 → v10)

```sql
-- Rename the main table
ALTER TABLE ingested_files RENAME TO sources;
ALTER TABLE sources ADD COLUMN display_name TEXT;
UPDATE sources SET display_name = filename;

-- Rename the markdown version chain
ALTER TABLE file_markdown_versions RENAME TO source_markdown_versions;

-- New table for source links
CREATE TABLE source_links (
    from_page_id TEXT NOT NULL REFERENCES pages(id),
    to_source_id TEXT NOT NULL REFERENCES sources(id),
    link_text    TEXT NOT NULL,
    PRIMARY KEY (from_page_id, to_source_id)
);

PRAGMA user_version = 10;
```

SQLite's `ALTER TABLE ... RENAME TO` automatically updates FK references in `source_markdown_versions.file_id` to point to `sources(id)`. The index `file_markdown_versions_file` is renamed manually or recreated.

### Swift Type Renames

| Old Name | New Name |
|----------|----------|
| `IngestedFileSummary` | `SourceSummary` |
| `IngestedFileRow` | `SourceRow` |
| `IngestedFileDetailView` | `SourceDetailView` |
| `FilesSectionView` | `SourcesSectionView` |
| `FileMarkdownVersion` | `SourceMarkdownVersion` |
| `IndexGenerators.FileRow` | `IndexGenerators.SourceIndexRow` |
| `WikiSelection.ingestedFile(PageID)` | `WikiSelection.source(PageID)` |
| `WikiFSContainerID.fileByIDPrefix` | `WikiFSContainerID.sourceByIDPrefix` |
| `WikiFSContainerID.fileByID(_:)` | `WikiFSContainerID.sourceByID(_:)` |

### WikiStore Protocol Renames

| Old Method | New Method |
|------------|------------|
| `ingestFile(filename:data:...)` | `addSource(filename:data:...)` |
| `listIngestedFiles()` | `listSources()` |
| `getIngestedFile(id:)` | `getSource(id:)` |
| `ingestedFileContent(id:)` | `sourceContent(id:)` |
| `deleteIngestedFile(id:)` | `deleteSource(id:)` |
| `markIngestedFile(id:)` | `markSourceIngested(id:)` |
| `markedIngestedFileIDs()` | `markedSourceIDs()` |
| `hasProcessedMarkdown(fileID:)` | `hasProcessedMarkdown(sourceID:)` |
| `processedMarkdownHead(fileID:)` | `processedMarkdownHead(sourceID:)` |
| `processedMarkdownHistory(fileID:)` | `processedMarkdownHistory(sourceID:)` |
| `appendProcessedMarkdown(fileID:...)` | `appendProcessedMarkdown(sourceID:...)` |
| `revertProcessedMarkdown(fileID:...)` | `revertProcessedMarkdown(sourceID:...)` |

The verb "ingest" survives in operation contexts where it describes the agent action (e.g., `WikiOperation.ingest`), but storage/model surfaces use "source."

### File Provider Path Renames

| Old Path | New Path |
|----------|----------|
| `files/` | `sources/` |
| `files/by-id/` | `sources/by-id/` |
| `files/by-name/` | `sources/by-name/` |
| `indexes/files.jsonl` | `indexes/sources.jsonl` |

Container ID constants:
| Old | New |
|-----|-----|
| `files` | `sources` |
| `filesByID` | `sourcesByID` |
| `filesByName` | `sourcesByName` |
| `indexFilesJSONL` | `indexSourcesJSONL` |
| `fileByIDPrefix` | `sourceByIDPrefix` |
| `fileByNamePrefix` | `sourceByNamePrefix` |

### CLI Renames

| Old | New |
|-----|-----|
| `wikictl file list` | `wikictl source list` |
| `wikictl file cat` | `wikictl source cat` |
| `wikictl file export` | `wikictl source export` |
| `FileCommand.swift` | `SourceCommand.swift` |
| `FileCommand.Selector` | `SourceCommand.Selector` |

New commands:
- `wikictl source rename <id> <new-name>` — edit display name
- `wikictl source edit-markdown <id> [--content <text>|--file <path>]` — append to markdown version chain

### UI Label Renames

- Sidebar section: "Files" → "Sources"
- Detail view title: "Ingested File" → "Source"
- Status badges: "Ingested" → "Processed" (or keep "Ingested" since it describes the agent action, not the file itself)
- Menu items, button labels, error messages — all updated

### Agent System Prompt

The `CLAUDE.md` template is updated:
- `files/` → `sources/`
- `files.jsonl` → `sources.jsonl`
- Any prose references to "ingested files" → "sources"

### What Does NOT Change

- The **verb** "ingest" — the agent still "ingests" sources into the wiki. "Ingest" describes the operation, "source" describes the thing.
- `WikiOperation.ingest` — still the operation type
- `IngestPlan` — still the tiering strategy for the ingest operation
- `ingestingFileIDs` / `ingestedFileStatus` → these become `ingestingSourceIDs` / `sourceIngestedStatus` for consistency, but the concept is the same

---

## Migration & Compatibility

### Breaking Changes

This is a **breaking change** across the board:
- DB schema v9 → v10 renames tables
- File Provider paths change
- CLI surface changes
- The agent system prompt changes

Users with existing wikis will be migrated automatically on next launch (stepwise migration is already the pattern). No backward compatibility shim — the rename is thorough.

### Implementation Phasing

Given the size of the change, implementation should be phased:

**Phase A — Core rename + migration:**
- v9→v10 migration (rename tables, add `display_name`)
- Rename all Swift types, protocol methods, UI labels
- Rename File Provider paths and container IDs
- Rename CLI surface
- Update all tests to match
- **Gate:** `swift build` + `swift test` passes

**Phase B — Wiki links to sources:**
- Extend `WikiLinkParser` with `source:` prefix
- Add `source_links` table
- Extend `WikiLinkMarkdown` for `wiki://source` URLs
- Extend `MarkdownPreview` for source navigation
- Extend `IndexGenerators` for source links in JSONL
- **Gate:** click a `[[source:...]]` link in preview → navigates to source detail

**Phase C — Source markdown in File Provider:**
- Project `.md` siblings in `Projection`
- Add `wikictl source edit-markdown` command
- **Gate:** `.md` file visible in mount, editable through app

**Phase D — Editable display names + rename propagation:**
- `wikictl source rename` command
- Sidebar inline rename UI
- Detail view editable title
- Link-update scan on rename
- **Gate:** rename a source → existing `[[source:...]]` links update

---

## Design Principle: Content-Type Over Extension

Source behavior — extraction, preview rendering, File Provider projection — MUST be driven by detected MIME type (from content sniffing), not by the filename extension. The `ext` column is a display hint; `mimeType` is the behavioral authority.

### Why

- A PDF ingested without a `.pdf` extension must still be recognized as `application/pdf` and go through the PDF extraction pipeline
- A Markdown file mislabeled as `.txt` must still render as Markdown
- Content sniffing already exists in `URLIngestService` (magic bytes for PDF, PNG, JPEG, GIF, ZIP) — this principle just ensures all downstream code respects the detected type rather than re-deriving it from the extension

### Concrete Rules

| Decision | Uses | Not |
|----------|------|-----|
| Whether to run PDF extraction | `mimeType == "application/pdf"` | `ext == "pdf"` |
| Inline preview vs. "open in default app" | `mimeType` (text/*, application/pdf get inline; others get download button) | extension |
| File Provider `.md` sibling exists? | `hasProcessedMarkdown(sourceID)` returns true | extension |
| Icon in sidebar | `mimeType` | extension |
| Display name default | `filename` as passed in (no stemming) | — |

The `ext` column remains useful for:
- File Provider filename construction (`<id>.<ext>` for the verbatim file)
- Export filename derivation
- Display when the user hasn't set a custom display name

But it's never the sole input to a behavioral branch.

### Pre-Existing Extension-Check Bugs

These sites use `file.ext` (filename extension) where they should use `file.mimeType` (content-detected type). All should be fixed as part of Phase A (the rename touches all of them anyway).

**Severe — behavioral decisions gated on extension:**

| File | Line | Current | Should be | Impact |
|------|------|---------|-----------|--------|
| `IngestedFileDetailView.swift` | 48 | `isPDF = file.ext == "pdf"` | `file.mimeType == "application/pdf"` | PDF without `.pdf` extension gets no PDF viewer, no tabs, no extraction UI |
| `IngestedFileDetailView.swift` | 44-46 | `isMarkdownNative = file.ext == "md" \|\| file.ext == "markdown" \|\| file.ext == "txt"` | `file.mimeType?.hasPrefix("text/") == true` or content-sniff for markdown | Markdown file with no/nonstandard extension gets no Markdown preview |
| `AgentOperationRunner.swift` | 63 | `if file.ext == "pdf"` | `if file.mimeType == "application/pdf"` | PDF without `.pdf` extension skips PDF→Markdown extraction entirely, agent sees raw PDF bytes |

**Minor — cosmetic decisions gated on extension:**

| File | Line | Current | Should be | Impact |
|------|------|---------|-----------|--------|
| `IngestedFileDetailView.swift` | 480 | `symbol` switches on `file.ext` | Switch on `file.mimeType` | Wrong SF Symbol icon for mis-extended files |
| `EditorTab.swift` | 52 | Tab icon switches on `file.ext.lowercased()` | Switch on `file.mimeType` | Wrong tab bar icon |
| `IngestedFileRow.swift` | 110-115 | `symbol(forExtension:)` switches on `ext` | Switch on `mimeType` | Wrong sidebar icon |

**Acceptable as-is (but noted):**

| File | Line | Why it's OK |
|------|------|------------|
| `ZoteroClient.swift` | 282-284 | `isIngestable` is a first-pass UI filter on Zotero attachment filenames. Zotero's sync client names files with the correct extension; it's a heuristic, not a gate. Could be improved by using Zotero's `contentType` from the API, but low priority. |
| `WikiFSItem.swift` | 30-35 | Suffix checks are on File Provider node names that WE construct, not on original filenames. Our generated names have predictable extensions. Safe, but fragile if we ever change naming conventions. |

**Reference — already correct (MIME-driven):**

`URLIngestService.plan(for:)` is the model citizen: it normalizes the HTTP `Content-Type` header, content-sniffs ambiguous responses (magic bytes for PDF, PNG, JPEG, GIF, ZIP), and branches on the detected MIME type. The `ext` column is populated as a derivative for filename construction only.

---

## Open Questions (Resolved)

1. **Display name default** ✅ — whatever filename was passed in at ingest time, extension included. No stemming. The user edits it if they want.

2. **Source links outside pages?** Defer. `[[source:...]]` links in `index.md` or `CLAUDE.md` would require linkifying those non-page documents, which is a separate concern. Page bodies only for now.

3. **Case sensitivity** — case-insensitive, whitespace-collapsed matching for display name resolution, same normalization as page titles.

4. **Cascade delete** — already handled by `ON DELETE CASCADE` on `source_markdown_versions.file_id` (née `file_markdown_versions`). The FK auto-updates when the table is renamed.
