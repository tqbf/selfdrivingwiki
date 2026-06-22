# Progress log

Newest first. To get up to speed: read `PLAN.md` then this file.

## 2026-06-22 — Right-click link context menus + whole-link selection

Implemented `plans/link-context-menus.md`. Right-clicking **any** link (wiki or
external) in a markdown preview now **selects the whole link run** (not just the
word under the cursor) and shows a **link-specific context menu**. Previously a
right-click on e.g. `Modern` inside `Spinellis's "Modern Debugging"` (from
`[[Modern Debugging (study)|Spinellis's "Modern Debugging"]]`) selected only
`Modern` and offered Share/Copy of that word.

**The Textual fork.** Textual is now a vendored in-repo path dependency
(`Packages/Textual/`, upstream `textual` 0.5.0 rev `01b5187`) so we could touch
its `internal` text-interaction layer (its `NSTextInteractionView` owns
right-click + the menu, and the `model.url(for:)` hit-test / selection model are
`internal` — no public seam). Three localized edits:
- Public `LinkMenuItem` + `LinkContextMenuBuilder` + a `linkContextMenu`
  `EnvironmentValues` entry and `.textual.linkContextMenu(_:)` modifier
  (`LinkContextMenu.swift`, `View+Textual.swift`).
- `TextSelectionModel.linkRange(for:)` (+ a layout helper) — expands from the
  clicked run slice over adjacent slices whose run shares the same URL, bounded
  to one layout so two same-URL links in neighboring paragraphs never merge.
- `NSTextInteractionView` right-click: `updateSelectionForContextMenu` selects
  the whole `linkRange` when on a link (word-range otherwise), and
  `makeContextMenu` builds link items from the builder (then Share/Copy of the
  selected link text). The env value threads through `AppKitTextInteractionOverlay`
  exactly like `openURL`. See `ISSUES.md` ("Vendored Textual fork") for re-sync.

**Menu items.** The pure `WikiLinkMenuBuilder` (`WikiFSCore`, no Textual dep)
classifies a link URL → `[WikiLinkAction]`; the view layer `WikiLinkContextMenu`
(`WikiFS`) wires them to closures in `MarkdownPreview` via
`.textual.linkContextMenu`:
- Missing wiki link → **Suggest…** (semantic-search submenu → navigate) + **Copy
  as Wiki Link** (`[[Target]]`).
- Resolved page/source link → **Find Similar…** + **Copy as Wiki Link**
  (`[[Target]]` / `[[source:Name]]`, `#fragment` preserved) + **Copy File Path**
  (the target's File Provider mount path — `pages/by-title/…` / `sources/by-id/…`,
  resolved async if the mount root isn't cached). Only page previews pass the
  spike, so it's offered there; the filename uses the page's canonical title.
- External link → **Open in Browser** + **Copy Link**.

**Not implemented (future).** **Edit Link** (enter edit mode + select the link
source) was deferred — it needs edit-mode plumbing and source-span selection, and
its behavior is an open question in the plan. It's not scaffolded in
`WikiLinkAction`.

**Tests.** 16 `WikiLinkMenuBuilderTests` (per-URL-kind action classification +
`[[…]]` reconstruction incl. fragments and percent-encoded titles). Full
`swift test` — 776 tests, 58 suites, 0 failures. `make check` clean.

On branch `feature/link-context-menus`.

## 2026-06-22 — Red missing wiki-links + context-menu design doc

Unresolved `[[Ghost Page]]` wiki links now render **red** in every markdown
preview, so dangling references are obvious at a glance. Resolved page/source
links, external links, and same-page anchors keep the standard link color and
behave exactly as before.

**How.** `WikiLinkMarkdown.linkified` already encodes resolution into the URL
host (`wiki://missing?title=…` for an unresolved target). A new custom Textual
`MarkupParser` — `WikiLinkStylingParser` (in `Sources/WikiFS`, since only WikiFS
depends on Textual) — wraps the default markdown parser and, after parsing,
recolors each `.link` run: `wiki://missing…` → `Color.red`, every other link →
the system link color (`NSColor.linkColor`, self-adapting). `MarkdownPreview`
switched `StructuredText(markdown: rendered)` →
`StructuredText(rendered, parser: WikiLinkStylingParser())` and adds
`.textual.inlineStyle(InlineStyle.default.link())` to neutralize Textual's
style-level link color: `WithInlineStyle` otherwise re-applies `InlineStyle.link`
to every `.link` run with a `keepNew` merge and would override the parser's
per-run colors. `.link` is kept on all runs, so missing links remain
hit-testable/forward-compatible. The change lives entirely inside
`MarkdownPreview`, so all four call sites (`PageDetailView`,
`SourceDetailView`, `ChangeLogDetailView`, `SystemPromptDetailView`) get it for
free.

**Why the system link color, not `DynamicColor.link`.** Textual's
`DynamicColor.link` can't be resolved inside the parser (it needs a color
environment the parser doesn't receive); `NSColor.linkColor` is the adaptive
semantic link color and is visually equivalent. (During implementation we hit
`Color.link` is a `ShapeStyle`, not a `Color` — fixed by using
`Color(NSColor.linkColor)`.)

**Also:** wrote `plans/link-context-menus.md` — the design doc for the
follow-on right-click link context-menu feature (Suggest for missing links,
Find Similar for any link, Copy as wiki-link / file path, Open in Browser +
Edit Link). It documents the blocker (Textual's `NSTextInteractionView` owns
right-click + the context menu internally; the `model.url(for:)` hit-test seam
is internal; no public API) and the operator-approved decision to vendor Textual
in-repo for that future PR. No context-menu code shipped here. Added a
`PLAN.md` doc-index row.

**Tests.** 10 new `WikiLinkStylingParserTests` (per-link-kind colors, external
links colored, non-link/code-span runs untouched, end-to-end via the linkifier).
`swift test` — 760 tests, 57 suites, 0 failures. `swift build` clean.

## 2026-06-21 — Phase D: Editable Display Names + Rename Propagation

Implemented `plans/phase-d-display-names-rename.md`. Sources can now be renamed
(`wikictl source rename --id <id> --to "New Name"`), and all `[[source:<old>…]]`
links in linking pages are automatically rewritten. Fragments (`#"quote"`) and
aliases (`|text`) are preserved byte-for-byte; code spans/fences are skipped.

**Architecture.** `WikiLinkRewriter.rewriteSourceBase` finds `[[source:Old…]]` spans
via the shared `WikiLinkSpan` regex, classifies them to ensure they're source links,
then structurally splices the bare-target byte range (everything between `source:`
and the first `#`/`|`) with the new name — not `replaceOccurrences`, so
`source:  old base#"q"` correctly matches and replaces only the base. The rename
drives the scan off `source_links` (O(linked-pages), zero false positives).

**Changes:**
- **`WikiLinkSpan`** (new): Shared `[[…]]` regex + `protectedCodeRanges`, extracted
  from `WikiLinkMarkdown` and `WikiFootnoteMarkdown` (they were copy-pasted).
  Both now delegate to `WikiLinkSpan`.
- **`WikiLinkRewriter`** (new): `rewriteSourceBase(in:matching:to:)` — pure helper,
  structurally splices the bare target, returns nil if no match.
- **`SQLiteWikiStore`:** `renameSource(id:to:)` updates `display_name` + bumps
  `version`, then iterates `sourceLinkingPages(to:)` to rewrite each linking page
  via `updatePage` + `replaceLinks`. `sourceLinkingPages(to:)` is a new read helper
  (one query: `SELECT DISTINCT from_page_id FROM source_links WHERE to_source_id = ?`).
- **`WikiStore` protocol:** Added `renameSource` method.
- **`WikiStoreModel`:** `renameSource(id:to:)` thin wrapper — calls store, refreshes
  summaries, updates open tab titles.
- **`sources.jsonl` `name` field:** Now `displayName ?? filename`.
- **By-name projection** (`Projection.swift`): `sourceNode`/`sourceMarkdownNode` now
  use `displayName ?? filename` for by-name names; `metadataVersion` bifurcated
  (by-name keys on display name, by-id stays filename-keyed).
- **CLI:** `wikictl source rename <selector> --to "<name>"` — resolves selector,
  calls `store.renameSource`, returns confirmation. Wired in `ArgumentParser.Command`,
  `SourceCommand.Action`, and `main.swift` dispatch.
- **`SystemPrompt`:** Documents `wikictl source rename` + auto-rewrite so the agent
  knows renames never orphan citations.
- **Tests:** 17 `WikiLinkRewriterTests` (basic swap, case-insensitive, whitespace-
  collapsed, fragment preservation, alias preservation, fragment+alias combined,
  code-span/fence skip, non-source links unchanged, multiple occurrences).
  5 store tests (`sourceLinkingPages`, `renameSource` update + rewrite + no-op).

**Tests.** 747 tests, 56 suites, 0 failures (+22 new).

On branch `feature/phase-d-display-names-rename`.

## 2026-06-21 — Markdown Anchors: section/passage links + footnote citations

Implemented `plans/markdown-anchors.md`. Wiki links can now point at a *place inside*
a document:

- `[[Page#Section]]` — navigate to page, scroll to heading
- `[[source:Paper#"quote"]]` — navigate to source, scroll to quoted passage
- `[[#"quote"]]` / `[[#Section]]` — scroll within current page
- All of the above work inside **footnotes** (`[^id]` + `[^id]: definition`)

**Architecture.** Pages cite by heading slug (Textual already applies `.id(slug)` to
headings); sources cite by quoted passage (render-time ids, nothing stored — extraction-safe).
`AnchorBlock.parse()` walks rendered markdown and builds an ordered block list;
`resolveAnchor()` resolves fragments slug-first then quote-first. `ScrollViewReader`
+ `proxy.scrollTo(id)` drives the scroll; `NumberedParagraphStyle` assigns sequential
`p1/p2/…` ids to paragraphs for quote-level precision. Navigation stashes a
`pendingScrollAnchor` tagged with target selection so a stale anchor can't misfire.

**Changes:**
- **`WikiLinkParser`:** `ParsedLink` gains `fragment: String?`. `splitFragment(_:)` splits
  raw target on first `#` before classification. Same-page anchors (empty base) are
  skipped in `parse()` but rendered in `linkified`.
- **`WikiLinkMarkdown`:** `markdownLink` gains `fragment:` param; `markdownAnchorLink`
  builds `wiki://anchor#…` for same-page. `fragment(from:)` decodes fragments from URLs.
  `isSamePageAnchor(_:)` identifies anchor-host URLs. `fragmentAllowed` character set
  encodes `#`, `"`, space, `%` in fragment. `resolvedKind(from:)` recognizes `"anchor"`
  host (returns nil — same-page is not a navigation).
- **`AnchorBlock`** (new): Struct with `Kind` (heading/paragraph), `id`, `text`.
  `parse(_:)` walks rendered markdown in document order, skipping lists/code/tables/
  blockquotes. `makeSlug(_:counts:)` does GFM-style slug generation with `-1/-2` dedup.
  `resolveAnchor(_:in:)` — pure function: slug-match first, then quote substring match.
- **`NumberedParagraphStyle`** (new): Custom Textual `ParagraphStyle` that applies
  `.id("p\(n)")` sequentially. Counter resets before each render.
- **`MarkdownPreview`:** Wrapped in `ScrollViewReader`; `NumberedParagraphStyle` applied
  to `StructuredText`; block list built after render; `OpenURLAction` dispatches
  same-page anchors locally and passes fragment through to `selectPage`/`selectSource`;
  `.task` consumes `pendingScrollAnchor` with 50ms layout-delay scroll.
- **`WikiStoreModel`:** `selectPage(byTitle:anchor:)` / `selectSource(byDisplayName:anchor:)`
  stash a `pendingScrollAnchor` tagged with target `WikiSelection`.
  `consumePendingScrollAnchor(for:)` atomically reads and clears it.
- **`SystemPrompt`:** Documented footnote grammar, cite-by-quote, page-section anchors,
  slug rules, same-page anchors, and a worked footnote example.
- All `MarkdownPreview` call sites (`PageDetailView`, `SourceDetailView`,
  `ChangeLogDetailView`, `SystemPromptDetailView`) pass `currentSelection: store.selection`.

**Tests.** 725 tests, 55 suites, 0 failures (41 new: 14 parser #-split, 11 linkified
fragment, 16 AnchorBlock).

On branch `feature/markdown-anchors`.

## 2026-06-21 — Deferred MarkdownPreview rendering

`MarkdownPreview` now shows a `ProgressView` spinner immediately and defers regex
preprocessing (footnote expansion + wiki-link linkification) via `Task.yield()`, so the
view shell appears instantly and the rendered text fills in after. For large markdown
documents this avoids blocking the main thread during body evaluation.

**Changes:**

- **`MarkdownPreview`:** Replaced the synchronous `renderedMarkdown` computed property
  with `@State private var renderedBody: String?` and `.task(id: markdown)`. The task
  yields first so the `ProgressView` renders, then runs the preprocessing on the main
  actor, then yields again so the frame commits. A task key prevents stale renders
  when the markdown changes mid-processing.

**Tests.** `swift test` — 684 tests, 54 suites, 0 failures.

On branch `feature/deferred-markdown-rendering`.

## 2026-06-21 — Phase C: source markdown in the File Provider

Implemented `plans/phase-c-source-markdown-projection.md`. PDFs with extraction output now
project a `.md` sibling alongside the verbatim file in both `sources/by-id/` and
`sources/by-name/`. The change bridge now sees chain edits, so extraction / edit / revert
refresh the mount without a relaunch. Every source gets a chain: markdown-native sources
self-seed v1 from verbatim bytes (origin `"source"`), PDFs seed from extraction.

**Changes:**

- **Change bridge (`SQLiteWikiStore`):** `sourceMarkdownVersionCount()` helper added
  (resilient `COUNT(*)` over `source_markdown_versions`, mirrors `logRowCount`).
  `changeToken()` gains an 8th component (`smvCount`), so any append to the versions
  table advances the File Provider sync anchor. Previously `appendProcessedMarkdown`
  and `revertProcessedMarkdown` left the token unchanged.

- **Projection (`Projection`):** `sourceMarkdownByID` / `sourceMarkdownByName` identity
  prefixes with constructors and a `sourceMarkdownULID` parser (parity with verbatim
  source identity). `sourceMarkdownNode(for:source:head:)` versions the sibling off the
  HEAD row (`contentVersion = Data(head.id.rawValue.utf8)`), naturally distinct from
  the verbatim node's version. `sourceNodes(byName:)` fetches all HEADs in one query
  (`processedMarkdownHeadsBySource()`) and emits a sibling only for non-markdown-native
  sources with a chain — markdown-native sources don't need a sibling (the verbatim
  `<id>.md` is the content). `contents(for:)` serves HEAD content for sibling ids.

- **One-query HEAD read (`SQLiteWikiStore`):** `processedMarkdownHeadsBySource()` joins
  `source_markdown_versions` against `MAX(id) GROUP BY file_id` in a single query.
  Returns `[String: SourceMarkdownVersion]` keyed by source id; empty dict on failure.

- **Self-seed, MIME-keyed (`WikiStoreModel`):** `processedMarkdownHead(for:)` self-seeds
  v1 from verbatim bytes for markdown-native sources (`mimeType.hasPrefix("text/")`,
  not `file.ext`). Origin `"source"` (distinct from `"extraction"` and `"user"`).
  Double-seed guard prevents duplicates. `headVersion` is never nil — every source has
  a chain, and the original content is always available as the baseline.

- **CLI (`wikictl source edit-markdown`):** New subcommand appends a `"user"` version
  to an existing chain. Accepts `--content` or `--file`. Refuses with a clear error
  when no extraction baseline exists (exit 1). `signalChange()` so the mount refreshes.

- **Index (`IndexGenerators`):** `SourceIndexRow` gains `has_markdown: Bool`.
  `sourcesJSONL` emits it in fixed key order (`id, name, path, size, mime, has_markdown`).
  True for every source (all have chains after self-seed). The agent uses `mime` to
  distinguish PDFs (have a `.md` sibling) from markdown-native sources (verbatim is content).

- **Agent prompt (`SystemPrompt`):** One line documenting the `.md` sibling convention.

**Tests.** `swift test` — 684 tests, 54 suites, 0 failures.

On branch `feature/phase-c-source-markdown-projection`.

## 2026-06-21 — Content-type over extension

Implemented `plans/content-type-over-extension.md` — made `mime_type` content-authoritative
rather than extension-derived. This closes the circularity bug where a PDF renamed `.txt`
was mis-typed and skipped extraction.

**Changes:**

- **`ContentSniff` (new):** Extracted `URLIngestService.sniffContentType` into a pure
  `WikiFSCore` helper (`mimeType(of:)`) shared by all ingest paths.
- **`addSource` MIME-first:** Added `mimeType:` parameter to the protocol and
  `SQLiteWikiStore`. Priority: explicit param → magic-byte sniff → ext fallback. A PDF
  named `.txt` now stores `application/pdf`.
- **`WikiFSItem.contentType` MIME-first:** Added `mimeType: String?` to `ProjectedNode`;
  `sourceNode` carries `file.mimeType`; `WikiFSItem.contentType` prefers
  `UTType(mimeType:)` over `UTType(filenameExtension:)`.
- **Zotero `isIngestable`:** Prefers API `contentType` (`application/pdf`, `text/*`) over
  filename extension; extension check remains as fallback.
- **Stale comment fix:** `AgentOperationRunner:130` comment now matches the MIME-based
  guard it annotates.
- **Grep guard:** `ExtensionCheckGuardTests` fails if a new behavioral extension check
  appears outside the allowlisted files.

**Tests.** `swift test` — 653 tests, 53 suites, 0 failures.

On branch `feature/content-type-over-extension`.

## 2026-06-21 — Phase B: `[[source:display-name]]` wikilinks

Wiki pages can now link to sources with `[[source:display-name]]` syntax. Clicking a
source link in the preview navigates to that source's detail view — the same seam
page links use. Source links render as `wiki://source?title=<display-name>`
(mirroring `wiki://page?title=…`), resolution happens at click time via
`selectSource(byDisplayName:)`, and a single `(String, LinkType) -> Bool` closure
serves both link kinds.

**Changes:**

- **Parser (`WikiLinkParser`):** `ParsedLink` gains a `LinkType` enum (`.page` /
  `.source`) with a `.page` default so every existing call site compiles unchanged.
  A new `classify()` method extracts the `source:` / `page:` prefix and re-normalizes
  the remainder (`[[source: X]]` → target `"X"`). `parse()` deduplicates per
  `(kind, target)`; `[[source:]]` (empty prefix target) is skipped as a non-link.
  The `page:` prefix is an explicit escape: `[[page:source:foo]]` links to a page
  literally titled "source:foo".

- **Shared normalizer (`WikiText`):** `WikiText.normalized()` replaces three private
  `collapseWhitespace` copies (in `WikiLinkParser`, `WikiLinkMarkdown`,
  `HTMLToMarkdown`). One source of truth for whitespace collapsing across the wiki
  subsystem.

- **Renderer (`WikiLinkMarkdown`):** `linkified` closure signature changed to
  `(String, LinkType) -> Bool`; source links render as
  `wiki://source?title=<display-name>` when resolved, `wiki://missing?title=…` when
  not. `markdownLink` is now kind-aware; `resolvedKind(from:)` returns `.page` /
  `.source` / `nil` for the click handler. `isEmptyPrefix()` skips `[[source:]]`
  in both parser and renderer.

- **Resolution (`SQLiteWikiStore`):** `resolveTitleToID` is now case-insensitive
  (`COLLATE NOCASE`) for parity with source resolution. `resolveSourceByName`
  matches `display_name` first, falling back to `filename`; multi-match tiebreak
  by `updated_at DESC`. `WikiStore` protocol extended with `resolveSourceByName`.

- **Navigation (`WikiStoreModel`):** `sourceExists(displayName:)` mirrors
  `pageExists(title:)` for the render closure. `selectSource(byDisplayName:)`
  mirrors `selectPage(byTitle:)` line for line — resolves display name → ULID,
  records navigation history, opens the source's tab (reusing an already-open
  tab). `MarkdownPreview`'s `OpenURLAction` dispatches by kind.

- **Persistence (`SQLiteWikiStore.replaceLinks`):** extended to write BOTH
  `page_links` and `source_links` in ONE `BEGIN IMMEDIATE` transaction. Wipes
  both tables for the page, then re-inserts resolved subsets atomically.
  `listAllSourceLinks()` added with `type: "source"`.

- **Index (`IndexGenerators`, `Projection`):** `LinkRow` gains `type: String`
  (default `"page"`). `linksJSONL` emits `type` in fixed key order
  (`from, to, link_text, type`). The File Provider projection merges
  `listAllLinks()` + `listAllSourceLinks()` — page rows first, then source rows,
  each sorted by `(from, to)`.

- **Agent prompts:** `SystemPrompt` cheatsheet now lists `wikictl source` commands
  and documents the `type` field in `links.jsonl`. `WikiOperation` Ingest/Query
  prompts updated from `wikictl file` to `wikictl source`. `wikictl --help`
  usage string updated in `ArgumentParser`.

- **Stale help text + prompt references fixed:** `ArgumentParser` usage string,
  `main.swift` comment, `WikiOperation` Ingest/Query prompts, and `SystemPrompt`
  cheatsheet all said `wikictl file` instead of `wikictl source`. The agent was
  running `wikictl file` from its prompt instructions and getting "unknown
  command". Three commits pushed to the PR to stamp this out.

**Tests.** `swift test` — 635 tests, 50 suites, 0 failures.

On branch `feature/phase-b-source-wikilinks`. PR #33.

## 2026-06-21 — Phase A: rename "ingested file" → "source" throughout (PR #31)

Full rename across database, types, UI, CLI, File Provider, and agent prompts. v10
migration renames `ingested_files` → `sources` and `file_markdown_versions` →
`source_markdown_versions`; adds `display_name` column (backfilled from `filename`);
creates `source_links` table. All Swift types renamed (`IngestedFileSummary` →
`SourceSummary`, etc.), all views renamed (`IngestedFileDetailView` →
`SourceDetailView`, `IngestedFileRow` → `SourceRow`, `FilesSectionView` →
`SourcesSectionView`), CLI renamed (`wikictl file` → `wikictl source`), mount paths
renamed (`files/` → `sources/`), agent prompts updated. Six extension-check bugs
fixed (use `mimeType` instead of `ext` for behavioral decisions). 596 tests green.

Branches `feature/sources-redesign` (PR #31) → `feature/phase-b-source-wikilinks` (PR #33).

## 2026-06-20 — Standalone Extract Markdown fixes + Stop-button overhaul

The standalone "Extract Markdown" button in `IngestedFileDetailView` had two bugs
from its divergence with the ingest-path extraction in `AgentOperationRunner`:

1. **Sidebar PDF Conversion box never appeared.** `runExtraction()` used its own local
   `@State` variables (`isExtracting`, `extractionLog`), but
   `AgentTranscriptSidebar.showsConversion` checked `launcher.isExtracting` and
   `launcher.extractionLog` — which were never set by the standalone path. The sidebar
   auto-expanded (because `extractingFileIDs` was inserted), but showed only an empty
   Agent Activity section.
2. **Stop button was a no-op.** The extraction `Task` was created inline
   (`Task { await runExtraction() }`) and never stored. `AgentLauncher.stop()` cancelled
   only `ingestTask` and `process`, both `nil` during standalone extraction.

Additional improvements found during the fix pass:

4. **Ingest button stayed active during extraction.** The "Ingest into Wiki" button was
   not disabled while the same file was mid-extraction, risking a double operation.
5. **Ingest-path always re-extracted PDFs.** `runMultiIngest` ran pdf2md for every PDF
   even when markdown had already been extracted via the standalone button — wasting a
   heavy conversion and taking the extraction slot unnecessarily.
6. **Single Stop button conflated two independent operations.** The sidebar had one
   shared Stop button that called `launcher.stop()` (kill everything). Two distinct
   buttons now match the two independent locks: Stop Conversion (extraction slot only)
   and Stop Agent (spawn slot only).

**Changes:**

- **`IngestedFileDetailView.runExtraction()`** now sets `launcher.isExtracting`,
  `launcher.extractionPID`, and `launcher.extractionLog` (with `onProgress`/`onStart`
  callbacks to `PdfExtractionService.convert`) so the sidebar's PDF Conversion box
  renders with live progress. The local `@State extractionLog` is removed — all log
  output goes to `launcher.extractionLog`; the detail view header keeps only a minimal
  "Extracting…" spinner driven by `isThisFileExtracting`.
- **`extractTask`** added to `AgentLauncher` (mirrors `ingestTask` for the standalone
  path). Stored/cleared by the Extract button action; cancelled by `stopExtraction()`.
  `PdfExtractionService.run()`'s `onCancel` handler terminates the pdf2md subprocess.
- **Ingest button disabled during extraction** — `|| isThisFileExtracting` added to the
  `.disabled()` guard in `IngestedFileDetailView`.
- **`AgentOperationRunner.runMultiIngest`** now checks `store.processedMarkdownHead(for:
  file)` before running pdf2md. If markdown was already extracted (via the standalone
  button or a prior ingest), it reuses the existing content and skips extraction
  entirely — no extraction slot taken, no subprocess spawned.
- **`AgentLauncher` split into three stop methods:**
  - `stopExtraction()` — cancels `extractTask` (or `ingestTask` during ingest-path
    extraction phase), clears `isExtracting` / `extractionPID` / `extractingFileIDs` /
    `extractionLog`. Never touches the agent process.
  - `stopAgent()` — cancels `ingestTask`, terminates the claude process, calls
    `finish()`. Never touches extraction flags.
  - `stop()` — convenience that calls both (preserved for surfaces that still want a
    kill-everything affordance).
- **`AgentTranscriptSidebar`** header simplified to just the "Transcript" label. The
  PDF Conversion box now has its own red Stop button (visible when
  `launcher.isExtracting`). The Agent Activity section has its own red Stop button
  (visible when `launcher.isRunning` or `!launcher.ingestingFileIDs.isEmpty`).

**Tests.** `swift test` — 596 tests, 50 suites, 0 failures (+10 from the prior
baseline of 586):
- `AgentExtractionLockTests` (+7: `stopCancelsExtractTask`,
  `stopWithNoExtractTaskIsNoOp`, `isExtractingFlagExposedByLauncher`,
  `stopExtractionCancelsExtractTask`, `stopExtractionClearsExtractionFlags`,
  `stopExtractionWithNoTaskIsSafe`, `stopAgentDoesNotClearExtractionFlags`)
- `ProcessedMarkdownTests` (+3: `pdfHeadNilBeforeExtraction`,
  `seedPdfMarkdownCreatesHead`, `seedPdfMarkdownDoubleSeedReturnsExisting`)

## 2026-06-20 — Serialized claude spawn slot + separate extraction lock

The shared `AgentLauncher` silently dropped a second run (`guard !isRunning`), and
one `ingestingFileIDs` set fused the pdf2md extraction phase with the agent-
ingestion phase — so a pure extraction mislabeled rows "Ingesting…" and greyed out
other files' Ingest buttons even though the slot was free. Two independent locks now
replace the single `isRunning` guard; the phase flags are split. See
`plans/extraction-vs-ingestion-lock.md` (Option B).

- **Spawn slot (`AgentLauncher`):** all `claude -p` spawns (ingest/query/lint)
  serialize through a FIFO, cancellation-aware slot (`awaitSpawnSlot` /
  `releaseSpawnSlot`); the silent-drop guard is gone, so a queued run waits and
  runs after the current one. `run`/`startInteractiveQuery` are `async`; preflight
  and staging run after the slot is acquired so every early-return releases it.
- **Separate extraction lock:** pdf2md conversions serialize on a *distinct*
  `awaitExtractionSlot`/`releaseExtractionSlot` (same shape, independent state) that
  never touches the spawn slot or the edit lock — so a query runs during an
  extraction and editing stays unlocked while a PDF converts. Both the ingest-path
  conversion and the standalone `Extract Markdown` action take it.
- **Phase-flag split:** `ingestingFileIDs` (set only at agent-spawn commit via a new
  `run` param, cleared in `finish()`) is now distinct from `extractingFileIDs`
  (pdf2md phase). `runMultiIngest` no longer pre-sets `ingestingFileIDs`. Rows show
  "Extracting…" vs "Ingesting…" (pure `rowStatus` predicate); the cross-file Ingest
  greyout (`isAnyFileIngesting = !ingestingFileIDs.isEmpty`) is now extraction-free.
- **Query page:** mounts the orange `AgentRunBanner` and scopes its debug cluster to
  active query runs only (`showsQueryDebugControls`); resets to the conversation
  when idle. The toolbar glow / transcript auto-open now key off `extractingFileIDs`
  so a pure extraction still surfaces the transcript.

**Cancellation.** A file is marked ingested only by the agent's `wikictl log append
--kind ingest`; an ingest interrupted before the agent spawns marks nothing
(`hasBeenIngested` stays `false`), and extracted markdown seeded before the agent
run survives a later cancel.

**Verified.** `swift build` clean (no warnings). `swift test` — 586 tests, 50
suites, 0 failures (+10 `AgentExtractionLockTests`, +6 `AgentSpawnSlotTests`).

## 2026-06-20 — Grey out Ingest/Extract buttons during any file ingest

The "Ingest into Wiki" and "Extract Markdown" buttons in
`IngestedFileDetailView` were only disabled when the agent was running or
the same file was being ingested. During the PDF-conversion phase (before
agent launch), both buttons were still active — a second ingest could be
started concurrently.

- **`IngestedFileDetailView`:** added `isAnyFileIngesting` parameter
  (true when any ingest is in flight, not just this file's). Both buttons
  now include it in their `.disabled()` guards.
- **`WikiDetailView`:** plumbed `isAnyFileIngesting` from
  `!launcher.ingestingFileIDs.isEmpty`.

**Verified.** `swift build` clean. PR #28.

## 2026-06-20 — Fix transcript sidebar disappearing on tab switch

The `AgentTranscriptSidebar` had Query-specific suppression that forced
`isTranscriptExpanded = false` when entering the Query tab and guarded
visibility/auto-open/toggle-enable with `!isQuerySelected`. This caused the
sidebar to collapse on entry to Query and stay collapsed when switching back to
other tabs — the state didn't recover.

- **`ContentView`:** removed `!isQuerySelected` from the sidebar visibility
  guard, the auto-open-on-agent-start guard, the auto-open-on-ingest guard,
  and `canShowTranscript`. Removed the forced `isTranscriptExpanded = false`
  in `onChange(of: store.selection)`. Removed the now-unused
  `isQuerySelected` computed property. (-16/+8)

The sidebar now persists across all tab switches and works consistently
regardless of which detail view is active.

**Verified.** `swift build` clean; `swift test` — 570 tests, 48 suites, 0
failures. PR #27.

## 2026-06-20 — Fix Zotero "View in Zotero" link + PageDetailView markdown alignment

Fixed two bugs found in live use after the Zotero source-link feature landed:

**"View in Zotero" link 404s.** The detail view constructed
`https://www.zotero.org/users/<numericLibraryID>/items/<itemKey>/`, but
Zotero's web library uses username slugs in URLs, not numeric IDs — the
numeric ID only works on the API host (`api.zotero.org`). Confirmed this is
the same root cause as [Zutilo #268](https://github.com/wshanks/Zutilo/issues/268).
Switched to the `zotero://select/library/items/<key>` URI scheme, which
opens items directly in the Zotero desktop app and needs no library ID at all.

- **`IngestedFileDetailView`:** removed the `zoteroLibraryID` parameter
  (no longer needed); `zoteroItemURL` now builds
  `zotero://select/library/items/<key>` instead of the broken web URL.
- **`WikiDetailView` / `ContentView`:** removed the `zoteroLibraryID`
  plumbing — the property was only threaded for this one link.

**Markdown preview appears centered.** `MarkdownPreview`'s VStack inside its
`ScrollView` was centered by default (SwiftUI `ScrollView` centers its
content). Added `.frame(maxWidth: .infinity, alignment: .leading)` after
the VStack's padding so content left-aligns within the scroll area.

**Page editor inset mismatch.** The `PageDetailView` editor used
`contentInset - 5` (7pt) while the header used 12pt; the markdown preview
was passed `contentInset: false` (0pt). Changed both to 12pt so the text
lines up with the header title and Edit button.

**Verified.** `swift build` clean; `swift test` — 570 tests, 48 suites, 0
failures.

## 2026-06-20 — Zotero source link on ingested files

Implemented `plans/zotero-source-link.md`. Files ingested from Zotero now carry
their parent library item's key + title as provenance, so the **Ingested File
Detail View** shows a "Zotero" tag with the item title and a "View in Zotero"
link back to the web library (`zotero.org/users/<id>/items/<key>/`).

- **Schema v8→v9:** two nullable TEXT columns (`zotero_item_key`,
  `zotero_item_title`) on `ingested_files`. NULL for drag-drop / URL /
  folder-import (no provenance).
- **`IngestedFileSummary`** grew `zoteroItemKey` / `zoteroItemTitle` (defaulted
  `nil` so existing callers compile).
- **Write seam:** `WikiStore.ingestFile` gained defaulted
  `zoteroItemKey`/`zoteroItemTitle` params; only `ingestFromZotero` passes
  non-nil. `WikiStoreModel.ingestFromZotero(_:parentItem:zoteroDir:)` now takes
  the parent `ZoteroItem`; `AddFromZoteroSheet.addSelected()` passes
  `selectedItem`.
- **Read path:** `listIngestedFiles`, `getIngestedFile`, and the
  `ingestedSummary` decoder extended for the two new columns (NULL→nil). The
  `listAllIngestedFilesOrderedByID` projection (files.jsonl / File Provider
  mount) is intentionally left unchanged for v1 — provenance is UI-only.
- **Detail view:** a small `zoteroOriginRow` in `headerSection` (Zotero tag +
  title + borderless "View in Zotero" button via `NSWorkspace.shared.open`).
  Library ID plumbed `ContentView → WikiDetailView → IngestedFileDetailView`
  from `ZoteroConfig`. Non-Zotero files show nothing (clean header).

Open questions resolved with the plan's recommended defaults: **web URL** link
target (universal, no Zotero install needed), **no** neutral "Imported" tag
for non-Zotero files, **UI-only** for v1 (no files.jsonl change).

3 new tests (NULL round-trip, Zotero-seam write, Zotero-seam threads key+title)
+ updated the 4 `ingestFromZotero` call sites in
`WikiStoreModelZoteroIngestTests`; bumped the 5 `user_version`-to-head
assertions across the suite to 9. Full `swift test` — 570 tests, 48 suites, 0
failures. `make check` compiles.

## 2026-06-20 — PR2: File browsing/editing + git-lite versioned processed markdown

Implemented `plans/file-versioned-editing.md`. Added a `file_markdown_versions`
append-only version chain (v7→v8 migration) so ingested files have editable processed
markdown while source bytes stay immutable. The version store (`FileMarkdownVersion`
model, 5 `WikiStore` methods, lazy seeding for native md/txt) is testable against a
temp DB with table-absent fallbacks for pre-v8 read connections.

Reworked `IngestedFileDetailView` to render markdown (MarkdownPreview) and PDFs
(PDFKit NSViewRepresentable) inline, with a tabbed Markdown⇄PDF view when extraction
output exists. Inline Save/Cancel buttons in the view (not toolbar) for all three
editor surfaces: ingested files, pages, and system prompt. Removed the toolbar Edit
buttons from `PageDetailView` and `SystemPromptDetailView` in favor of inline ones.
`PageReaderView` now shows the last-updated date and a Copy Path button (only when
the File Provider mount is available).

Moved all sidebar toolbar buttons (ingest, Zotero, New Page, Reindex Search) to the
main toolbar. Removed `OperationsView`; Query and Lint are now sidebar items (added
`.lint` to `WikiSelection` with a new `LintView`). Moved the System section below
Files. The empty-state view now shows Add-from-URL/Import/Zotero buttons
horizontally.

`AgentOperationRunner` now persists `PdfExtractionService` output as v1 (double-seed
guard); standalone "Extract Markdown" action in the detail view.

15 new `ProcessedMarkdownTests` (migration, version chain, revert, cascade, source
immutability, seeding, fallback). Full `swift test` — 567 tests, 48 suites, 0
failures.

## 2026-06-20 — `wikictl file` command family

Implemented `plans/wikictl-file-reads.md`. Added `wikictl file list|cat|export` so the
agent reads raw ingested files from SQLite instead of the File Provider mount during
Query. `cat` writes raw bytes via `FileHandle` (binary-safe); `--json` list output is
byte-identical to `indexes/files.jsonl`. Name resolution rejects ambiguity by listing
the matching ids. The Query and QueryConversation prompts now route raw-file reads
through `wikictl file` instead of `$WIKI_ROOT/files/...`.

19 new parser + execution tests in `WikiCtlCommandTests`; updated
`OperationCommandTests` prompt assertions. Full `swift test` — 552 tests, 0 failures.

## 2026-06-19 — Tab system rebuild: ID-based active tab + right-click context menu

Rebuilt the multi-tab system from scratch (plan:
`plans/tab-context-menu-rebuild.md`) to fix architectural defects in the merged
version and add the right-click context menu it lacked.

**What was broken in the merged system:**
- `activeTabIndex: Int` as the source of truth forced fragile index arithmetic
  (`min(index, count-1)`, `index < activeTabIndex ? -= 1`) in every close path —
  the root of the off-by-one / "wrong tab activates" bugs.
- `isSwitchingTab` re-entrancy guard was duplicated around every programmatic
  `selection = …` / `loadDrafts` pair (easy to miss one site).
- The uncommitted context menu used an `NSViewRepresentable` overlay setting
  `NSView.menu`, which fought SwiftUI's responder/gesture system (the "severe
  bugs"). Close button used insert-on-hover, reflowing tab width on hover.

**The rebuild (`WikiStoreModel`):**
- **`activeTabID: UUID?`** is now the single source of truth; `activeTabIndex` /
  `activeTab` are computed view-layer conveniences (never stored, can't go stale).
- **`setActiveTab(_:)`** is the one seam every switch routes through: flush →
  set `activeTabID` → mirror `selection` → `loadDrafts`, under a single
  `isApplyingTabSelection` guard (replaces the scattered `isSwitchingTab`).
- One intent per method: `openTab` (focus existing tab for any selection, else
  create new — see post-rebuild fix below),
  `selectTab(id:)`, `closeTab(id:)`, `closeOtherTabs(id:)`, `closeTabsAfter(id:)`,
  `closeAllTabs()`, `reopenLastClosedTab()`. `handleSelectionChange` /
  `select` / `applyHistorySelection` share one `syncActiveTabMetadata(to:)`
  helper for in-tab navigation.
- `delete` / `deleteIngestedFile` close affected tabs by ID.

**The rebuild (`WikiFS` views):**
- `TabBarItemView` uses native SwiftUI **`.contextMenu`** (Close / Close Others
  / Close Tabs After / Close All) — the `NSViewRepresentable` `TabContextMenu` is
  gone. Close button is always-present with **opacity-fade** (`.opacity` +
  `.allowsHitTesting`), not insert-on-hover (SWIFTUI-RULES §4.5). Tap handled via
  `.onTapGesture` so the nested close `Button` and context menu coexist cleanly.
- `TabBarView` iterates `store.tabs` by `id`, `isActive` = `tab.id ==
  activeTabID`. `ContentView` Cmd+W / Cmd+1–9 use the ID-based API.

**Post-rebuild fixes (same day, from live testing):**
- **Duplicate tab on tab click.** Clicking a tab set `store.selection`, which the
  sidebar's `.onChange(of: store.selection)` mirrored into `listSelection`, which
  re-fired `selectionDidChange` → `openTab` → a phantom tab to the right. Fixed in
  `SidebarView.selectionDidChange`: skip `openTab` when the clicked selection
  already equals `store.activeTab?.selection` (it's a programmatic sync, not a
  fresh click).
- **Tabs never reused.** `openTab` only de-duped the singleton types; pages/files
  always spawned a new tab (the plan's "Obsidian always-new" rule). Per operator
  request, `openTab` now **focuses an existing tab for any selection** if one is
  open, else creates a new one. `selectPage(byTitle:)` (`[[wiki-link]]` clicks)
  now routes through `openTab` (records history first, then reuses/creates) so
  clicking a link to an already-open page returns to its tab.
- Logging: added a `tabs` category to `DebugLog` (subsystem
  `com.selfdrivingwiki.debug`) used in `SidebarView`; `print("[tabs] …")` traces
  in `WikiStoreModel.openTab`.
- **Responsive tab strip.** Replaced the horizontal `ScrollView` (tabs ran past
  the window edge) with a `GeometryReader`-driven layout: tabs share the
  available width evenly, shrinking from 200pt toward 110pt as more open; past
  that they spill into a `⌄` overflow menu (a full tab switcher listing every
  open tab, active one checkmarked). The **active tab is always kept visible** —
  pinned into the last visible slot if it would otherwise overflow. The
  fit/overflow arithmetic is a pure `TabBarLayout.compute` in Core with 7 unit
  tests (`TabBarLayoutTests`); `TabBarItemView` now takes a uniform `width` and
  truncates its title within.

Shared-draft model retained (per-tab drafts remain an explicit non-goal).
**43 `EditorTabTests`** (was 31) cover the ID-based API plus the three new
close-variants and edge cases (leftmost-active close, anchor-active
`closeTabsAfter`, kept-non-active `closeOtherTabs`, recently-closed cap at 10),
plus tab-reuse coverage (`openTabForExistingPageReusesTab`, and
`WikiLinkNavigationTests` reuse/new-tab cases for `selectPage`).
Full suite green (531 tests, incl. 7 `TabBarLayoutTests`); `make check` clean;
signed bundle builds. Design
skills (swiftui-pro / macos-design / typography-designer) were not installed in
the build session — SWIFTUI-RULES applied inline.

## 2026-06-19 — Multi-tab editor space (Obsidian-style)

Added a multi-tab editor space: a horizontal tab bar above the detail pane lets
users keep multiple pages, Query, Instructions, and Activity open simultaneously.
Obsidian-style — clicking a page in the sidebar opens it in a new tab.

- **EditorTab** (`WikiFSCore/EditorTab.swift`) — `Identifiable, Hashable, Sendable`
  value type holding a `UUID` identity, a `WikiSelection`, and a display `title`.
  Plus `WikiStoreModel` helpers `tabTitle(for:)` and `tabIcon(for:)` that derive
  labels/icons from the live summaries/ingestedFiles arrays.
- **Tab management** on `WikiStoreModel`:
  - `tabs: [EditorTab]`, `activeTabIndex: Int`, `recentlyClosedTabs: [EditorTab]`
  - `openTab(_:title:)` — create or focus a tab. Singleton types (`.query`,
    `.systemPrompt`, `.changeLog`) reuse existing; pages/files always create new
    (Obsidian-style).
  - `selectTab(at:)` — switch tabs, flushing outgoing drafts
  - `closeTab(at:)` — close tab, push to recently-closed stack, activate neighbor
  - `reopenLastClosedTab()` — Cmd+Shift+T support
  - `newPageInNewTab(title:)` — create page + open in new tab
  - `handleSelectionChange`, `delete`, `deleteIngestedFile`, `rename`, `newPage`,
    `select`, `selectPage`, `applyHistorySelection` all updated for tab awareness
- **TabBarView** (`WikiFS/TabBarView.swift`) — horizontal `ScrollView` tab strip
  with `.regularMaterial` background, 34pt height
- **TabBarItemView** (`WikiFS/TabBarItemView.swift`) — icon + truncated title +
  hover-revealed close button; active tab: accent underline + control background;
  inactive: subtle hover highlight. Semantic typography (`.caption`, `.semibold`).
- **ContentView** — tab bar integrated above detail content; hidden keyboard
  shortcut buttons (Cmd+W close, Cmd+Shift+T reopen, Cmd+1–9 switch, Cmd+N new
  page); New Tab toolbar menu (New Page / Query / Instructions / Activity)
- **SidebarView** — single-click calls `store.openTab(_:)` (Obsidian-style)

**Tests** — `EditorTabTests` (31 tests): initial state, tab creation, open/close/
switch/reopen, singleton reuse, delete-page-closes-tab, rename-updates-title,
ingested-file-tab-close, history-preserves-tab-metadata, tabTitle/tabIcon helpers.

**Verified.** `make check` clean; `swift test` **510/510** green (31 new, 0
regressions); `make` produces a clean signed bundle.

**Post-merge fix:** Opening a file (switching tabs) was bumping `updated_at` on the
outgoing page because `flushPendingSaves()` called `save()` unconditionally, and
`PageUpsert.upsert` always writes. Added `isDraftDirty` / `isSystemPromptDirty`
flags — set by `didSet` on `draftTitle`/`draftBody`/`draftSystemPrompt` (and by
`bodyChanged`/`titleChanged`/`systemPromptChanged`), cleared by `loadDrafts` and
after a successful save. `flushPendingSave()` and `flushPendingSystemPromptSave()`
now skip the save when the draft is clean, so viewing a page without editing no
longer touches its timestamp.

## 2026-06-19 — File filter + native multi-select + batch ingest in single agent run

Added a filter picker and native multi-select to the Files section, and generalized
the ingest pipeline so multiple selected files are staged and processed in a single
agent run.

- **Filter picker** (All / Ready / Ingested) in the Files header
- **Native List multi-select** — Shift+Arrow, Shift+Click, Command+Click select
  multiple files; selected files highlight and show "Ingest Selected" button
- **Multi-source ingest** — selected files staged together as `source-1.md`,
  `source-2.pdf`, … in ONE agent run so the agent cross-references holistically
- **ProgressView spinner** on file rows while being ingested
- **`ingestingFileID` → `ingestingFileIDs: Set<PageID>`** to track multiple files
- **Right-click → "Ingest Selected"** on a selected file in the context menu

**Changed — Core pipeline (WikiFSCore)**
- `WikiOperation.ingest` generalized from one source to N: `sourcePath`→`sourcePaths`,
  `stagedSourcePath`→`stagedSourcePaths`. Prompt builders list all sources and
  instruct the agent to cross-reference and log each source ID.
- `AgentStaging` gained `stageSources(_:in:)` (stages `source-1.<ext>`, …) and
  `sourceFileName(ext:index:)`. `IngestWriteRule.dontRediscover` takes `[String]`.
- `AgentOperationRunner.runMultiIngest(fileIDs:)` reads all files, converts PDFs,
  builds `[StagedSource]`, stages together, launches one agent run.

**Changed — App (WikiFS)**
- `OperationRequest.ingest` takes `sources: [StagedSource]` (bytes, ext, displayPath).
- `SidebarView`: `listSelection: Set<WikiSelection>` bridges native multi-select to
  single-item detail navigation. "Ingest Selected" appears when file IDs are selected.
- `IngestedFileRow`: simplified — no custom checkboxes; shows spinner when ingesting;
  context menu has "Ingest Selected" on selected files.
- Removed all custom checkbox / batch-mode toggle code.

**Tests**
- Updated `OperationCommandTests`, `ClaudePromptHelpTests` for new signatures.
- `AgentStagingTests`: `sourceFileNameWithIndex`, `stagesMultipleSourcesIntoScratch`,
  `stagesEmptySourcesListReturnsEmpty`.

**Verified.** `make check` clean; `swift test` **479/479** green; `make` produces a
clean signed bundle. PR #16.

See `plans/markdown-folder-import.md`.

## 2026-06-19 — Import Markdown Folder (Obsidian, LogSeq, general .md directories)

Added a one-shot "Import Markdown Folder…" action that recursively walks a directory
of Markdown files and lands them in `ingested_files` for the agent to curate via
Ingest. Works with Obsidian vaults, LogSeq graphs, and any folder of `.md` files.
Hidden files/directories are skipped; duplicate filenames get a disambiguating suffix.

**Added — Core (WikiFSCore)**
- `MarkdownFolderReader` — pure, testable recursive walk with injectable `FileOperations`
  protocol (production: `FileManagerFileOperations`). Filters `.md` / `.markdown`,
  skips hidden entries, deduplicates filenames, collects per-file read errors.
  `WalkResult`, `MarkdownFile`, `WalkError` (conforms to `LocalizedError`).

**Added — Model (WikiStoreModel)**
- `importFromMarkdownFolder(directory:) async -> (imported: Int, errors: [String])`
  — walks off the main actor via `Task.detached`, stores each file via the shared
  `store.ingestFile(filename:data:)` seam, returns import count + error messages.

**Added — UI (WikiFS)**
- `ImportMarkdownSheet` — follows `AddFromURLSheet`'s phase-enum pattern: idle →
  scanning → ready(count) → importing → done(imported, errors) → failed. Directory
  picker via `WikiFilePanels.chooseDirectory`. Progress + results summary.
- Toolbar + Files section header buttons ("Import Markdown Folder…") in `SidebarView`,
  always shown (no configuration gate). Sheet binding alongside existing URL/Zotero
  sheets.

**Tests**
- `MarkdownFolderReaderTests` — 14 unit tests with `FakeFileOperations` test double
  (recursive walk, .md/.markdown filter, non-markdown exclusion, hidden file/dir
  skip, filename dedup, read error collection, empty/no-markdown directory,
  byte-identical content, Equatable conformance).
- `WikiStoreModelMarkdownImportTests` — 12 integration tests with real SQLiteStore +
  temp directory fixtures (all files land in ingested_files, filenames match,
  content byte-identical, non-markdown ignored, signal fires, empty dir handled,
  dedup works, YAML/wikilinks/callouts preserved, hidden dirs skipped, idempotent
  second import, .markdown extension handled).

**Skill pass.** Before and after code: `swiftui-pro` kept the sheet as a thin leaf
surface with a phase-enum state machine; `macos-design` placed the action in the
toolbar and Files section header alongside the existing URL/Zotero buttons;
`typography-designer` used semantic system fonts (`.headline`, `.subheadline`,
`.callout`, `.caption`).

**Verified.** `make check` clean; `swift test` passes (**476/476** — 26 new tests,
no regressions). Full build (debug) produces a clean signed bundle.

See `plans/markdown-folder-import.md`.

## 2026-06-19 — Parameterized signing for any Apple Developer account

Signing was hardcoded to one developer's team. Bundle ids and App Groups are
globally unique across App Store Connect, so nobody who clones can reuse them —
signing is now parameterized, with per-developer values kept out of git. Full
design + the asc/keychain runbook in `plans/signing.md` (§ Multi-developer
signing).

**Added**

- `signing/local.config` (gitignored) + `signing/local.config.example` — single
  source of truth for `TEAM_ID`/`DEV_IDENTITY`/`BUNDLE_ID`/`EXT_BUNDLE_ID`/
  `APP_GROUP`. Absent → upstream defaults, so a fresh clone still builds +
  ad-hoc signs unchanged.
- `signing/setup.sh` — `asc`-driven provisioning (mint/discover cert, register
  this Mac, create bundle ids + App Groups capability, create + download
  profiles, write `local.config`). Pauses for the one portal step the API can't
  do — creating + binding the App Group. Idempotent.
- `Sources/WikiFSCore/WikiIdentifiers.swift` — resolves the ids at runtime
  (env → `Bundle.main` Info.plist → `wiki-identifiers.env` sidecar → default),
  so the app, the sandboxed extension, and the bundle-less `wikictl` all agree.

**Changed**

- `build.sh` sources `local.config`, generates both `.entitlements` into
  `build/`, injects the ids into the Info.plists + the `wikictl` sidecar, and
  signs with `SIGN_IDENTITY` → `DEV_IDENTITY` → ad-hoc. `Makefile` reads the
  config via a `cfg` helper. `DatabaseLocation`/`FileProviderSetupVerifier`
  delegate to `WikiIdentifiers`. Removed the committed `WikiFS/*.entitlements`
  (now generated — they baked in one team).

**Verified**

- `swift test` → all 450 pass. End-to-end on a real paid account: `make run`
  builds + signs with a dev cert, the File Provider extension loads, registers,
  and its mount appears with projected pages. Requires full Xcode (not just the
  Command Line Tools — the app's `swiftui-math` macros need Xcode.app).

**Fixes found during bring-up**

- The bundled `pdf2md` script wasn't signed in the real-signing path (only the
  ad-hoc path was), so codesign rejected the unsigned file. Now signed.
- The `wiki-identifiers.env` sidecar must live in `Contents/Resources/`, not the
  code-only `Contents/Helpers/`.

## 2026-06-18 — Semantic search via sqlite-vec + NLEmbedding

Added meaning-based search over wiki pages. sqlite-vec ranks by cosine similarity
inside SQLite; Apple NLEmbedding generates 512‑dim embeddings at save time. The
sidebar has a search bar (debounced 300ms); `wikictl search --query "…"` gives
the agent the same capability. Falls back to LIKE title match when the extension
or model is unavailable — never a hard dependency. v7 migration. 16 files, 472+.

See `plans/semantic-search.md`.

## 2026-06-18 — Collapsible sidebar sections + page sort order

All four sidebar sections (Tools, System, Pages, Files) are now collapsible via
chevron toggles. The Pages section gains a sort Picker: Last Updated, Newest
First, Title A–Z. `WikiPageSummary` now carries `createdAt`. `WikiStore.listPages()`
accepts a `PageSortOrder` parameter; `WikiStoreModel` holds the user's preference
and `currentStateSnapshot()` always passes `.lastUpdated` so the agent prompt is
stable regardless of sidebar sort. 441 tests green. PR #12.

## 2026-06-18 — PDF extraction pipeline: PdfExtractionService + pdf2md integration

Add pdf2md to integrate docling/granite-docling VLM/spacy pipeline to convert PDF to markdown without going through Claude.  Refactor the ingestion UI to show PDF conversion and ingestion results.

**Added — PdfExtractionService (WikiFS)**

- `PdfExtractionService` — spawns `pdf2md` as a subprocess, matching the existing
  `wikictl`/`claude` subprocess pattern. Converts PDF bytes → Markdown via a temp
  file; streams stderr progress; returns the extracted markdown.
- `PdfExtractionService.preDownload()` — two-phase pre-download (uv packages then
  HuggingFace model weights), with streaming progress. `probeReady()` uses `uv run
  --offline` for a fast cached-probe without triggering downloads.
- `PdfExtractionService.OutputBuffer` — thread-safe byte accumulator for pipe
  draining off the main actor. `ProcessRegistry` — tracks live subprocesses for
  app-termination cleanup.
- Continuous stdout/stderr pipe draining via `readabilityHandler` — pipes are
  drained as data arrives, never allowed to fill the 64 KB kernel buffer. Spawns
  `pdf2md` as a subprocess, matching the existing `wikictl`/`claude` pattern.

**Fixed**

- `run()` termination handler now drains the pipe tail (`readToEnd()`) after
  nil'ing the readability handler, preventing data loss at the kernel buffer
  boundary.
- `streamProcess()` now buffers stderr via `OutputBuffer` so error messages
  actually contain the failure output (was always empty — the handler had already
  consumed the data by the time `readDataToEndOfFile()` ran).

**Added — UI (WikiFS)**

- `PdfExtractionView` — inline readiness probe + download progress + live
  conversion log, shown above the agent activity feed during ingest.
- `AgentTranscriptSidebar` — draggable horizontal grippy between PDF conversion
  and agent activity sections, letting the user resize both.
- `IngestSheetView` — button label shortened to "Ingest", centered.
- `AgentOperationRunner.runIngest()` — runs PDF conversion BEFORE the agent
  launch; passes extracted markdown as a staged sibling file so the agent
  prefers it over the raw PDF.

**Tests added**

- `PdfExtractionServiceTests` — `OutputBufferTests` (5, incl. 500-write × 10-task
  concurrent safety) + `PipeDrainingTests` (5, incl. 256 KB stdout drain proving
  the subprocess doesn't block) + the existing ProcessRegistry / error-description
  / resolveScript suites. **22 tests.**
- `pdf2md` integration tests — `TestCLIStdout` (4, covering the stdout code path
  `PdfExtractionService` exercises), `TestErrorOutput` (2), `TestCLIWithMinimalPdf`
  (3) + a `minimal_pdf` fixture (538-byte hand-crafted valid PDF for fast,
  hang-proof tests). **67 total (48 unit + 19 integration).**

**Skill pass.** Before and after code: `swiftui-pro` kept service/process state in
`@MainActor @Observable` types and the views as thin leaf surfaces; `macos-design`
kept the transcript sidebar as a quiet inspector with native split-drag controls;
`typography-designer` kept semantic system fonts (`.subheadline`, `.caption`,
monospaced logs).

**Verified.** `make check` clean; full `swift test` passes (**435/435**). Python
tests pass but are not in CI (manual):
`uv run pytest tests/test_pdf2md.py tests/test_integration.py -v` **(60/60 green)**;
`uv run pytest tests/test_vlm.py -v` (VLM pipeline, run on demand — requires
~2 GB model download + a real PDF fixture).

**Carry-forward.** The `pdf2md` VLM pipeline (`--pipeline vlm`) is not tested in
CI (requires model download). `--json -o` ignoring the `-o` flag is existing
behaviour (documented in tests, not yet changed).

## 2026-06-17 — Dedicated interactive Query page

- Added a first-class Query destination in the sidebar, separate from individual
  page readers, so asking questions is a wiki-level workspace.
- Replaced the page-bottom one-shot query composer with `QueryConversationView`:
  an output-first chat transcript, Start/Send composer, Stop, and Activity log
  access.
- Extended the Claude launcher with a stdin-backed stream-json session for Query
  conversations. The first prompt starts the session; follow-ups are written to
  stdin while the same process remains alive.
- Added a specialized interactive Query prompt: answer in chat by default, follow
  wiki pages/raw-source footnotes as needed, and write via `wikictl` only when the
  user explicitly asks to persist an update. The prompt now also tells the agent
  to do wiki/source inspection silently rather than narrating setup steps.
- Suppressed the trailing transcript inspector while the Query page is selected,
  because the page itself is already the transcript surface.
- Transcript surfaces now default to output-only, with a default-off "Show
  internals" checkbox that reveals tool calls, status, diagnostics, and raw agent
  events for debugging.
- Removed explicit Answer/Update mode controls from Query. The composer now sends
  exactly what the user types; users can ask Claude to update the wiki in plain
  language when they want persistence.
- Removed the File Provider path chip from the Query header after the chat
  surface stabilized; the mount is still used as a run precondition, but it no
  longer competes with the conversation.
- Tightened the Query typography pass: the empty state is centered and stronger,
  the composer input uses body text, and the internals checkbox only appears once
  there is a run/debug state.
- Reworked Query around ChatGPT-style states: empty state is a centered greeting
  with a floating pill composer; after the first turn, messages occupy the page
  and the same composer docks at the bottom. User turns render as right-aligned
  pills; Claude turns render as unboxed prose.
- Centered the conversation in a shared chat column so user turns, Claude prose,
  and the composer align with each other instead of spreading across the full
  window. Collapsed Query debug controls into a small Activity menu; running
  state now shows only a quiet spinner plus Stop.
- Split the sidebar's top controls into Tools and System sections, leaving pages
  and files as content lists rather than mixing them with app-level destinations.
- Documented the design in `plans/query-conversation.md` and added command /
  navigation regression coverage.

**Skill pass.** Before code: `swiftui-pro` led to a singleton navigation
destination and kept process/session state in the existing `@MainActor
@Observable` launcher; `macos-design` kept Query as a quiet utility workspace
with visible status and standard controls; `typography-designer` kept semantic
system fonts (`.largeTitle`, `.callout`, `.caption`) rather than fixed sizes.
After code: the new view is a focused leaf with distinct empty/conversation
states, the prompt/command contract is pure and tested, page reading no longer
carries unrelated query chrome, and the operations/sidebar transcript views
share the same default-off internals control.

**Verified.** `make check` passes and `swift test` passes (**351/351**).

## 2026-06-16 — Agent transcript prose renders as Markdown

- Added a reusable `AgentMarkdownText` leaf view that renders Claude-authored
  transcript prose with Textual's `StructuredText(markdown:)`.
- Updated the shared agent activity feed used by the transcript sidebar and the
  Ingest/Query/Lint operation sheet so assistant prose and final results preserve
  Markdown blocks such as headings, lists, links, and code fences.
- Kept tool-use, tool-result, diagnostics, and raw-event rows in compact
  monospaced/log styling so the operation log remains scannable.

**Skill pass.** Before code: `swiftui-pro` pointed to a small extracted leaf view
instead of expanding the activity row, `macos-design` kept the transcript as a
quiet inspector/log surface, and `typography-designer` favored Textual/system
Markdown typography over hard-coded sizes. After code: the change is localized to
Claude prose/result rows and reuses the same Markdown renderer dependency already
accepted for the page reader.

**Verified.** `make check` passes and `swift test` passes (**348/348**).

## 2026-06-17 — Zotero integration

Branch `zotero-integration` (PR #9). See `plans/zotero-integration.md` for the
full design (why, research findings, decisions, architecture). Delivered as a
single branch — both the core library and the settings/picker UI, rather than
two separate PRs.

**Added — Core (`WikiFSCore`, pure/testable, no UI)**

- `ZoteroClient` — talks to `api.zotero.org` for search/browse; mirrors
  `URLIngestService`'s testable-fetcher + pure-dispatch shape (`RequestFetcher`
  protocol, `decodeItems`/`decodeAttachments`/`buildSearchRequest`/
  `buildChildrenRequest` statics). `searchItems`, `childAttachments`,
  `verifyConnection`. Production fetcher `URLSessionZoteroFetcher`.
- `ZoteroLocalStorage` — resolves an attachment to
  `~/Zotero/storage/<key>/<filename>` (pure path composition + injectable
  existence check, mirrors `PathPreflight`). Confirmed via direct research
  against Zotero's own open-source sync client that this path is safe to read
  directly (single atomic `OS.File.move` commits a download — never a torn
  file for the plain PDF/Markdown case this feature targets).
- `ZoteroConfig` — non-secret app-wide config (library ID, Zotero-dir
  override), JSON load/save following `WikiRegistry`'s pattern
  (`zotero-config.json`, sibling to `wikis.json`).
- `ZoteroCredentialStore` — the API key (a secret) behind a protocol:
  `KeychainZoteroCredentialStore` (generic-password Keychain item, no
  entitlement needed — the app has no App Sandbox) and
  `InMemoryZoteroCredentialStore` for tests.
- `WikiStoreModel.ingestFromZotero(_:zoteroDir:)` — resolves the attachment,
  reads bytes off the main actor, and lands them through the EXISTING public
  `ingestFile(filename:data:)` seam (the same one drag-ingest uses) — no new
  storage path, no schema change. Throws `ZoteroIngestError.unavailable` for
  an attachment not yet synced locally (no network-download fallback in v1).

**Added — Settings + picker UI (`WikiFS`)**

- `ZoteroSettingsView` — the app's first Settings scene (`⌘,`): API key
  (`SecureField`, Keychain-backed), library ID, an optional Zotero data
  directory override (`NSOpenPanel`), and a "Test Connection" button that
  surfaces failures via `.alert`, matching `WikiFSApp`'s existing warning
  pattern. Save is an explicit action (not implicit on-blur/on-submit) so a
  window-closed-via-red-button edit is never silently dropped.
- `AddFromZoteroSheet` — mirrors `AddFromURLSheet`'s `Phase`/`Metrics` shape:
  debounced live search → item list → checkbox multi-select of an item's PDF
  and/or `.md` attachments → "Add Selected" calls `ingestFromZotero` per
  selection, collect-and-continue on per-item failure. Two-level: search
  results, then drill-down into the selected item's attachments.
- `SidebarView` — "Add from Zotero…" button (toolbar + Files section header)
  next to "Add from URL…", shown only when `ZoteroConfig` has a library ID and
  the Keychain has an API key. Both buttons kept as always-mounted views
  (§SWIFTUI-RULES 1.1).
- `WikiFSApp` — Settings scene wired in, container directory plumbed through.
- `WikiFilePanels` — `chooseDirectory` helper for the Zotero-dir override.
- Extracted `ZoteroAttachment.isIngestable` (`.pdf`/`.md` extension check,
  case-insensitive) and `ZoteroItem.subtitle` ("Ito, K. · 2016") as pure
  value-type properties in `WikiFSCore` so the picker UI stays thin.

**Tests**

- 5 test files (35 tests): `ZoteroClientTests`, `ZoteroLocalStorageTests`,
  `ZoteroConfigTests`, `ZoteroCredentialStoreTests`,
  `WikiStoreModelZoteroIngestTests` — all fakeable, no real network or Keychain
  access in CI.
- +24 additional tests after gap analysis: `isIngestable` extension filtering
  (5), `subtitle` formatting (5), decode/status boundary edge cases (7), config
  empty-override + nil round-trip (2), multi-ingest + `ZoteroIngestError`
  conformance (3). Total: **410 green** (59 Zotero-specific across 5 files).
- `KeychainZoteroCredentialStore` is NOT covered by automated tests (would
  pollute the test runner's Keychain) — gets a manual smoke test instead.
  Same for the live-API path (real search/ingest against the user's library).

**Verified**

- `make check` compiles clean; `make` produces a clean signed (ad-hoc) bundle.
- `swift test`: 410 tests green, no regressions.
- Rebased onto `main` (2026-06-17) — resolved a single conflict in
  `PROGRESS.md`.

**Decisions** (confirmed with the user before implementation)

- No network-download fallback in v1 — unsynced attachments error clearly
  instead.
- Zotero credentials are app-wide, not per-wiki.
- Search is live/debounced against the API, no session cache.
- Multi-select ingest: check a PDF + its converted `.md` and ingest both in
  one action.

**Gate**

- A live-account manual smoke test against the user's real Zotero library:
  search, ingest both a PDF and its converted `.md`, confirm byte-identical,
  exercise "Test Connection" with a deliberately wrong key.

## 2026-06-16 — Wiki rename plus SQLite backup/restore

- Added wiki-level management actions to the switcher menu: rename the active
  wiki, export it as a `.sqlite` backup, and import a `.sqlite` backup as a new
  wiki with a new display name.
- `WikiManager.exportWiki(id:to:)` flushes pending active edits, checkpoints the
  WAL into the main DB, copies a single portable SQLite file, and refuses to
  overwrite the source backing database.
- `WikiManager.importWiki(from:displayName:)` copies the selected SQLite file to
  a fresh ULID-backed DB, opens it once to validate/migrate the schema, adds it
  to the registry, registers its File Provider domain, and selects it.
- Rename remains identity-stable (`<ulid>.sqlite` unchanged) and now refreshes
  the File Provider domain display name so Finder can pick up the new label.
- Added native macOS open/save panels for choosing backup files, plus an import
  naming sheet that uses the existing compact `.headline`/body hierarchy.

**Skill pass.** Before code: `swiftui-pro` kept stateful backup/restore logic in
the existing `@MainActor @Observable` manager and left the switcher as a thin UI
surface; `macos-design` put the actions in the wiki/account menu and used system
file panels; `typography-designer` kept semantic system type rather than adding a
new scale. After code: import/export are covered by manager tests, the UI uses
native controls and SF Symbols, and rename/delete/import remain progressive
wiki-level actions rather than page chrome.

**Verified.** Full `swift test` passes (**341/341**) and `make check` passes.

## 2026-06-16 — Agent runs show quiet-live status and can be stopped inline

- Diagnosed a Query run that appeared hung: the spawned `claude -p` process was
  still alive, but `run.jsonl` had not changed since the last tool result, so the
  transcript only showed a spinner with no heartbeat.
- `AgentLauncher` now records run start time, last stdout/stderr activity, and
  the child process ID for the current run.
- The operation transcript and inline transcript sidebar now show a live status
  line such as "Running · last output 12s ago · elapsed 1m 4s · pid 12345"; after
  60 seconds without output it explicitly says the process is still running but
  quiet.
- Added a Stop button to the inline transcript header, matching the modal sheet's
  existing stop control, so a wedged inline query can be terminated without
  leaving the page.
- Fixed a follow-on beachball when collapsing the transcript sidebar. The sidebar
  had been kept alive at width 0, leaving selectable transcript text and live
  timeline/status views in a zero-width layout loop. Collapsing now removes the
  transcript subtree entirely; visible sidebars use a stable fixed width.

**Verified.** `make check` passes, `swift test` passes (**337/337**), and
`make install` installs the fixed app into `/Applications`.

## 2026-06-16 — Reader renders full Markdown blocks with Textual

- Replaced the reader's inline-only Markdown preview with
  `gonzalezreal/textual`'s `StructuredText(markdown:)`, so page bodies render
  headings, paragraphs, lists, dividers, code blocks, and links as actual
  Markdown blocks.
- Kept the app's wiki-specific preprocessing: `[[wiki-links]]` are still
  rewritten to private `wiki://` links before rendering, footnote references
  remain generated local note links, and extracted footnotes are appended as an
  ordered Markdown notes section.
- Bumped the package platform to macOS 15 because Textual 0.5.0 requires it.

**Skill pass.** Before and after code: `swiftui-pro` kept the renderer isolated
in the existing leaf preview view and left parsing/link transforms in pure core
helpers; `macos-design` and `typography-designer` favored Textual's native
SwiftUI/system text rendering and document spacing rather than custom fixed type.

**Verified.** `make check` passes and `swift test` passes (**337/337**).

## 2026-06-16 — File Provider install path is enforced

- Diagnosed the unavailable mount: `pluginkit` had multiple enabled
  `org.sockpuppet.WikiFS.FileProvider` records from old `WikiFS.app`, temp
  bundles, and the build product, and `fileproviderctl dump` showed the daemon
  binding domains to stale/unreachable app-extension records instead of the
  current installed app.
- Changed `make run` to go through `make install`, so local launches use
  `/Applications/Self Driving Wiki.app` rather than the `build/` copy.
- `make install` now prunes stale provider registrations for old dev paths,
  copies the app into `/Applications`, registers it with LaunchServices, and
  explicitly registers/enables the nested File Provider with `pluginkit`; it
  fails if `pluginkit` does not report the provider at the installed path.
- Added a launch-location warning in the app: if the bundle is not running from
  `/Applications/Self Driving Wiki.app`, it alerts that File Provider mounts may
  be unavailable and offers to open the installed copy or reveal the current one.
- Added a startup File Provider setup verifier. It checks `pluginkit` for
  `org.sockpuppet.WikiFS.FileProvider`, attempts to register/enable the installed
  `.appex` if the path is wrong or missing, and alerts if the provider still is
  not registered to `/Applications/Self Driving Wiki.app`.

## 2026-06-16 — Ingest sheet no longer waits on a broken File Provider mount

- The Maintain Wiki sheet now auto-selects the newest ingested source when the
  Ingest tab opens, so the magic-wand path does not strand the user on
  "Choose a file..." with a disabled Run button.
- The file-detail "Ingest into Wiki" action opens the same sheet with that file
  preselected, keeping the operation visible and making the selected source
  explicit before launch.
- `AgentOperationRunner` no longer signals the File Provider before an Ingest
  run. Ingest stages source bytes and `WIKI_STATE.md` from SQLite and writes via
  `wikictl`, so a daemon/provider registration failure must not delay or block
  the agent start. Query and Lint still signal/use the mount.
- Verified with `make check`, `swift test`, and a signed `make` build.

## 2026-06-16 — Mount resolution no longer hangs the agent run UI

Fixed a fresh-wiki failure where Ingest/Query/Lint could become nonresponsive in
the Maintain Wiki sheet: `NSFileProviderManager.getUserVisibleURL` could hang
forever while resolving a newly-created File Provider domain, leaving the UI stuck
at "Resolving mount..." and the Run button disabled.

**Changed**
- Added bounded mount URL resolution in `FileProviderSpike`; if File Provider
  does not return a root URL within 5 seconds, the app retries domain
  registration/enumeration once and then surfaces a real status instead of
  looking permanently busy.
- Allowed Ingest to run without a resolved mount because the app already stages
  the source bytes and `WIKI_STATE.md` directly from SQLite; Query/Lint still
  require the mount because they may need raw-file reads.
- Bounded File Provider enumerator signals so pre-run refresh cannot hang before
  launch.
- Added explicit `isResolvingPath` state so `OperationsView` can distinguish
  active progress from a failed/unavailable mount and show the underlying status.
- Reused the bounded resolver when opening ingested files so file opens also fail
  visibly instead of waiting indefinitely on File Provider.

**Skill pass.** Before and after code: `swiftui-pro` kept shared state in the
existing `@MainActor @Observable` model, kept File Provider access main-actor
isolated, and left the view as a small status presentation change.

**Verified.** `make check` passes and `swift test` passes (**333/333**).

## 2026-06-16 — Query can follow footnotes to raw files

Updated Query orientation so an agent answering from the wiki can use the new
source-location footnotes instead of stopping at the synthesized wiki page.

**Changed**
- Added a root-level `WIKI-STRUCTURE.md` projection that serves the same layout
  map as the legacy `TREE.md` alias, and updated the renderer/schema/README to
  name `WIKI-STRUCTURE.md` first.
- Expanded the Query prompt to name `WIKI-STRUCTURE.md`, pull fresh page content
  with `wikictl page get`, inspect Markdown footnote definitions, resolve cited
  source files through `files/by-name`, `files/by-id`, or `indexes/files.jsonl`,
  and read raw sources from the mount with `Read` or shell tools such as
  `pdftotext`.
- Added regression assertions for the Query prompt's footnote-following workflow
  and the new layout-map name.

**Skill pass.** Before and after code: `swiftui-pro` kept this in pure prompt /
projection code with focused tests; no SwiftUI layout or typography changes were
needed.

**Verified.** `make check` passes and `swift test` passes (**333/333**).

## 2026-06-16 — Ingest prompts ask for source-location footnotes

Updated the Opus Ingest prompts so wiki pages written during Ingest should
footnote synthesized conclusions, interpretations, and non-obvious facts using
Markdown footnotes. The requested provenance is intentionally lightweight: source
file name plus page number, section, heading, line range, or chunk range; no real
links required.

**Changed**
- Added a shared "FOOTNOTE CONCLUSIONS" prompt fragment used by both tiny
  single-Opus Ingest and large Opus-curator Ingest.
- Kept the instruction out of Query/Lint prompts and out of the Sonnet
  `source-reader` digester prompt, because only Opus writes pages during Ingest.
- Added regression assertions in `OperationCommandTests` for the ingest-only
  footnote rule and digester exclusion.

**Skill pass.** Before and after code: `swiftui-pro` kept the prompt logic pure,
shared, and unit-tested; no SwiftUI layout or typography changes were needed.

**Verified.** `make check` passes and `swift test` passes (**332/332**).

## 2026-06-16 — Wiki footnotes render in the reader

Verified the prior renderer could not render Markdown-style wiki footnotes:
Foundation's `AttributedString(markdown:)` left `[^id]` references and
`[^id]: ...` definitions as literal text.

**Changed**
- Added a pure `WikiFootnoteMarkdown` transform in `WikiFSCore` that extracts
  `[^id]: ...` definitions, numbers referenced notes by first use, rewrites
  in-body references to local note links, and leaves unknown references literal.
- Updated `MarkdownPreview` to run the footnote pass before block rendering and
  show extracted definitions as a secondary `.footnote` notes section below the
  article body. Wiki source in SQLite / the File Provider projection remains
  unchanged.
- Added regression coverage for numbering, repeated references, continuation
  lines, unknown references, and code-span/fence protection.

**Skill pass.** Before code: `swiftui-pro` pointed toward keeping parsing out of
SwiftUI and covering it with unit tests; `macos-design` and
`typography-designer` kept the reader as the content focus with semantic system
type. Post-code review kept the view small, used `.body` / `.footnote` rather
than custom sizes, and handled generated note links locally.

**Verified.** `make check` passes and `swift test` passes (**330/330**).

## 2026-06-16 — Prompt help made navigable

Changed the Claude Prompt Templates Help window from one long scroll into a
sidebar/detail view listing each prompt artifact directly: Command, Ingest
variants, Query, Lint, Agents, and appended System Prompt. The window now defaults
to **Query -p Prompt**, so Query is visible immediately instead of buried below
the long ingest prompt. The detail body still renders from `ClaudePromptHelp`,
which renders from the production prompt builders.

**Verified.** `make check` passes and `swift test` passes (**325/325**).

## 2026-06-16 — Fan-out prompt names Sonnet for raw ingestion

Tightened the large-source Ingest curator prompt so it explicitly tells Opus to
use **Sonnet `source-reader` workers, not Opus**, for raw source ingestion. Opus
still curates/synthesizes and writes pages/index/log; Sonnet handles the bulk
read/digest work. Added a regression assertion in `OperationCommandTests`, and
the Help-menu prompt reference picks this up automatically from the production
`WikiOperation` builder.

**Verified.** `make check` passes and `swift test` passes (**325/325**).

## 2026-06-16 — Claude prompt templates added to Help

Added a secondary Help-menu reference for the actual `claude -p` command surface:
the argv/env/cwd template, each operation's `-p` prompt, the large-ingest
`--agents` JSON, and a pointer to the active wiki's editable System Prompt body.

**Changed**
- Added `ClaudePromptHelp` in `WikiFSCore`, rendering Help documents from the
  production `OperationCommand`, `WikiOperation`, and `IngestPlan` builders using
  placeholder paths/inputs so the reference tracks the real launch payload.
- Added a **Help → Claude Prompt Templates** window with selectable monospaced
  prompt blocks. The window is secondary UI, separate from the main wiki/editor
  flow.
- Added `ClaudePromptHelpTests` to assert the Help reference includes command,
  operation, subagent, and system-prompt sections and that the operation prompt
  bodies come from the production builders.

**Skill pass.** Before and after code: `swiftui-pro` kept the renderer pure and
the SwiftUI views split into leaf types; `macos-design` placed the reference in
the Help menu rather than primary navigation; `typography-designer` kept semantic
system styles for prose and monospaced body text only for literal prompt/code
content.

**Verified.** `make check` passes and `swift test` passes (**325/325**).

## 2026-06-16 — Change Log surfaced in the sidebar

Surfaced the append-only operation log in the app UI, next to the other pinned
wiki-level documents.

**Changed**
- Added a pinned **Change Log** row beside **System Prompt** in the sidebar.
- Added `WikiSelection.changeLog` and a read-only `ChangeLogDetailView` that renders
  the same markdown body as projected `log.md`, including query answers and agent
  notes.
- Added `WikiStoreModel.currentLogMarkdown()` as the app-side seam over the existing
  `LogRenderer`, so the UI and File Provider projection share one formatter.

**Skill pass.** Before and after code: `swiftui-pro` kept the log as a separate
leaf view with a small model seam; `macos-design` placed it as a pinned sidebar
document alongside System Prompt; `typography-designer` kept the detail view on
the existing reader scale (`.largeTitle`, `.callout`, rendered markdown body).

**Verified.** `make check` passes and `make test` passes (**322/322**). Added a
core regression test that `WikiStoreModel.currentLogMarkdown()` includes query log
notes via the projection renderer.

## 2026-06-16 — Inline agent transcript inspector

Added an expandable trailing transcript sidebar for inline Query/Ingest runs, so
the page can remain visible while the wiki is edit-locked and the user can still
see what the agent is doing.

**Changed**
- `ContentView` now hosts a trailing inspector pane beside the selected detail
  content. It auto-expands when an agent run starts and can be toggled from the
  toolbar or collapsed from inside the pane.
- `AgentTranscriptSidebar` reuses `AgentActivityView`, the same live transcript
  renderer used by the dedicated Maintain Wiki sheet, so tool calls, subagent rows,
  assistant text, diagnostics, and results render consistently.
- Split selected-detail rendering into `WikiDetailView`, keeping the app shell
  focused on navigation/chrome and avoiding a growing monolithic view body.

**Skill pass.** Before and after code: `swiftui-pro` favored extracting the detail
switch and reusing the existing activity view; `macos-design` pointed to a trailing
inspector rather than a modal; `typography-designer` kept the panel on existing
semantic macOS styles (`.headline`, `.callout`, `.caption`, monospaced transcript
rows). The toggle and collapse controls keep text labels for accessibility even
when rendered as icons.

**Verified.** `make check` passes and `make test` passes (**321/321**).

## 2026-06-16 — Ingestion and query affordances moved into the content flow

Made Ingest and Query discoverable where the user is already working instead of
requiring the toolbar's Maintain Wiki sheet.

**Changed**
- The Files list remains most-recently-added first and now shows a per-file status
  badge: a green check when an ingest log matches that source, otherwise a dashed
  "ready" indicator.
- Files are selectable sidebar items. Selecting one opens a file detail pane with
  **Ingest into Wiki** and **Open File** actions, so a raw source can be processed
  on the spot.
- Added a shared `AgentOperationRunner` so the existing operations sheet, the file
  detail pane, and page-level queries all use the same mount refresh, staging, and
  edit-lock launch path.
- Every page reader now has a compact query field pinned below the rendered page,
  launching the same Query operation without opening the operations sheet.

**Skill pass.** Before code: `swiftui-pro`, `macos-design`, and
`typography-designer` pointed toward semantic Dynamic Type, standard macOS list
selection/detail behavior, labeled icon buttons, and progressive disclosure in the
content area. Post-code review checked the new views against SwiftUI design,
accessibility, and hygiene guidance: controls keep text labels for VoiceOver, type
uses system styles, and status is icon+color rather than color-only.

**Verified.** `make check` passes and `make test` passes (**321/321**). Added a
core regression test for the ingested-file status derived from log entries.

## 2026-06-16 — Product rename to Self Driving Wiki

Renamed app-facing product copy from WikiFS to **Self Driving Wiki** while leaving
bundle identifiers, SwiftPM target/module names, signing assets, and legacy
database filenames intact.

**Changed**
- `build.sh` and `Makefile` now produce/install `Self Driving Wiki.app`, with the
  SwiftPM executable target still built from `WikiFS` and copied into the renamed
  bundle.
- App/File Provider display strings, projection README/root labels, default legacy
  wiki display name, manifest product name, agent scratch/log cache directory, and
  the read-only error now say Self Driving Wiki.
- `README.md` and `PLAN.md` now present Self Driving Wiki as the product name while
  keeping technical identifiers such as `WikiFSCore`, `WikiFSFileProvider`, and
  `org.sockpuppet.WikiFS` explicit where they remain true.

**Skill pass.** Before code: `swiftui-pro`, `macos-design`, and
`typography-designer` pointed toward preserving semantic SwiftUI text and native
macOS naming surfaces rather than adding custom typography or visual treatment.
Post-code review kept the rename to visible strings/build metadata only, with no
new UI layout or type-scale changes.

## 2026-06-16 — Reader-first page detail UI

Started correcting the app's main interface: page selection now defaults to a
rendered reader instead of an always-visible markdown editor + preview split. The
product principle is that Self Driving Wiki is agent-maintained first; users should rarely
need manual source editing.

**Changed**
- `PageDetailView` now owns an explicit read/edit mode and a toolbar action:
  **Edit Page** / **Done Editing** (`Command-E`).
- `PageReaderView` is the default page surface: title plus rendered markdown in a
  readable column. It suppresses a duplicate leading `# Title` when the body starts
  with the same heading.
- `PageEditorView` is the rare manual mode: title field + markdown `TextEditor`,
  using the existing draft buffers and debounced autosave path.
- `MarkdownPreview` now constrains rendered blocks to the same readable width.
- Added `plans/page-reader-ui.md` and linked it from `PLAN.md`.

**Skill pass.** Before code: `swiftui-pro`, `macos-design`, and
`typography-designer` pointed toward progressive disclosure, reader-first content,
semantic Dynamic Type styles, and a restrained macOS article column rather than a
permanent edit/preview split. Post-code review found the view split aligned with
SwiftUI guidance: `PageDetailView` stays small, leaf views are separate files,
semantic fonts are used, and the editor reuses the existing model autosave seam.

**Verified.** `make check` passes, `make test` passes (**320/320**), and the
user-provided appshot shows the selected page in reader mode with the manual edit
button tucked into the toolbar.

## 2026-06-16 — Ingest division of labor: Opus curates/writes, Sonnet only digests — DONE ✅ (user-verified, merged to main)

CORRECTION to the model-tiering build below.
The prior build (commit `caebfd7`) tiered by model but with the WRONG division of
labor (tiny → Sonnet single pass; large → Opus *planner* that delegated **page
writing** to Sonnet `ingest-worker`s). The user's guiding principle: **Opus is
ALWAYS the curator — it decides what goes in the wiki and WRITES everything. Sonnet
exists ONLY to chew through large volumes of source content; Sonnet NEVER writes.**

**Corrected architecture.**
- **Tiny source** (`< 4 KB`, `IngestPlan.singleOpus`) → a single `--model opus` pass,
  no `--agents`. Opus reads the small staged source and writes the pages + index +
  log itself. (Opus must decide what belongs even for small sources.)
- **Large source** (`IngestPlan.opusCurator`) → `--model opus` curator + `--agents`
  `'{"source-reader":{"model":"sonnet","tools":["Bash","Read"],…}}'`. Opus INSPECTS
  the source's size/structure (`wc`/`head`/page count) WITHOUT reading the whole bulk,
  splits it into chunks, and forks **2–19** Sonnet `source-reader` DIGESTERS to READ
  the chunks in parallel and return STRUCTURED DIGESTS. Opus then synthesizes the
  digests, decides the page set, and WRITES every page + `index.md` + the log entry
  itself. Opus MAY fork more workers for follow-up QUESTIONS and MAY pull pages via
  `wikictl page get` to double-check — the `<20` cap is on TOTAL Sonnet invocations.
- The Sonnet worker has **read-only tools** (`["Read","Bash"]`, no wikictl), and its
  prompt (`IngestPlan.digesterPrompt`) carries NO write rule — it only reads + returns
  a digest. The write rule (`IngestWriteRule.writes`) now leads ONLY the Opus prompts
  (single + curator), since Opus is the writer (`OperationCommandTests` asserts both
  ways). Top-level `--model` is `opus` in BOTH Ingest modes; the tiering is purely in
  the fan-out. Query/Lint unchanged (single-Opus + write rule + WIKI_STATE +
  don't-rediscover).

**Verified (CLI 2.1.178, real `--agents` smoke test):** top level ran on
`claude-opus-4-8`; the `source-reader` subagent resolved to `claude-sonnet-4-6`
(`"resolvedModel":"claude-sonnet-4-6"`), READ the staged source via its `Read` tool,
and returned its digest to the Opus parent, which replied `DIGEST_RECEIVED: …`. No
wikictl anywhere in the worker. Delegation still surfaces as an `Agent` `tool_use` +
`system`/`task_started`/`task_notification` events; the `AgentEvent` parser maps those
to `.subagent` and the activity panel renders the fan-out as purple "reading" / green
"digested" rows (relabeled from "delegated"/"finished" + `doc.text.magnifyingglass`
icon, since the workers now READ, not write).

**Tests / build.** Reworked the two-mode argv + plan tests: tiny → `--model opus` no
`--agents`; large → `--model opus` + a read-only `source-reader` digester whose prompt
DIGESTS (not writes); the curator prompt carries the 2–19 guardrail + "fork more for
questions / pull pages to double-check" + "Opus writes every page"; the worker prompt
has no wiki-write instructions. `make test` → **320/320** green; `make` clean signed
bundle. Live gate (orchestrator `make install` + watch a large Ingest) pending: proof
is no mount-probing, Opus does the writing, a visible fan-out of 2–19 Sonnet *reader*
workers, and Opus optionally asking follow-ups / pulling pages.

### Superseded — 2026-06-16 — Ingest redesign: write-rule in the prompt, local staging, model tiering

Branch `feature/ingest-fewer-turns`. Fixes three problems a live Ingest run exposed.
(The model-tiering division of labor in item #3 below was corrected by the entry
above; items #1 and #2 — the write rule in the `-p` prompt, and local staging — still
stand.)

**1. Agent probed the read-only mount instead of writing.** Phase D moved the
`wikictl` write rule entirely into `--append-system-prompt`, which the agent
under-weights — in a real run it printed *"The mount is read-only. There must be a
dedicated tool for wiki mutations. Let me search."*, ran ToolSearch, then
`echo > pages/by-title/__wikitest__.md` to test the mount. Fix: the load-bearing
write rule + the exact `wikictl` write commands now lead EVERY `-p` prompt
(`IngestWriteRule.writes`), while the layout map / conventions stay in the schema
(DRY — asserted both ways in `OperationCommandTests`).

**2. Wasted orientation turns + laggy mount reads.** The app now STAGES into the
per-run scratch dir, reading from SQLite (not the ~5s-laggy mount): `WIKI_STATE.md`
(titles + index.md + log tail, via `WikiStateSnapshot.renderStateFile`) and, for
Ingest, the raw `source.<ext>` bytes (via `ingestedFileContent`). The prompt names
those absolute paths and forbids `wikictl page list` / re-reading index.md/log.md
(`IngestWriteRule.dontRediscover`). Staging is owned by `AgentLauncher` (it owns the
scratch dir); the per-op intent is the new app-side `OperationRequest`, whose pure
pieces (`AgentStaging` leaf-name math, the `WIKI_STATE.md` rendering, the plan
decision) are core-tested.

**3. Model tiering.** App picks the mode by source size (`IngestPlan.decide`,
threshold `tinySourceByteThreshold = 4096`). **Tiny** (`< 4 KB`) → single
`--model sonnet` pass, no `--agents`. **Non-tiny** → `--model opus` planner +
`--agents '{"ingest-worker":{"model":"sonnet",…,"tools":["Bash","Read"]}}'`: Opus
plans the page set, fans out to **2–19** Sonnet workers (prompt-level guardrail:
"use more than 1 and fewer than 20; size the fan-out to the material"), then Opus
synthesizes `index.md` + the log entry. Query/Lint stay single-agent Opus but ALSO
get the write rule + the staged state + the don't-rediscover directive. The worker
prompt is SELF-SUFFICIENT (a custom agent's `prompt` doesn't inherit
`--append-system-prompt`, so it embeds the full write rule).

**Verified mechanism (CLI 2.1.178, real `--agents` smoke test):** top level ran on
`claude-opus-4-8`, the `worker` subagent resolved to `claude-sonnet-4-6`
(`"resolvedModel":"claude-sonnet-4-6"`; `modelUsage` shows both). Aliases: `opus` →
`claude-opus-4-8`, `sonnet` → `claude-sonnet-4-6`. The `--agents` JSON shape is
`{"<name>":{"description","model","prompt","tools"}}`. Delegation surfaces in the
stream as an `Agent` `tool_use` plus `system`/`task_started` + `task_notification`
events — the `AgentEvent` parser now maps those to a `.subagent` event and the
activity panel renders the Opus→Sonnet fan-out as indented purple "delegated" /
green "finished" rows.

**Tests / build.** +20 tests (the two-mode argv builder, the 2..19 guardrail text,
the write-rule + staged paths + don't-rediscover assertions, the schema-not-
duplicated check, `IngestPlan` threshold, `AgentStaging` path math + WIKI_STATE.md
rendering, the `.subagent`/`Agent` parser cases). `make test` → **320/320** green;
`make` clean signed bundle. Live gate (orchestrator `make install` + watch an
Ingest) pending: proof is no mount-probing, few/no orientation turns, a visible
Opus→Sonnet fan-out.

## 2026-06-16 — URL ingest fix: share-link normalization + content sniffing

Branch `feature/url-ingest`. A real-world test exposed a gap: pasting a **Dropbox
share link** to a PDF stored the Dropbox HTML *preview page* (converted to junk
markdown) instead of the PDF. File-share hosts (Dropbox, Google Drive, OneDrive)
hand non-browser clients a JS interstitial unless you hit the direct-download host
— and Dropbox serves HTML for BOTH `dl=0` and `dl=1`. Two pure, tested fixes:

- **`ShareLinkNormalizer` (new, `WikiFSCore`)** — `normalize(_ url:) -> URL` with a
  list of provider `Rule`s. **Dropbox:** host `www.dropbox.com`/`dropbox.com` →
  `dl.dropboxusercontent.com`, preserving path + query (so the `.pdf` filename in
  the path and the `rlkey`/`e` auth params survive) — the verified rewrite that
  returns raw `%PDF` bytes. Conservative: an unrecognized URL passes through
  byte-for-byte. Google Drive / OneDrive shapes are stubbed in comments for trivial
  add-later. **Wired into `URLSessionFetcher.fetch`** (normalizes BEFORE the request),
  so every production fetch — `ingest` and `WikiStoreModel.ingestURL` — benefits.
- **Content sniffing in `URLIngestService.plan(for:)`** — `sniffContentType(_ data:)
  -> String?` reads leading magic numbers (`%PDF`→pdf, `\x89PNG`→png, `\xFF\xD8\xFF`
  →jpeg, `GIF8`→gif, `PK\x03\x04`→zip). When the declared type is ambiguous
  (`text/html`, missing, or `application/octet-stream` — see `shouldSniff`) but the
  bytes are clearly a known binary, store them VERBATIM as the sniffed type instead
  of running HTML→Markdown. A specific declared type (`application/pdf`, …) is
  trusted as-is. This is the backstop if an interstitial ever slips past the
  normalizer.

**Tests.** +5 `ShareLinkNormalizerTests` (www/bare-host rewrite preserves
path+query+filename; non-share URL unchanged; case-insensitive; no double-rewrite),
+6 in `URLIngestServiceTests` (html-labeled-%PDF→`.pdf` byte-identical;
octet-stream-PNG→`.png`; genuine HTML still→markdown; real PDF still→`.pdf`; the
`sniffContentType`/`shouldSniff` tables). `make test` → **300/300** green; `make`
clean signed bundle. The original failing URL
(`www.dropbox.com/scl/fi/…/CPP_behaviorgen.pdf?…&dl=0`) now normalizes to
`dl.dropboxusercontent.com`, fetches `%PDF` bytes, and stores `CPP_behaviorgen.pdf`.

## 2026-06-16 — Feature: ingest a resource by URL — DONE ✅ (live-verified, merged to main)

Fetch a URL and land it as an ingested
file in the ACTIVE wiki — exactly like a drag-dropped file, so the existing
"Ingest into wiki" `claude -p` operation can summarize it. HTML is converted to
clean Markdown; PDFs/text/binaries are stored verbatim. All deterministic logic is
pure + unit-tested with a FAKE fetcher (NO real network in tests); the UI is a small
native sheet. **221 → 289 tests; clean signed bundle (app + appex + `wikictl`).**

**Added (`WikiFSCore`, all pure + dependency-free)**
- **`HTMLToMarkdown`** — a hand-rolled, tolerant HTML→Markdown converter. We
  deliberately do NOT use `NSAttributedString(html:)` (WebKit-backed,
  main-thread-only, non-deterministic, untestable). A tokenizer
  (`HTMLTokenizer.swift`) + a streaming renderer (`HTMLMarkdownRenderer.swift`) +
  an entity decoder (`HTMLEntities.swift`). Strips `script`/`style`/`head`/`nav`/
  `footer`; prefers `<article>`/`<main>`/`<body>` content; maps `h1`–`h6`→`#`…,
  `p`→paragraphs, `br`→newline, `a`→`[t](u)`, `strong`/`b`→`**`, `em`/`i`→`*`,
  `code`→`` ` ``, `pre`→fenced block, `ul`/`ol`/`li`→lists (nesting-indented),
  `blockquote`→`>`, `img`→`![alt](src)`; decodes named + numeric (`&#NN;`/`&#xNN;`)
  entities; collapses whitespace; extracts `<title>` (for the filename). Every loop
  is input-length-bounded — never crashes/loops on malformed/unclosed tags
  (degrades to literal text). 45 tests.
- **`URLIngestService`** — the fetch→dispatch→store pipeline with an INJECTED
  `URLResourceFetcher` (so dispatch/filename/store is unit-tested with a fake
  fetcher). `Content-Type` dispatch: `text/html`/`application/xhtml+xml` →
  `HTMLToMarkdown` → store the **markdown** as `.md` (named from `<title>`);
  `application/pdf` → raw bytes as `.pdf`; other `text/*` → raw as-is; else → raw
  bytes with a MIME/URL-inferred extension. Filename rules: HTML uses the sanitized
  `<title>` (else the URL stem, else host), via `FilenameEscaping.escapeTitle` +
  an 80-char cap + an `ensureExtension` guard; derives from the FINAL (post-redirect)
  URL. `normalizeURL` trims whitespace + defaults a missing scheme to `https://` +
  rejects non-http(s). 20 tests.
- **`URLSessionFetcher`** — the production `URLResourceFetcher`: `URLSession`
  (ephemeral config) with a desktop Safari User-Agent (so sites don't 403), redirect
  following (reports the final URL), a bounded timeout, and non-2xx → `httpStatus` /
  transport error → `network` translation. The app is un-sandboxed, so this needs no
  entitlement and fires no macOS prompt.

**Added / changed (app — `WikiFS`)**
- **`WikiStoreModel.ingestURL(_:fetcher:)`** — the model seam: validate + fetch OFF
  the main actor (the GET shouldn't stall the UI), then store on the main actor via
  the SAME `store.ingestFile` path drag-ingest uses (so the file shows up under Files
  + `files/by-{id,name}` and is pickable in Operations → Ingest), `reloadIngestedFiles()`
  + `onPageDidChange?()`. Pure `URLIngestService.plan(for:)` decides filename+bytes
  so no `@Sendable` store closure crosses the actor boundary. 3 tests.
- **`AddFromURLSheet`** — a clean native sheet: a paste-friendly URL field
  (auto-focus, submit-on-Return), a prominent **Fetch** button, an inline progress
  spinner while fetching, and an inline red error row on failure. SWIFTUI-RULES:
  the status row is always-mounted + height-animated (§1.1, no insert/remove
  transition), the URL is read fresh at click time (§3.5), semantic Dynamic-Type
  fonts (§5.1), no formatters in `body`. On success it dismisses and the new file
  appears live.
- **Affordance** — "Add from URL…" lives in TWO native spots in `SidebarView`: the
  sidebar toolbar (next to New Page, always available) and an inline icon button in
  the "Files" section header (next to the content it produces). Also updated the
  Operations → Ingest empty-state hint to mention it.

**Skills (CLAUDE.md, before & after):** `swiftui-pro`, `macos-design`,
`typography-designer`, `airbnb-swift-style` — the sheet matches the app's existing
utility type scale (`.headline`/`.subheadline`/`.body`/`.callout`, same as
`OperationsView`) and animation/state rules; no findings to apply.

**Tests/build.** `make test` → **289/289** green (+45 `HTMLToMarkdownTests`, +20
`URLIngestServiceTests`, +3 `WikiStoreModelURLIngestTests`); `make` produces a clean
signed bundle.

**Live gate (orchestrator `make install` + user):** open a wiki → click "Add from
URL…" (sidebar toolbar) → paste an HTML page URL (e.g.
`https://en.wikipedia.org/wiki/Photosynthesis`) → Fetch → a `.md` file named from the
page title appears under Files; paste a PDF URL (e.g.
`https://www.w3.org/WAI/ER/tests/xhtml/testfiles/resources/pdf/dummy.pdf`) → a `.pdf`
appears (raw bytes). Then Maintain Wiki → Ingest → pick the fetched file → it
summarizes like any dropped file.

## 2026-06-16 — LLM Wiki Phase D: the schema — DONE ✅ (gate passed)

Branch `llmwiki/phase-d-schema` (stacked on `llmwiki/phase-c-claude-ops`).
Implements `plans/llm-wiki.md` Phase D: replaces the stub `SystemPrompt.defaultBody`
with the real wiki-maintainer schema, and slims the operation `-p` prompts now that
the schema is delivered every run via `--append-system-prompt`. **Cheap, mostly
prose — no new views, no migration changes.**

**Verified (live gate — user created the wiki; orchestrator verified via Bash; real `make clean && make install`, real-signed, fresh wiki `GateD`)**
- **Byte-identity ✅:** a freshly-created wiki's `CLAUDE.md` ≡ `AGENTS.md` ≡ the
  seeded `system_prompt` row body — all `sha256 f3174a5b…`, **5362 bytes**, the
  new "# Wiki Maintainer Instructions" schema (read raw via `writefile` to avoid
  the `sqlite3`-CLI trailing-newline artifact). The projection serves the same
  body under both names, as in the post-v0 system-prompt gate.
- **Agent reads it ✅:** a real `claude -p` launched with the new schema as
  `--append-system-prompt` named the FULL `wikictl` surface from its instructions
  alone — `page list/get/upsert/delete`, `index set`, `log append --kind …`.
- **Migration ✅:** the new wiki seeds the new schema; an EXISTING wiki
  (`GateCFresh`) is **unaffected** — still the old 762-byte stub (no `wikictl`),
  exactly as required (only `defaultBody`, the v2→3 seed + projection fallback,
  changed; no path rewrites an existing row).
- **Prompt de-duplication ✅:** the ~30-line `toolingPreamble` (layout +
  `wikictl` cheatsheet + read-after-write rule) is GONE from the `-p` prompts —
  each op now carries just the task + the resolved `WIKI_ROOT` (+ Ingest's source
  path / Query's question), relying on `CLAUDE.md` (via `--append-system-prompt`)
  for the schema. The exact seam the user flagged during Phase C.
- 211 → **221** tests (also fixed the last same-millisecond ULID flake), all green.

**What changed**
- **`SystemPrompt.defaultBody` is now the real maintainer schema** (`WikiFSCore/
  SystemPrompt.swift`) — addressed to the maintaining agent ("You maintain this
  wiki…"), tight and skimmable. Documents: the **layout** (`pages/by-{title,id}`,
  immutable `files/by-{name,id}`, `index.md`/`log.md`/`TREE.md`, `indexes/*.jsonl`,
  `manifest.json`, `CLAUDE.md`≡`AGENTS.md`); **conventions** (page titling,
  `[[wiki links]]`/`[[Target|alias]]`, summarize-don't-discard, entity vs concept
  page shapes, citing sources by their `files/…` path); **tooling** — the full
  `wikictl` command reference (`page list/get/upsert/delete`, `index set`,
  `log append`), **write via `wikictl` NEVER the filesystem** (mount is read-only),
  `wikictl` on PATH + targets the wiki via `WIKI_DB` (do NOT pass `--wiki`), and the
  **read-after-write rule** (read back via `wikictl page get` because the mount lags
  ~5s); **workflows** — the Ingest/Query/Lint playbooks in order; **sources** — raw
  `files/` may be PDFs/images, use the `Read` tool (PDF text first, images
  separately). This IS each wiki's per-wiki `CLAUDE.md`/`AGENTS.md`; the user
  co-evolves it in-app.
- **Slimmed the operation `-p` prompts** (`WikiOperation.swift`). The Phase-C
  `toolingPreamble` (layout map + `wikictl` cheatsheet + read-after-write rule) is
  REMOVED — that content now lives only in the system prompt, delivered every run via
  `--append-system-prompt`. Each prompt is now the per-op task + the per-run facts
  the schema can't contain: the resolved absolute `WIKI_ROOT` and (Ingest) the
  source's absolute path / (Query) the question. E.g. Ingest is now "Follow the
  Ingest workflow from your instructions… WIKI_ROOT: `<abs>` Source: `<abs>/…`". DRY
  against the schema — no second copy of the layout/cheatsheet to drift.
- **Migration UNCHANGED — verified, not disturbed.** The v2→3 seed and the
  projection fallback both reference the same `defaultBody` constant, so changing the
  constant seeds NEW wikis with the new schema while leaving EXISTING wikis untouched
  (the seed runs only inside `if version < 3` at table-creation; there is no code
  path that rewrites an existing `system_prompt` row to the default). A new test
  (`existingSystemPromptRowIsNotOverwrittenOnReopen`) pins this. `CLAUDE.md`≡
  `AGENTS.md`≡seeded body still holds structurally (both projection nodes serve
  `systemPromptDocument().body`, which returns the seeded `defaultBody`).

**Also in this phase — hardened File Provider domain registration (Phase D gate
finding).** During the Phase D gate a freshly-created wiki ("GateD") did NOT mount
until the app was relaunched, with NO error shown. The create→register→mount code
path was logically correct (`WikiManager.createWiki` → `registerDomain` →
`FileProviderSpike.registerDomain` → `NSFileProviderManager.add(domain)`, the same
call launch uses), but registration was **brittle and silent under a busy/churned
`fileproviderd`**: a single `add(domain)` that swallowed any error into an
unsurfaced `status` string and never verified/retried/nudged. Hardened
`FileProviderSpike.registerDomain(id:displayName:)` WITHOUT changing its injected
shape:
- **Surfaces failures** — a real `add` error is now `print`ed to the console AND
  kept in `status` (never buried); already-exists stays benign (the verify below
  confirms presence).
- **Verifies + bounded retry** — after each `add` it confirms the domain actually
  appears in `NSFileProviderManager.domains()`; if a busy daemon didn't take it, it
  backs off (~0.6 s async sleep — never blocks the main actor) and retries, up to 3
  attempts, then fails LOUDLY (console + `status`) and returns `false`.
- **Nudges initial enumeration** — on a verified add it signals the new domain's
  `.rootContainer` + `.workingSet` enumerator (the same `signalEnumerator` path
  `signalChange` uses, scoped to THIS domain) so the daemon materializes the root
  promptly instead of waiting for an external trigger — this is what makes the mount
  appear right after create.
The decision arithmetic (registered? / retry? / failed?) is extracted into a PURE,
unit-tested `WikiFSCore/DomainRegistrationPolicy` (mirroring `PathPreflight`) so the
FileProvider-importing `FileProviderSpike` stays thin side-effect glue. Idempotent +
safe to call repeatedly (launch calls it per wiki via `registerAllDomains`, create
once); the `WIKIFS_REENUMERATE` one-shot remove+re-add hatch is preserved.
`DomainRegistrationPolicyTests` (10) covers exact-match membership, the
retry-while-attempts-remain / fail-after-max decision table, and full-loop
simulations (registers on the final attempt; fails when the domain never appears).
**Guaranteed by the code:** on a healthy-but-momentarily-busy daemon, create→mount
is immediate (verify+retry+nudge) and any real failure is loud + self-healing rather
than silent. **Still daemon-dependent:** a fully *wedged* replica (the `ISSUES.md`
churned-domain case) is NOT rescued by retry — it needs a domain teardown — and the
exact end-to-end timing can't be proven without a clean (un-churned) `fileproviderd`.

**Tests/build.** Updated `OperationCommandTests` to the slimmed prompt shape: each
prompt now carries the resolved `WIKI_ROOT` and defers to "the … workflow from your
instructions", and the inline layout map / `wikictl` cheatsheet / read-after-write /
`--wiki` reminders are asserted GONE. New `SystemPromptTests` pin the schema content
(names every `wikictl` command, the layout, conventions, workflows, the PDF/Read
note) and the migration invariant (existing row not overwritten). **Also fixed the
last same-millisecond ULID flake** (`PageUpsertTests.upsertByTitleResolvesDuplicate
ToLowestULID` assumed creation order == ULID order; `ULID.generate()` is NOT
monotonic within a ms, so it now derives the expected lowest id from the actual ids
— matching the fix already applied to `WikiLinkNavigationTests`/`WikiLinkStoreTests`).
`make test` → **221/221 green** (211 schema-phase + 10 `DomainRegistrationPolicyTests`);
`make` produces a clean signed bundle (app + appex + `wikictl`, real identity).

**Notes / what the independent verifier should watch (the Phase-D gate)**
- The new default is **byte-identical** across a wiki's `CLAUDE.md` and `AGENTS.md`
  and matches the seeded DB body (use a freshly-created wiki; one-shot
  `WIKIFS_REENUMERATE=1` may be needed to surface the files on an already-materialized
  domain).
- A fresh `claude -p` launched against a NEW wiki reads the schema as its system
  prompt and **can name the `wikictl` commands** (`claude` on PATH; macOS-26 TCC
  prompt re-fires on a re-signed install).
- Migration seeds new wikis with the new schema; **existing wikis are unaffected**.

## 2026-06-16 — Preview polish: clickable `[[wiki-links]]` — DONE ✅ (live-checked)

Surfaced during the Phase C gate: the in-app Markdown preview rendered
`[[Photosynthesis]]` as literal dead text because `AttributedString(markdown:)`
is CommonMark and has no `[[…]]` concept. The link *graph* was already correct
(`page_links` / `links.jsonl`); this was purely a preview/navigation gap. The
on-disk / mounted body STAYS literal `[[…]]` — this is an in-app render concern
only, nothing is written back.

What landed:
- `WikiFSCore/WikiLinkMarkdown.swift` — pure, view-free transform
  `linkified(_:isResolved:)` that rewrites every `[[Title]]` / `[[Target|alias]]`
  span into a real Markdown link on a private `wiki://` scheme
  (`[[Photosynthesis]]` → `[Photosynthesis](wiki://page?title=Photosynthesis)`;
  alias displays the alias, links by the URL-encoded target). Reuses
  `WikiLinkParser`'s exact bracket grammar; rewrites EVERY occurrence (the parser
  de-dupes for the graph, the preview must not). Skips spans inside inline code
  (`` `…` ``) and fenced ``` blocks so code samples stay literal. Resolution is
  injected as a closure, so a resolved target gets host `page` (navigates) and a
  missing one host `missing` (rendered dimmed, inert).
- `WikiFS/MarkdownPreview.swift` — linkifies each block through the model's
  `pageExists`, dims unresolved (`wiki://missing`) link runs to `.secondary`, and
  installs an `OpenURLAction` that drives `store.selectPage(byTitle:)` for our
  scheme (`.handled`) while letting real external URLs fall through
  (`.systemAction`).
- `WikiFSCore/WikiStoreModel.swift` — `selectPage(byTitle:)` (resolve title→id,
  lowest-ULID on duplicates, navigate through the SAME `select(_:)` seam the
  sidebar uses so the outgoing page flushes first) + `pageExists(title:)`.
- Tests: `WikiLinkMarkdownTests` (transform: forms, encoding, code-span/fence
  protection, escaping, idempotence, URL round-trip) + `WikiLinkNavigationTests`
  (resolve-to-id, missing no-op, duplicate→lowest-ULID, flush-on-navigate). Suite
  green at 207. `make` builds + signs clean.

Still DRAFT until the live check: click a resolved `[[link]]` in the running app
and confirm it selects that page; confirm a missing link reads dimmed and inert.

## 2026-06-16 — Phase C gate fix: skip-permissions + layout-up-front + `TREE.md` — DONE ✅ (folded into the Phase C gate pass below)

The first live Phase-C gate FAILED with two real defects (still DRAFT — re-gate
pending). Fixing exactly these on `llmwiki/phase-c-claude-ops`:

1. **Every command the agent issued was rejected → ZERO output.** The
   `--allowedTools 'Bash(wikictl:*) Bash(cat:*) …'` allowlist can't statically
   verify a command containing a `$WIKI_ROOT`/`$WIKI_DB` shell expansion or a
   compound command, so the CLI demanded approval — and in `-p` (non-interactive)
   mode there is no approval prompt, so the run was dead on arrival (no page, no
   log, no index bump). The allowlist is fundamentally incompatible with the
   env-var paths the whole design depends on. **Fix:** dropped the `--allowedTools`
   pair, now pass **`--dangerously-skip-permissions`** — the "frictionless mode"
   fallback `plans/llm-wiki.md` sanctions (app is local, un-sandboxed,
   user-initiated; the agent only has `wikictl` + read-only shell intent). Verified
   accepted by the installed CLI (2.1.178 — a real `-p … --dangerously-skip-permissions`
   run reports `permissionMode":"bypassPermissions"`). Everything else on the argv
   is unchanged.
2. **The agent burned ~6 turns probing for basic structure** (`ls`, `env`,
   `mount`, `wikictl --help`) because it had no map. **Fix, two parts:**
   - **In-prompt layout (load-bearing).** `WikiOperation.prompt` is now
     `prompt(wikiRoot:)` and leads with a concrete map: the **resolved absolute
     `WIKI_ROOT`** (passed in — not `$WIKI_ROOT` for the agent to expand, which is
     exactly what the permission system choked on AND what made it hunt), the fixed
     `pages/by-{title,id}` + `files/by-{name,id}` + `index.md`/`log.md`/`TREE.md`/
     `manifest.json`/`indexes/*.jsonl` layout, the `wikictl` cheatsheet (incl. the
     exact `printf '%s' "<body>" | wikictl page upsert --title T --body-file -`
     form), and that `wikictl` is on PATH + already targets the wiki via `$WIKI_DB`
     (so do NOT pass `--wiki`). For Ingest, the **chosen source's resolved absolute
     path** is injected so the agent reads it immediately instead of hunting.
   - **`TREE.md` at the wiki root** — a new read-only projection (`WikiTreeRenderer`,
     pure) served exactly like `log.md`/`index.md` (new container id `tree-md`, root
     child, working-set re-emit, `contents`). It is the same orientation map,
     largely STATIC (the projection layout is fixed) plus two cheap live counts
     (pages, files). Versioned by `changeToken()` like `log.md` — NOT a separate
     token term: the only thing that moves is the two counts, and those move with
     the same page/file folds the token already tracks, so a token-versioned node
     re-fetches precisely when the counts can change. Prompts reference it ("full
     layout is in `TREE.md`").

**KEPT exactly as-is** (they work — they're how we SAW the failure): the streaming
activity panel, `AgentEvent`/`AgentEventParser`, the backend `run.jsonl`/
`run.stderr.log`, the per-wiki edit lock, the change-bridge live refresh, and the
`claude` PATH preflight.

**Tests/build.** `OperationCommandTests` updated: argv now asserts
`--dangerously-skip-permissions` (no `--allowedTools`); the prompt builder is
asserted to lead with the layout + resolved `WIKI_ROOT` + cheatsheet + (Ingest)
the resolved source path. New `WikiTreeRendererTests` covers the layout/cheatsheet
content, the live counts (incl. singular/plural), and determinism. `make test`
green at **184**; `make` produces a clean signed bundle.

(Original Phase-C build notes below — the parts about `--allowedTools` are
superseded by the skip-permissions switch above.)

## 2026-06-16 — LLM Wiki Phase C: `claude -p` operations (Ingest / Query / Lint) — DONE ✅ (gate passed)

Branch `llmwiki/phase-c-claude-ops` (stacked on `llmwiki/phase-b-index-log`).
Implements `plans/llm-wiki.md` Phase C: generalizes the v0 agent launcher into
three discrete `claude -p` operations scoped to the active wiki, the per-wiki
edit lock, and the live-sidebar refresh during a run. The deterministic seams
(prompt/command/env construction, PATH preflight, edit-lock state machine) are
unit-tested; the real agent run was verified live. This phase took **three
gate-driven course-corrections** (the two entries above + this one are the
sub-stories): (1) the streaming UI + backend logs were missing → built them
(without live visibility the agent "just sits there"); (2) the least-privilege
`--allowedTools` allowlist rejected EVERY command (it can't match a command
containing the `$WIKI_ROOT`/`$WIKI_DB` expansion, and `-p` has no approval
prompt) → switched to `--dangerously-skip-permissions` + inject the wiki layout
up front (`TREE.md` + in-prompt map) so the agent acts instead of probing; (3)
ingested `[[wiki-links]]` rendered as dead text in the preview → made them
clickable/navigable.

**Verified (live gate — user drove the app UI, orchestrator verified via Bash; real `make clean && make install`, real-signed, on a freshly-created wiki `GateCFresh`)**
- **Ingest (structural pass):** a real `claude -p` Ingest of `photosynthesis.txt`
  took the wiki from **1 page → 6** (Photosynthesis + Chloroplast, Chlorophyll,
  Light-Dependent Reactions, Calvin Cycle), appended an **`ingest` log row**,
  rewrote **`index.md` (v2→v3)**, and built a **9-edge `[[link]]` graph**
  (`page_links` + `indexes/links.jsonl`) — all written via `wikictl`, the
  read-only mount untouched. The gate is structural (the agent is
  non-deterministic), and all three required artifacts (≥1 page, ≥1 log entry,
  index changed) landed.
- **Query:** returns a cited answer in the panel + a `query` log row.
- **Live streaming + backend logs:** the activity panel showed real tool-call
  rows (`printf … | wikictl page upsert`, etc.), assistant text, and the green
  terminal result **as they streamed**; **4 `run.jsonl`** backend logs captured
  the full NDJSON event stream (system init → assistant → tool_use → tool_result
  → result) under `~/Library/Caches/WikiFS-agent/<uuid>/`, with `run.stderr.log`
  sibling and a "Reveal Log" button.
- **Edit lock:** the in-app editor was read-only with the "Agent is updating the
  wiki…" banner for the run's duration and re-enabled on completion (per-wiki).
- **Clickable wiki-links:** in the preview, `[[Photosynthesis]]` etc. render as
  accent links and navigate to the target page on click; unresolved links render
  dimmed + inert. (On-disk/mount bytes stay literal `[[…]]`.)
- **Tests 161 → 207** across the phase (operations seams, `AgentEvent` parser,
  `WikiTreeRenderer`, `WikiLinkMarkdown` linkifier + navigation), all green and
  deterministic — also fixed three pre-existing same-millisecond ULID-ordering
  flakes (log order; duplicate-title resolve; link order) surfaced along the way.

**Carry-forward to Phase D:** the operation `-p` prompts currently INLINE the
schema (layout + `wikictl` cheatsheet + read-after-write rule) as a stopgap,
because today's `system_prompt`/`CLAUDE.md` is still the Phase-D stub. Phase D
puts the real schema in `CLAUDE.md`; the `-p` prompts should then slim down to
just the per-op task (the inline preamble becomes the duplication to remove).

**Flag surface confirmed (claude-api skill + installed CLI `2.1.178`)**
- `claude --help` confirms `-p`/`--print`, `--append-system-prompt <prompt>`,
  `--allowedTools` ("Comma or space-separated list of tool names"), and
  `--output-format text|json|stream-json`.
- **Streaming is now load-bearing, not polish.** A plain `claude -p` emits almost
  nothing until the final result, so the operations panel sat blank for the whole
  run — "you just sit there waiting for claude to do nothing", undebuggable. We now
  always pass `--output-format stream-json --verbose --include-partial-messages`.
  `--help` (and a real captured run) confirm `--verbose` is REQUIRED with
  `stream-json` in print mode, and `--include-partial-messages` is accepted (it
  adds token-level `stream_event` deltas).
- **Real event shapes captured from the installed binary** (a live
  `claude -p 'say hi' --output-format stream-json --verbose --include-partial-messages`
  run, NDJSON, one per line): a `{"type":"system","subtype":"init",…,"model":…}`
  event; `{"type":"assistant","message":{"content":[{type:"text"|"tool_use",…}]}}`;
  `{"type":"user","message":{"content":[{type:"tool_result","is_error":…,"content":…}]}}`;
  and the terminal `{"type":"result","is_error":…,"result":…}`. The bookkeeping
  types we DON'T render — `system/status`, `rate_limit_event`, the
  `--include-partial-messages` `stream_event` deltas, `system/post_turn_summary` —
  were all observed and are intentionally skipped (the complete `assistant`/`user`
  events carry the same content cleanly).
- Validated the EXACT combination parses on the real binary (no unknown-flag
  error). The space-separated `Bash(<cmd>:*)` allowlist form is what the installed
  CLI accepts.

**Added (deterministic, unit-tested — `WikiFSCore`)**
- **`WikiOperation`** — a PURE enum (`ingest(sourcePath:)` / `query(question:)` /
  `lint`) that renders each operation's OWN self-sufficient `-p` prompt. Because
  the per-wiki `system_prompt` is still the Phase-D stub, each prompt spells out
  the `wikictl` workflow (write via `page upsert`, record via `log append`,
  rewrite via `index set`, **read-back via `page get`** since the mount lags ~5s)
  and reminds the agent the mount is read-only + `WIKI_DB` already selects the
  wiki (so it must NOT pass `--wiki`). Ingest names all four write steps (≥1
  summary page, entity/concept pages, rewrite `index.md`, append `log.md`); Query
  asks for a cited answer; Lint asks for the health report + a `log append`.
- **`OperationCommand`** — the PURE `claude -p` argv/env/cwd builder, the
  load-bearing testable seam. `build(...)` assembles:
  `claude -p <prompt> --output-format stream-json --verbose
  --include-partial-messages --append-system-prompt <wiki's system_prompt>
  --allowedTools '<allowlist>'` with **env** `WIKI_ROOT=<live mount>` +
  `WIKI_DB=<wiki ULID>` +
  `PATH=<Helpers dir>:<inherited PATH>` (so the agent's `wikictl` calls resolve),
  **cwd** = a per-run writable scratch dir (NOT the read-only mount, decision #4).
  `allowedTools` = `Bash(wikictl:*) Bash(find:*) Bash(cat:*) Bash(grep:*)
  Bash(printf:*) Read Grep Glob` (least privilege: wikictl writes + read-only
  shell + read tools; `printf` for the stdin-piped `--body-file -` writes).
- **`AgentEvent` + `AgentEventParser` + `ToolInputSummary`** (NEW, PURE,
  unit-tested) — the typed projection of the stream-json NDJSON. `parse(line:)`
  decodes ONE line → `.systemInit(model:)` / `.assistantText(String)` /
  `.toolUse(name:inputSummary:)` / `.toolResult(isError:summary:)` /
  `.result(isError:text:)`, and is deliberately TOLERANT: an empty line → `nil`;
  any line that fails to decode (garbage, a mid-object partial flush) →
  `.raw(line)` rather than throwing; unmodeled event types (`stream_event`
  deltas, `system/status`, `rate_limit_event`, `post_turn_summary`) and
  renderable-content-free `assistant` blocks (e.g. `thinking`-only) → `nil`. So a
  bad/unfamiliar line never crashes or drops the run. `ToolInputSummary` renders a
  concise one-liner per `tool_use` (Bash → its command, Read/Write/Edit → the
  path, Glob/Grep → the pattern, else a sorted `key=value` join), elided at 120
  chars — so the feed reads `Bash  wikictl page upsert --title "…"` not a JSON
  blob. Built against the REAL captured shapes, not a guess.
- **`PathPreflight`** — pure `resolve(executable:onPath:fileExists:)` first-hit
  PATH search + `resolveOnLoginShell()` (a real `zsh -lc 'echo $PATH'` hop, since
  the GUI app's process PATH lacks `/opt/homebrew/bin`). Surfaces a clear in-UI
  error if `claude` isn't resolvable instead of a cryptic spawn failure.
- **`EditLock`** — `@MainActor @Observable` per-wiki lock state machine (decision
  #6): `lock(wikiID:)` / `unlock(wikiID:)`, keyed by ULID, **re-entrant via a
  count** (two ops on one wiki don't unlock each other early), stray-unlock
  clamped at zero. (The app drives the lock through `WikiStoreModel` directly —
  `EditLock` is the tested standalone state machine for the per-wiki contract.)

**Added / changed (app — `WikiFS`)**
- **`AgentLauncher` generalized + made observable** from a free-form `zsh -lc
  <cmd>` to
  `run(operation:wikiID:wikiRoot:systemPrompt:wikictlDirectory:onLock:onUnlock:)`:
  runs the PATH preflight, builds the per-run scratch dir under Caches, assembles
  the command via `OperationCommand.build`, spawns `claude`. **The stdout
  `readabilityHandler` now does double duty**: it tees every raw byte to the
  per-run `run.jsonl` log AND feeds bytes through a line buffer (carrying over a
  partial trailing line until its newline arrives, so the parser only ever sees
  complete NDJSON) → `AgentEventParser` → a published
  `private(set) var events: [AgentEvent]` the UI renders live, all on the main
  actor. It also keeps a `rawTranscript` mirror and separate `stderr`. The
  no-`waitUntilExit` model is preserved — completion arrives via
  `terminationHandler`, which drains any trailing partial line, closes the log
  handles, releases the edit lock (`onUnlock`), and records the exit status, so a
  killed/crashed agent still re-enables editing. Exposes `preflightError`,
  `runningKind`, `exitStatus`, and `logFileURL` for the UI. `resolveClaude` is
  injectable for tests.
- **Backend logs (the user-required "fully reconstructable after the fact").**
  Each run's scratch dir holds `run.jsonl` (every raw stream-json byte, unparsed)
  and a sibling `run.stderr.log` (claude's diagnostics). The scratch dir is now
  PERSISTED (not deleted on termination) so a finished run can be replayed;
  `logFileURL` surfaces `run.jsonl` so the UI can reveal it in Finder.
- **`HelpersLocation`** — resolves the `wikictl` dir to prepend to the agent's
  PATH: the signed bundle's `Contents/Helpers` first, then `build/` and the
  running-exe dir for dev (`swift run`). Confirmed live: the embedded+signed
  `wikictl` resolves on PATH and honors `WIKI_DB`.
- **Edit lock wired into the model.** `WikiStoreModel.beginAgentRun()` flushes
  pending edits then sets `isAgentRunning` (editor → read-only, autosave PAUSED —
  both `scheduleAutosave` and `systemPromptChanged` early-return while running, so
  an in-app save can't clobber the agent's `wikictl` writes). `endAgentRun()`
  clears the flag, `reloadFromStore()`s the sidebar, and reloads the open
  document's draft from the (agent-rewritten) source. The live change-bridge
  `reloadFromStore` is UNAFFECTED by the lock, so the sidebar still fills in as the
  agent's writes land mid-run. `currentSystemPromptBody()` exposes the singleton
  for `--append-system-prompt`.
- **UI (macos-design + typography-designer + swiftui-pro).** `OperationsView`
  replaces the old "Run Agent" sheet: a segmented Ingest/Query/Lint picker, an
  Ingest source picker (over the wiki's ingested files → its `files/by-id/…`
  mount path via the shared `FilenameEscaping`), a Query text box, a Lint button,
  the live activity panel, and the PATH-preflight error.
- **`AgentActivityView` (NEW) — the live transcript.** Replaces the old "raw blob"
  console: an auto-scrolling `LazyVStack` over `launcher.events`, one row per typed
  event — a `tool_use` row is an SF Symbol (terminal/doc/pencil/magnifyingglass per
  tool) + monospaced name + concise input summary; assistant text is body prose;
  the terminal result is distinct (green `checkmark.seal` / red
  `exclamationmark.octagon` by `is_error`); a spinner + "Starting <kind>…"
  placeholder shows while a run has started but emitted nothing yet, so the panel
  is NEVER staring at nothing. Auto-scroll animates a scroll OFFSET to a
  zero-height bottom anchor (`onChange(of: events.count)`) — never inserts/removes a
  structural view (SWIFTUI-RULES §1.1); rows derive purely from their `AgentEvent`
  (§3.1); semantic Dynamic-Type fonts (§5.1); no cached formatters in `body`. A
  stderr "Diagnostics" sub-panel surfaces claude's stderr when non-empty, and the
  footer's **"Reveal Log"** button opens `run.jsonl` in Finder. The raw transcript
  stays available via `launcher.rawTranscript` for debugging.
- `AgentRunBanner` ("Agent is updating the wiki…") sits above both
  editors — **always-mounted, height-animated** per SWIFTUI-RULES §1.1 (no
  structural transition), Reduce-Motion-aware; both detail views `.disabled` while
  `store.isAgentRunning`. Semantic Dynamic-Type fonts throughout. Toolbar button
  renamed "Maintain Wiki" (`sparkles`). Obsolete `AgentLauncherView` removed.
- Tests: 135 → **180** (+45). `OperationCommandTests` (updated: argv now asserts
  `-p`, the `--output-format stream-json --verbose --include-partial-messages`
  streaming flags, `--append-system-prompt`, `--allowedTools` in exact order, plus
  a dedicated `streamJSONRequiresVerbose` check; allowlist scope,
  `WIKI_ROOT`/`WIKI_DB` env, Helpers-dir PATH prepend, scratch-cwd-not-mount,
  base-env inheritance, every-kind builds; the three prompts name their `wikictl`
  steps + read-after-write rule + `do NOT pass --wiki`; PATH preflight
  found/missing/order/absolute/empty). **`AgentEventParserTests` (NEW, ~19)** —
  each event type from REAL captured sample lines (system/init w/ + w/o model,
  assistant text, Bash/Read `tool_use` summaries, string + array `tool_result`,
  success + error `result`); tolerance (garbage → `.raw`, truncated mid-object →
  `.raw`, empty/whitespace → `nil`, unmodeled types → `nil`, renderable-free
  assistant → `nil`); `ToolInputSummary` (unknown-tool sorted `key=value`,
  long-command elision, empty input). `EditLockTests` (8, unchanged).
  `make test` → **180 green, all deterministic** (the prior log-ordering flake was
  fixed in `38aeb6f` — `ts+rowid` ordering); `make` clean signed bundle (app +
  appex + `wikictl`, real identity).
- **End-to-end live smoke (this session).** Drove the FULL pipeline against the
  installed `claude 2.1.178`: built the real `OperationCommand` argv, spawned
  `claude -p`, teed raw stdout to `run.jsonl`, line-buffered through the real
  `AgentEventParser`. Result: parsed `systemInit(model: "claude-opus-4-8[1m]")` →
  `assistantText("PONG")` → `result(isError:false, text:"PONG")`, and `run.jsonl`
  populated (7,917 bytes). The activity stream AND the backend log both populate
  on a real run. (Smoke harness was temporary; removed after the run.)

**The EXACT command each op builds** (env + cwd shown):
```
cd <Caches>/WikiFS-agent/<uuid>  \   # writable scratch (also holds run.jsonl +
                                     #   run.stderr.log); NOT the read-only mount
  env WIKI_ROOT=<live mount> WIKI_DB=<wiki ULID> \
      PATH=<WikiFS.app/Contents/Helpers>:<inherited PATH> \
  <resolved claude> -p "<operation prompt>" \
    --output-format stream-json --verbose --include-partial-messages \
    --append-system-prompt "<this wiki's system_prompt body>" \
    --allowedTools 'Bash(wikictl:*) Bash(find:*) Bash(cat:*) Bash(grep:*) Bash(printf:*) Read Grep Glob'
```

**Notes / carry-forward**
- **The prior log-ordering flake is FIXED** (`38aeb6f` — `log.md` now orders by
  `ts+rowid`, not the ULID `id`). The whole suite (180) is deterministic.
- **Gate is STRUCTURAL** (agent is non-deterministic): on a FRESHLY-CREATED wiki,
  drop a real source → Ingest → ≥1 new summary page + ≥1 `log.md` entry +
  `index.md` changed (all visible on the mount); a Query returns a cited answer; a
  Lint produces a report; the editor is read-only during a run and re-enabled
  after. `claude` must be on the login-shell PATH. macOS-26 TCC prompt re-fires on
  a re-signed install (Phase 0 carry-forward).
- **The verifier must ALSO confirm the streaming observability** (the whole point
  of this enhancement): during a run the operations panel shows live tool-call
  rows + assistant text streaming in (NOT a blank box until the end), and a
  backend `run.jsonl` log is written under the run's scratch dir
  (`<Caches>/WikiFS-agent/<uuid>/run.jsonl`, revealable via "Reveal Log"),
  containing the raw stream-json for after-the-fact replay.

## 2026-06-15 — LLM Wiki Phase B: `log.md` + `index.md` — DONE ✅ (gate passed)

Branch `llmwiki/phase-b-index-log` (stacked on `llmwiki/phase-a-write-path`).
Implements `plans/llm-wiki.md` Phase B: the append-only `log` table + the curated
`wiki_index` singleton, two `wikictl` subcommands to write them, and both
projected read-only at each wiki's root. All deterministic (no agent yet).
Independent live-mount gate (Bash, on a freshly-created wiki) PASSED.

**Added / changed**
- **Two stepwise migrations** slotted into the existing `bootstrapSchema()` ladder
  (`SQLiteWikiStore.swift`), continuing past the v2→3 `system_prompt` step:
  - **v3→4** — a `log` table (`id` ULID PK, `ts` REAL, `kind` TEXT, `title` TEXT,
    `note` TEXT nullable). Append-only chronological log; NOT a singleton — each
    `appendLog` INSERTs a fresh ULID-keyed row (`id` sorts == chronological).
  - **v4→5** — a `wiki_index` SINGLETON (`id INTEGER PRIMARY KEY CHECK(id=1)`,
    `body_markdown`, `updated_at`, `version`), modeled EXACTLY on `system_prompt`:
    seeded with `WikiIndex.defaultBody`, UPSERT on write, `version` bumped each
    write. Existing v1/v2/v3 DBs migrate forward with pages + files + system_prompt
    preserved (`LogIndexTests.migratesV3DatabaseToV5PreservingData` builds a v3 DB
    by hand and asserts all three ride through untouched + the index seeds).
- **Value types (`WikiFSCore`).** `LogEntry` (+ closed `LogEntry.Kind`
  `ingest|query|lint`) and `WikiIndex` (the `system_prompt`-shaped singleton +
  `defaultBody`). `LogRenderer` — pure, deterministic `log.md` rendering: one
  grep-able `## [YYYY-MM-DD] <kind> | <title>` heading per row (UTC date via a
  fixed `en_US_POSIX` formatter so `grep "^## \[" log.md | tail -5` works exactly
  as the doc shows), the optional note on the following line.
- **Store methods (`SQLiteWikiStore` + `WikiStore` protocol).** `appendLog(kind:
  title:note:)`, `getWikiIndex()`, `updateWikiIndex(body:)` on the protocol (so the
  CLI commands run against `WikiStore`, like the `page` commands);
  `listAllLogEntriesOrderedByID()` stays concrete (a read-projection helper, like
  `listAllPagesOrderedByID`).
- **⚠️ `changeToken()` extended** `…:spVersion` → `…:spVersion:logCount:idxVersion`
  (now `"pCount:pSum:fCount:fSum:spVersion:logCount:idxVersion"`). SAME reasoning
  as the `spVersion` fold: appending ONLY a log entry (logCount) or editing ONLY
  the index (idxVersion) must still advance the anchor or the projected
  `log.md`/`index.md` would never refresh. `log` uses COUNT (append-only — rows
  only grow), `wiki_index` uses the row `version` (UPSERTs). Both fall back to `0`
  on a pre-v4/v5 read connection (table absent), exactly like the `spVersion`
  helper. ALL `changeToken` test literals gained the trailing `:0:1` (fresh DB:
  no log rows, index seeded at v1).
- **`wikictl` subcommands (`WikiCtlCore` + `wikictl`).** `ArgumentParser` grew a
  top-level command switch (`page` / `log` / `index`) and two parsers; the new
  `LogIndexCommand` executes `logAppend` / `indexSet` against a `WikiStore`
  (mirrors `PageCommand`); `main.swift`'s dispatch (`execute`) routes to the right
  family and reads the deferred `--body-file` body (`-` = stdin):
  - `wikictl [--wiki <id>] log append --kind ingest|query|lint --title "…"
    [--note "…"]` — appends one dated row, echoes the new ULID. Rejects an invalid
    `--kind`.
  - `wikictl [--wiki <id>] index set --body-file <path|->` — UPSERTs the singleton
    body wholesale (version+1); `-` reads stdin.
  Both select the wiki via `--wiki`/`WIKI_DB` and post the SAME per-wiki
  `WikiChangeNotification` Darwin name as Phase A after committing (both return
  `didCommit: true`) — reusing the existing `WikiResolver` + `DarwinNotifier`
  plumbing unchanged, so the app's change bridge refreshes that wiki with no new
  wiring.
- **Projection (`Projection.swift` + `WikiFSContainerID`).** Two new root-level
  read-only files: `index.md` (the singleton body served verbatim, sized/versioned
  by the row `version` — exactly the `CLAUDE.md`/`AGENTS.md` path) and `log.md`
  (the rendered table, versioned by the change token since its bytes derive from
  many rows — like the generated index files). New `log-md`/`index-md` container
  ids; added to `node(for:)`, the root children, the working set, and
  `contents(for:)`. Both resilient to the v4/v5 tables being absent on a
  pre-migration read connection → empty/default, so the files always exist.
- **Signaling.** `log.md`/`index.md` are root children, so the app's existing
  `signalChange()` (`.rootContainer` + `.workingSet`) refreshes them — no new
  signal container needed (same as `manifest.json` / `CLAUDE.md`).
- Tests: 113 → **135** (+22). `LogIndexTests` (v3→5 migration preserving
  pages+files+system_prompt + seeding the index; `appendLog` field correctness +
  nil-note + chronological order; `LogRenderer` grep-able prefix + empty doc;
  `updateWikiIndex` UPSERT version-bump + persist-across-reopen +
  recreate-after-delete; **changeToken advances on a log-only AND an index-only
  write**). `WikiCtlLogIndexTests` (arg parsing/dispatch for both commands incl.
  bad-`--kind` + missing-required + unknown-subcommand; `LogIndexCommand`
  execution against a temp DB). Existing `changeToken`/migration literals updated.
  `make test` → **135/135**; `make` clean signed bundle (app + appex + `wikictl`).

**Smoke-tested (Bash, against the `GateAClean` wiki, non-destructive)**
- `log append --kind ingest --title … --note …` and `--kind query` (no note) both
  echoed new ULIDs and wrote correct `log` rows (kind/title/note); `index set`
  from stdin UPSERTed the `wiki_index` body to version 2. The hand-computed change
  token reflected the writes (`…:logCount=2:idxVersion=2`), proving both folds
  advance live. DB migrated to `user_version 5`.

**Verified (independent live gate, real `make clean && make install`, real-signed, Bash + minimal computer-use)**
On a **freshly-created wiki `GateBClean`** (`01KV7CWPJE…`, mount
`WikiFS-GateBClean`, made via the in-app switcher) — no `WIKIFS_REENUMERATE`
needed, the new root files materialized cleanly in seconds (confirming Phase A's
churned-domain finding). App pid **44966 unchanged through every step** (no
relaunch anywhere).
- **(1) `log append` → grep-able `log.md`:** appended `--kind ingest` (with
  `--note`) and `--kind query` (no note) → mount `log.md` refreshed in ~2 s to
  `## [2026-06-16] ingest | Article One` / `## [2026-06-16] query | How does X
  compare?`; `grep "^## \["` returned exactly the two headings; the note renders
  for the ingest entry and is absent for the no-note query entry. `--kind bogus`
  rejected (exit 2).
- **(2) `index set` → rewrites root `index.md`:** `printf … | wikictl index set
  --body-file -` bumped `wiki_index.version` 1→2; mount `index.md` refreshed in
  ~1 s and `diff` vs the set body was IDENTICAL (verbatim).
- **(3) log-only / index-only edit advances the anchor + refresh, no relaunch:**
  a fresh `log append --kind lint` advanced the token fold `logCount` 2→3
  (idxVersion held at 2) → `log.md` changed bytes in ~2 s; a fresh `index set`
  advanced `idxVersion` 2→3 (logCount held at 3) → `index.md` refreshed in ~3 s;
  pid 44966 unchanged both times. Both halves of the `…:logCount:idxVersion` fold
  drive the sync anchor independently.
- **SoT confirmed:** `PRAGMA user_version` migrated 3→5 **lazily on the first
  `wikictl` write** (a fresh wiki ships at 3); `wiki_index` at version 3, all 3
  `log` rows intact. 135/135 tests; real-signed app + appex + `wikictl`.

**Notes / carry-forward**
- A fresh wiki's DB ships at `user_version 3` and migrates to 5 **lazily on the
  first `wikictl` write** (the `bootstrapSchema()` ladder runs on store-open) —
  expected; the projected `log.md`/`index.md` exist (default/empty) before then.
- **~5 s mount-refresh window** still applies; `wikictl page get` is the instant
  SoT escape hatch.
- **macOS-26 TCC prompt** re-fires on a re-signed install and holds the app until
  "Allow" (Phase 0 carry-forward).
- Gate artifact wiki **`GateBClean`** left in place (deleting is destructive; the
  gate doesn't require teardown), as with `GateAClean`.

## 2026-06-15 — LLM Wiki Phase A: Write path + change bridge — DONE ✅ (gate passed)

Branch `llmwiki/phase-a-write-path` (stacked on `llmwiki/phase-0-many-wikis`).
Implements `plans/llm-wiki.md` Phase A: the `wikictl` write path, the shared
link-reparse refactor, and the Darwin-notification → debounced app refresh +
`signalChange()` change bridge. **All deterministic (no agent yet).** Independent
live-mount gate (Bash + one UI check) PASSED.

**Added / changed**
- **Shared upsert+reparse seam (`WikiFSCore/PageUpsert.swift`).** Lifted "create-
  or-update a page + reparse `[[links]]` + `replaceLinks`" out of
  `WikiStoreModel.save()` into `PageUpsert.upsert(in:id:title:body:)`. BOTH the
  app model (`save()` now calls it) AND `wikictl` call this one op, so the link
  graph stays consistent **identically** from both writers (the doc's "no second
  drifting implementation in the CLI"). Resolution order: explicit `--id` →
  title→id via `resolveTitleToID` → create. Returns the id + a `didCreate` flag.
  `newPage()` still uses `createPage` directly (it must always create, never
  resolve-to-existing). A unit test drives the SAME content through `PageUpsert`
  and through the model and asserts byte-identical `page_links`.
- **`wikictl` CLI — new SwiftPM targets.** Logic lives in a LIBRARY target
  `WikiCtlCore` (arg parsing, command dispatch, wiki resolution, the Darwin post)
  so it's unit-testable; the `wikictl` executable target is a thin process shell
  over it (the same library/executable split `WikiFSCore` uses). Command surface,
  each selecting the wiki via `--wiki <id-or-name>` or the `WIKI_DB` env var:
  - `page list [--json]` — id / title / mount-relative `pages/by-title/…` path per
    line, TSV or JSON (the path uses the SAME `FilenameEscaping` as the projection
    so the agent can `cat` it).
  - `page get (--title X | --id Y)` — prints the body. The **instant SoT read**
    that bypasses the ~5 s mount lag.
  - `page upsert --title X [--id Y] --body-file <path|->` — create-or-update via
    the shared `PageUpsert`; prints the resulting id. `-` reads stdin.
  - `page delete --id Y`.
  Opens the wiki's `<ulid>.sqlite` **read-write** via the literal App Group path
  the un-sandboxed app uses (`WikiResolver` → `DatabaseLocation.appGroupContainerDirectory`),
  resolved through the SAME `WikiRegistry` the app reads. WAL + `busy_timeout=5000`
  make the second writer safe. Exit codes: 0 ok / 2 usage / 1 runtime.
- **Darwin notification — wiki id in the NAME.** Darwin notifications carry no
  payload, so the wiki id can't be data. `WikiChangeNotification`
  (`WikiFSCore`, shared so the two sides can't drift) encodes it in the name:
  `org.sockpuppet.wiki.changed.<wikiID>`. `wikictl` posts THIS per-wiki name after
  every committing call (`upsert`/`delete`), never on a read, and **never signals
  the File Provider itself** — that stays the app's job (single owner of FP
  signaling). The app subscribes to exactly that name for each registered wiki, so
  the change bridge learns WHICH wiki changed with no demux table. (Rejected: one
  generic name + refresh-all-wikis — wasteful with N wikis and loses the "which
  wiki" the doc wants.)
- **Change bridge in the app (`WikiFS/WikiChangeBridge.swift`).** Observes the
  per-wiki Darwin notification for every registered wiki (re-subscribes on the
  wiki set changing via `.onChange(of: manager.wikis)`), and for the changed wiki,
  after a **per-wiki ~250 ms coalesce**, (a) rebuilds the active store's
  `summaries` if that wiki is on screen (`WikiStoreModel.reloadFromStore()`, a full
  source rebuild per §3.1) and (b) calls `FileProviderSpike.signalChange(forWikiID:)`
  so that wiki's mount refreshes (~5 s). The CF observer fires on a CFRunLoop
  callback and **hops to the main actor** before touching the coalescer / model /
  FP. The coalescing itself is the PURE `WikiFSCore/ChangeCoalescer` (injected
  scheduler + flush) so the debounce is unit-tested with a fake clock — one ingest
  burst of ~15 `wikictl` calls collapses to one rebuild + one FP signal per wiki.
- **`FileProviderSpike.signalChange(forWikiID:)`** — a per-wiki variant (the old
  `signalChange()` now delegates to it for the active wiki) so the bridge can
  refresh a wiki that is NOT the one on screen.
- **Packaging.** `Package.swift` gains `WikiCtlCore` + `wikictl`. `build.sh`
  builds `wikictl`, copies it to `build/wikictl` for the gate to invoke directly,
  AND embeds + codesigns it at `WikiFS.app/Contents/Helpers/wikictl` for Phase C's
  app-spawn. Read-only FP invariant intact — `wikictl` writes ONLY SQLite.
- Tests: 86 → **113** (+27). `PageUpsertTests` (create/update/explicit-id/
  duplicate-title resolution, link reparse, replace-not-append, CLI-vs-model link
  parity), `WikiCtlCommandTests` (arg parsing for every command incl. env-vs-flag
  precedence + usage errors; `PageCommand` dispatch against a temp DB; Darwin name
  carries the id), `ChangeCoalescerTests` (burst→one flush, per-wiki independence,
  re-arm after flush). `make test` → **113/113**; `make` clean signed bundle
  (app + appex + wikictl all real-signed).

**Smoke-tested (Bash, against the real registry's wiki, non-destructive)**
- `page list` (TSV + `--json`), `page get --title/--id`, `WIKI_DB` env and
  display-name selectors all resolve and return live SQLite bytes. An `upsert`
  with a `[[Home]]` body wrote a real `page_links` row (shared reparse seam works
  from the CLI), `page get` read it back instantly, and `delete` removed it (list
  returned to 2). Error paths return the right exit codes (unknown wiki → 1, bad
  args → 2).

**Verified (independent live gate, real `make clean && make install`, real-signed, Bash + one computer-use UI check)**
All five Phase A criteria passed; the decisive end-to-end run was on a
**freshly-created wiki `GateAClean`** (`01KV7BHTQM…`, mount `WikiFS-GateAClean`),
with items 1–2 also reconfirmed on the live `WikiFS` wiki.
- **(1) CLI write:** `printf 'Gate A body linking [[Home]]\n' | wikictl --wiki
  <id> page upsert --title "GateA-CLEAN9" --body-file -` → printed new id
  `01KV7BJWS8…`; SQLite row confirmed directly (title + body).
- **(2) Sidebar updates live (no relaunch):** the new page appeared in the running
  app's sidebar above Home, app pid unchanged — proving the per-wiki Darwin
  notification → debounced `WikiChangeBridge` → `reloadFromStore()` path
  (reconfirmed with two successive upserts on the WikiFS wiki).
- **(3) Mount reflects it (~1 s):** `pages/by-id/01KV7BJW….md` +
  `pages/by-title/GateA-CLEAN9--01KV7BJW.md` both served the exact body.
- **(4) Read-only intact:** overwrite/append of projected files AND of
  `indexes/links.jsonl` → "operation not permitted"; SQLite untouched.
- **(5) Link graph:** `page_links` row `01KV7BJW… → <Home>` and mount
  `indexes/links.jsonl` `{"from":"01KV7BJW…","to":"<Home>","link_text":"Home"}` —
  the CLI-written `[[Home]]` resolved through the shared `PageUpsert` seam end to
  end. Command surface (`get`/`list` TSV+JSON/`WIKI_DB` env/`delete`, exit codes
  1 unknown-wiki / 2 usage) all confirmed. 113/113 tests; real-signed app + appex
  + `wikictl`.

**Notes / carry-forward**
- **Heavily-churned domain replica can wedge (operational, NOT a code defect →
  use a fresh wiki for live gates).** The long-lived `WikiFS` domain's mount would
  not reflect CLI writes during the gate: `fileproviderctl dump` showed the
  daemon's replica holding a *phantom* page from an earlier session, `-1005`
  fetch errors, a missing `indexes/`, and "Stale NFS file handle" on
  previously-valid files — the extension wasn't even invoked. The DB itself is
  intact (a `wal_checkpoint(TRUNCATE)` confirmed all pages durable + readable by a
  fresh reader); this is a corrupted **daemon-side materialized replica**
  accumulated over many prior gate runs on that one domain. It did NOT recover via
  the app's `WIKIFS_REENUMERATE` remove+re-add, a `fileproviderd` bounce, or ~90 s
  of reconciliation — a true reset needs a domain teardown (only the signed app's
  lifecycle can do it; an ad-hoc CLI gets FP -2001/-2014). A **freshly-created**
  domain (`GateAClean`) materialized fully and correctly in ~1 s. **Phase B/C live
  gates should run against a freshly-created wiki, not the churned `WikiFS` one.**
  Logged to `ISSUES.md`.
- **~5 s mount-refresh window** (replicated-FP read-after-write) still applies; the
  CLI's `page get` is the instant-SoT escape hatch.
- **macOS-26 TCC prompt** ("access data from other apps") re-fires on a re-signed
  install and holds the app until "Allow" (Phase 0 carry-forward).
- A gate artifact wiki **`GateAClean`** was left in place (deleting is destructive;
  the gate doesn't require teardown); its only content is a seeded empty `Home`.

## 2026-06-15 — LLM Wiki Phase 0: Many wikis (foundation) — DONE ✅ (gate passed)

Branch `llmwiki/phase-0-many-wikis` (stacked on the post-v0 line). Implements
`plans/llm-wiki.md` Phase 0: one SQLite DB + one File Provider domain **per
wiki**, a registry, an in-app switcher, and migration of the single v0 wiki as
wiki #1. Independent live-mount gate (computer-use + Bash) PASSED after one
fix round (the migration duplication loop below).

**Added / changed**
- **Registry (`WikiFSCore`).** New `WikiDescriptor` (id ULID, displayName,
  createdAt, lastUsedAt) — `dbFileName` (`<ulid>.sqlite`) and `domainIdentifier`
  (the bare ULID) BOTH derive from the ULID, **never the display name**, so a
  rename can't orphan the DB or the mount (the doc's explicit open-risk). New
  `WikiRegistry` (Codable) persisted as `wikis.json` in the App Group container:
  MRU-ordered list, add/rename/touch/remove, atomic save, corrupt/missing →
  empty (no launch crash).
- **`DatabaseLocation` generalized.** Split into `appGroupContainerDirectory()`
  (literal home path, app) + `extensionContainerDirectory()` (security API,
  extension), each with a per-wiki `…URL(forWikiID:)` → `<ulid>.sqlite`. The
  literal-vs-`containerURL` app/extension split is preserved; the legacy
  `WikiFS.sqlite` constant + Application-Support migration are kept for the v0
  adoption.
- **Extension maps domain → DB (the crux).** `Projection` went from a static
  `enum` to a `struct Projection { let wikiID }`; `init(domain:)` builds
  `Projection(wikiID: domain.identifier.rawValue)` and threads it through
  `WikiFSEnumerator`. `openReadStore()` resolves
  `extensionContainerURL(forWikiID:)` — same projection logic, different DB per
  domain, **no registry read** in the extension. The token-keyed index cache is
  now keyed by `(wikiID, identifier)` so two domains in one process can't collide.
- **`WikiManager` (`WikiFSCore`, `@MainActor @Observable`).** Owns the registry,
  the active `WikiStoreModel`, and create/select/rename/delete. File-Provider
  side effects (`registerDomain`/`removeDomain`) + `onActiveStoreDidChange` are
  injected CLOSURES, so the whole switcher logic is unit-testable without
  importing `FileProvider` (same pattern as `onPageDidChange`). Resolves per-wiki
  DB paths under an injected `containerDirectory` (hermetic tests).
- **One domain per wiki.** `FileProviderSpike` rewritten from a single static
  domain to per-wiki `registerDomain`/`removeDomain`/`activate`/`signalChange`,
  each keyed by the wiki ULID; mounts at `~/Library/CloudStorage/WikiFS-<name>`.
  The v0 `WIKIFS_REENUMERATE` one-shot hatch is preserved, scoped per domain.
  Obsolete single-domain `WelcomeView` spike removed.
- **Switcher UI.** `WikiSwitcher` — a sidebar-header `Menu` (`.headline`, native
  "account header" idiom) listing wikis to select, with New Wiki…/Rename/Delete;
  a `NewWikiSheet` for naming; a destructive-confirm delete alert. `RootView`
  hosts the active wiki's `ContentView` keyed by `.id(activeWikiID)` so no
  draft/selection leaks across a switch. `WikiFSApp` builds the manager, wires
  the FP closures, bootstraps, and registers all domains on launch.
- **v0 migration.** On first launch `WikiManager.bootstrap()` renames the legacy
  `WikiFS.sqlite` (+ `-wal`/`-shm`) to `<ulid>.sqlite` and registers it as wiki
  #1 named "WikiFS" — all pages/files/system_prompt ride along untouched (same
  file). **Strictly one-time, idempotent across any number of launches:** the
  whole legacy-import chain is gated on an EMPTY registry. The first gate run
  found this was broken — two un-coordinated migration layers (`WikiManager`
  renames the container file away; `DatabaseLocation.migrateFromApplicationSupportIfNeeded`
  re-copies it from Application Support) formed a duplication loop, spawning a new
  "WikiFS" wiki on every launch. Fixed by gating BOTH layers on the registry
  being empty: `WikiFSApp.init` only runs the Application-Support copy when the
  registry is empty, and `bootstrap()` only calls `migrateLegacyWikiIfNeeded`
  when the registry is empty. Net invariant: a v0 user's first launch → exactly
  one wiki #1; every subsequent launch adds zero wikis and keeps it active; a
  non-empty registry + a stray legacy file never creates a new wiki.
- Tests: 69 → **86** (+17). New `WikiRegistryTests` (round-trip, MRU,
  rename-keeps-identity, ULID-derived paths) + `WikiManagerTests` (fresh-seed,
  per-wiki DB isolation, distinct files on disk, delete removes DB, MRU
  launch-pick, rename doesn't move the file, v0 migration preserves content +
  doesn't re-run, **legacy file reappearing after first launch doesn't
  duplicate**, **stray legacy file + non-empty registry creates no wiki**).
  `make test` → **86/86**; `make check` clean; real `make` app-bundle build +
  codesign (app + appex) clean.

**Verified (independent live gate, real `make clean && make install`, real-signed, computer-use + Bash)**
- **Create + isolation + independent DBs:** created a second wiki **"GateBeta"**
  in-app via the sidebar switcher → it mounted at its own
  `~/Library/CloudStorage/WikiFS-GateBeta` with its own `<ulid>.sqlite` (3
  distinct ULID DB files in the container at peak). Added a sentinel page
  `BetaSentinelZ9` in GateBeta → it appeared ONLY in GateBeta's DB (`count(*)=1`;
  `0` in both other DBs) and ONLY in GateBeta's mount; the v0 wiki's unique
  `Target` page never appeared in GateBeta's mount, and `BetaSentinelZ9` never
  appeared in the v0 wiki's mount (`WikiFS-WikiFS`). Isolation proven both ways.
- **Delete removes domain + DB:** deleted GateBeta via the switcher (destructive
  confirm dialog) → its registry entry, `<ulid>.sqlite` + `-wal`/`-shm` sidecars,
  Finder mount, AND File Provider domain (`fileproviderctl`) were all gone.
- **v0 preserved + migration idempotent (the fix):** from a v0 starting point
  (Application Support `WikiFS.sqlite` present, empty registry), the FIRST launch
  migrated to **exactly one** wiki #1 "WikiFS" carrying the full v0 content —
  original `Home` (`01KV6EAH…`) + `Target` (`01KV6KS0…`) + the ingested
  `[MS-NRPC] (1).pdf` — served read-only on the mount. Repeated relaunches **with
  the Application Support source still present** kept the registry at exactly one
  wiki (same id) and one ULID DB — zero duplicates (the pre-fix code spawned a new
  "WikiFS" every launch). Read-only still enforced (`echo >` rejected with
  "operation not permitted"; SQLite untouched).

**Notes / carry-forward**
- **macOS-26 TCC gate re-fires on a re-signed install:** "WikiFS would like to
  access data from other apps" appears (UserNotificationCenter) in `App.init()`
  and holds the app hostage until "Allow" — migration/bootstrap don't run until
  it's dismissed. Consent persists across launches within an install. Already
  documented in `PROGRESS.md`/`ISSUES.md`; surfaced again here driving the gate.
- **Mount labels:** each wiki mounts at `~/Library/CloudStorage/WikiFS-<display>`;
  two wikis with the same display name collide on the Finder label (not the DB —
  identity is the ULID). With the migration fixed there are no spurious
  same-named duplicates; deliberate same-name wikis remain out of scope to dedupe.
- **Stale domains** from prior manual file-archiving aren't reaped by the app
  (it registers add-if-absent; `NSFileProviderManager.removeAllDomains` needs the
  provider-app context, so an ad-hoc CLI can't reap them). Cosmetic only.

A user-editable singleton "system prompt" document — the instructions the
managing agent reads each run — projected **read-only at the wiki root under TWO
names with identical bytes: `CLAUDE.md` and `AGENTS.md`** (the filenames CLI
agents look for). Edited in-app like a page; read-only on the mount like
everything else. Branch work stacked on the v0 + Phase-5 line.

**User-chosen scope (locked):** in-app editing via a **pinned sidebar item**
(above Pages) that opens the document in the main editor pane — i.e. a
first-class document, not a sheet/settings window.

**Added / changed**
- **New singleton `system_prompt` table** (`id INTEGER PRIMARY KEY CHECK(id=1)`,
  `body_markdown`, `updated_at`, `version`). `bootstrapSchema()` gains a stepwise
  **v2→3 migration** that creates AND **seeds** the row with
  `SystemPrompt.defaultBody`; existing v1/v2 DBs migrate forward with pages +
  ingested files preserved (test-proven). `SystemPrompt` value type +
  `defaultBody` live in `WikiFSCore` (shared by the migration seed and the
  projection fallback).
- **Store API** (`SQLiteWikiStore` + `WikiStore` protocol): `getSystemPrompt()`
  (returns the seeded default if absent) and `updateSystemPrompt(body:)`
  (**UPSERT**, `version = version + 1`).
- **⚠️ `changeToken()` now folds in the system-prompt version** →
  `"pCount:pSum:fCount:fSum:spVersion"`. Editing ONLY the prompt (no page/file
  change) must still advance the sync anchor or the projected files would never
  refresh. Resilient to the table being absent on a pre-v3 read connection
  (→ `0`). All `changeToken` test literals gained the trailing `:1`.
- **Projection**: `CLAUDE.md` + `AGENTS.md` as root-level files (new
  `claude-md`/`agents-md` identities), both serving the SAME live body (read like
  a page in both `node` and `contents`); item version = the row `version`. Added
  to root children, the working set, and `contents(for:)`; README updated.
  `systemPromptDocument()` falls back to `SystemPrompt.defaultBody` so the two
  files ALWAYS exist even pre-migration. **No new signal container needed** — both
  are root children, so the existing `.rootContainer` + `.workingSet` signals
  refresh them (same path as `manifest.json`).
- **Model/UI**: sidebar selection generalized from `PageID?` to a new
  `WikiSelection` enum (`.page` / `.systemPrompt`); the autosave tests reference
  selection opaquely so the load-bearing §3.5 logic is untouched. New
  `draftSystemPrompt` track with its own debounce + `flushPendingSystemPromptSave`
  (combined `flushPendingSaves()` used on switch + backgrounding). `SidebarView`
  pins a **"System Prompt"** item above Pages; `ContentView` switches the detail
  pane; new `SystemPromptDetailView` (header explaining the projection + editor +
  live preview, semantic Dynamic-Type styles).
- Tests: 63 → **69** (new `SystemPromptTests`: seed default, update bumps
  version + persists across reopen, repeated edits, token advances on a
  prompt-only edit, UPSERT recreates a deleted row, v2→3 migration preserving
  pages + files). Updated `SQLiteWikiStoreTests` (user_version 3, `system_prompt`
  table, `:1` token suffix) and the `IngestedFilesTests` migration assertion (→3).

**Verified (live signed mount, real `make install`, computer-use + Bash)**
- **Byte-identity:** `CLAUDE.md` and `AGENTS.md` byte-identical to each other AND
  to the seeded DB body (`writefile` raw compare; sha `17e74587…`, 770 bytes —
  762 *chars*, the gap is UTF-8 em-dashes). 69/69 tests; real Apple Development
  signing chain.
- **Refresh on edit (no relaunch):** edited the prompt **in-app** (appended a
  sentinel to the heading via the pinned "System Prompt" item), switched pages to
  flush → `system_prompt.version` bumped (1→3 across autosave+flush), sentinel
  persisted to SQLite. Within ~6 s the mount's `CLAUDE.md` AND `AGENTS.md` showed
  the new bytes (sha `f7021881…`), **app pid unchanged** (no relaunch). Reverted
  the sentinel in-app → both files returned to the clean default (sha
  `17e74587…`). The change-token's `spVersion` fold drives this end to end.
- **Read-only enforced:** append/overwrite of both files rejected (`operation not
  permitted`); SQLite row untouched; projected bytes still matched the DB (no
  client-side staging leak).
- **One-shot re-enumerate needed** on the already-materialized (phase-5) domain to
  surface the two new root files — launched once with `WIKIFS_REENUMERATE=1`, as
  predicted; fresh installs wouldn't need it.

**Notes / known gaps**
- The ~5 s read-after-write window (replicated-File-Provider replica invalidation,
  NOT a stale SQLite read) is documented in `ISSUES.md` — two items signaled
  together (`CLAUDE.md` + `AGENTS.md`) can also refresh a few seconds apart.
- Same `files/`-style caveat: on an already-materialized (upgraded) domain the
  two new root files may need the one-shot `WIKIFS_REENUMERATE=1` launch to
  appear; fresh installs are fine.
- Pre-existing flaky test `resolvesDuplicateTitleToLowestULID` (same-millisecond
  ULID ordering) is unrelated to this change — flagged separately.

## 2026-06-15 — Post-v0 feature: File ingestion (drag-to-ingest) — DONE ✅

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

## 2026-06-15 — 🎉 v0 DONE ✅ — all four phases gate-passed

WikiFS v0 is complete: a native macOS SwiftUI wiki, SQLite-backed, projected
read-only onto the filesystem via a File Provider extension, kept fresh on edit,
and traversable by an agent launched with `WIKI_ROOT`. Built across four stacked,
unmerged branches off a pristine `main` (review/merge locally):

- `phase-1-local-wiki` — **Phase 1 (M0+M1)**: SQLite wiki + editor. Gate: create
  Home, type Markdown, live preview, quit/relaunch persistence, matching SQLite
  row. (computer-use)
- `phase-2-file-provider` — **Phase 2 (M2+M3)**: read-only SQLite projection.
  Gate: `find .` shows the tree, `cat pages/by-title/Home--*.md` returns live
  SQLite bytes from both by-title and by-id, read-only enforced. (live mount)
- `phase-3-verify-fresh` — **Phase 3 (M4+M5)**: Copy Unix Path + change-signaling.
  Gate: copy path → cat → edit in app (token `1:5→1:6`) → re-cat shows new bytes,
  NO relaunch. Closes INITIAL §12. (computer-use)
- `phase-4-agent-wiki` — **Phase 4 (M6 + generated views)**: indexes, wiki-links,
  agent launcher. Gate below.

**Verification method note:** Phases 1–3 and most of Phase 4 were driven via
computer-use/Bash by dedicated verifier subagents. The Phase-4 index/link/
read-only/freshness checks were validated directly via Bash (no screen
disruption); the in-app agent-launcher output panel was confirmed by the user
(GUI automation was repeatedly stealing focus, so we stopped fighting it).

**What is stubbed / deferred (known v0 gaps):**
- `enumerateChanges` deletion semantics (`didDeleteItems`) not implemented.
- A brand-new top-level projection folder (e.g. `indexes/`) needs a one-shot
  domain re-enumeration on an already-materialized (upgraded) domain — handled
  by a gated `WIKIFS_REENUMERATE=1` launch hatch; fresh installs don't need it.
- Rename does not re-resolve the whole wiki-link graph (stale cross-page links
  self-heal on the linking page's next save).
- Read-after-write is eventually-consistent (~5 s) — a `cat` within ~1 s of a
  save can briefly show stale bytes before refreshing (no relaunch needed).
- macOS-26 TCC "access data from other apps" prompt fires in `App.init()` and
  re-prompts per re-signed install (cleanup idea: move the DB open off init).
- Optional post-v0 views skipped: by-created/updated-date, tags/backlinks/
  attachments JSONL.

## 2026-06-15 — Phase 4 (M6 + generated views): Agent-facing wiki — DONE ✅ (gate passed)

Branch `phase-4-agent-wiki` (stacked on `phase-3-verify-fresh`, unmerged).
Layers the agent surface on top of the v0 loop.

**Added / changed**
- **Wiki-links (INITIAL §4).** `WikiFSCore/WikiLinkParser.swift` (pure, tested):
  `[[Title]]` + `[[Target|alias]]`, whitespace-collapse, dedupe, skip empty.
  `SQLiteWikiStore` gains `resolveTitleToID` (lowest ULID on duplicate titles),
  `replaceLinks` (one txn: delete-then-`INSERT OR IGNORE` the resolved subset;
  **unresolved links omitted** — `page_links.to_page_id` is NOT NULL/FK; self-
  links allowed), `listAllLinks`. `WikiStoreModel.save()`/`newPage()` re-parse +
  rewrite that page's links. **`deletePage` now clears `page_links` rows
  referencing the page (source OR target) first** — required under
  `foreign_keys=ON` or deleting a linked page throws (orchestrator-caught;
  regression-tested).
- **Generated indexes (INITIAL §5).** `WikiFSCore/IndexGenerators.swift` (pure,
  deterministic, tested): `manifest.json` (`name/version/generated_at/
  page_count/paths`), `indexes/pages.jsonl` (one line/page, by id), `indexes/
  links.jsonl` (one line/link from `page_links`). `Projection` adds the four
  identities + a **token-keyed (`count:sum(version)`) byte cache** so a node's
  `documentSize` and its `contents` bytes always come from the same snapshot
  (a mismatch truncates `cat`). `signalChange()` now also signals `.rootContainer`
  + `indexes` so edits invalidate the generated files.
- **Agent launcher (INITIAL §8 / M6).** `WikiFS/AgentLauncher.swift`
  (`@MainActor @Observable`) spawns `/bin/zsh -lc <command>` with `WIKI_ROOT` =
  the live mount (resolved via `getUserVisibleURL` at click time, never
  hardcoded), streaming stdout+stderr into the UI via pipe `readabilityHandler`s
  (non-blocking; `terminationHandler` for exit status). `AgentLauncherView.swift`
  is the sheet (editable command, Run/Stop, scrolling output). Works because the
  app is **un-sandboxed** (the Phase-2 Option-B call) — a sandboxed app couldn't
  `Process`-spawn. Before spawning, `await signalChange()` so the agent sees
  current content (no fixed-sleep correctness dependency).
- Tests: 24 → **47** (WikiLinkParser, replaceLinks/resolve/listAllLinks,
  deletePage-with-links FK regression, index generators).

**Verified (Bash by the orchestrator + user-confirmed GUI)**
- `manifest.json` valid, `page_count: 2` == `select count(*) from pages`.
- `indexes/pages.jsonl`: 2 valid JSON lines == 2 pages. `indexes/links.jsonl`:
  the **cross-page link** `Home→Target` (`{"from","to","link_text":"Target"}`),
  valid, == the one `page_links` row — `[[Target]]` in Home's body parsed through
  to the index end to end.
- Read-only: `manifest.json` overwrite → "operation not permitted"; SQLite
  untouched. Phase-3 freshness intact (Home body served fresh, no relaunch).
- 47/47 tests; real-signed `make install`.
- **Agent launcher: user confirmed** the in-app output panel populated with the
  `find` tree + manifest + both JSONL files when clicking Run Agent (WIKI_ROOT =
  the live `~/Library/CloudStorage/WikiFS-WikiFS` mount).

## 2026-06-15 — Phase 3 (M4+M5): Verify & stay fresh — DONE ✅ (v0 ship-gate loop passed)

**This closes the v0 definition of done (INITIAL §12):** copy a Unix path → read
it in Terminal → edit in the app → re-read sees the update, no relaunch. Branch
`phase-3-verify-fresh` (stacked on `phase-2-file-provider`, unmerged). Phase 4
(agent-facing wiki) is the extension on top; the core v0 loop is now proven.

**Added / changed**
- **M4 — path button.** `Sources/WikiFS/VerificationPopover.swift` (NEW) +
  `ContentView.swift`: a `Copy Unix Path` toolbar button (⌘⇧U) opening a popover
  that resolves the mount URL **at click time** via
  `NSFileProviderManager.getUserVisibleURL(for: .rootContainer)` (NEVER
  hardcoded), copies `url.path` to the pasteboard, shows it (monospaced,
  selectable), and offers a copyable `cd … && find . && cat pages/by-title/Home--*.md`
  block + Reveal in Finder. (Open Terminal Here skipped — Process hop is Phase 4.)
- **M5 — change-signaling (defeats read-after-write staleness).**
  - `WikiFSCore/SQLiteWikiStore.swift` — `changeToken()` = `"count:sum(version)"`.
    **NOT `MAX(version)`:** `version` is per-page, so `MAX` wouldn't advance when
    a non-max page is edited (would stay stale); `count:sum` advances on every
    create/update/delete. Locked by `changeTokenAdvancesOnEveryMutation`.
  - `WikiFSFileProvider/WikiFSEnumerator.swift` — `currentSyncAnchor` returns the
    live token; `enumerateChanges` re-emits page items (carrying higher
    `contentVersion`) when the token advanced → daemon invalidates the
    materialized copy → next read re-fetches from SQLite. Legacy/unparseable
    anchors (the Phase-2 `"v2-sqlite"`) treated as expired → clean full
    re-enumerate.
  - `WikiFSCore/WikiStoreModel.swift` — `@ObservationIgnored onPageDidChange`
    hook fired on save/new/rename/delete success (NO FileProvider import in core).
  - `WikiFS/FileProviderSpike.swift` — `signalChange()` signals **three**
    containers: `pages-by-title`, `pages-by-id`, and `.workingSet` (signaling root
    alone wouldn't refresh the page lists). `registerIfNeeded()` rewritten
    **add-if-absent** — the Phase-2 `remove(.removeAll)` relaunch hack is GONE.
  - `WikiFSCore/WikiFSContainerID.swift` (NEW) — shared plain-`String` container-id
    constants used by BOTH the extension and the app, so the signaled ids can't
    drift from the projection's ids.
  - `WikiFSApp.swift` — wires `store.onPageDidChange = { fileProvider.signalChange() }`.
- Tests: 23 → **24** (+`changeTokenAdvancesOnEveryMutation`).

**Verified (independent computer-use gate, fresh `make clean && make install`, real-signed)**
- Copy Unix Path → clipboard held `/Users/tqbf/Library/CloudStorage/WikiFS-WikiFS`
  (overwrote a pre-seeded sentinel → the app wrote it); path matches the live
  mount `fileproviderctl dump` reports.
- `cat` original Home (`VERIFY-7Q4Z`) → edit through the app to `FRESH-D7F04E00`
  → change token advanced **`1:5 → 1:6`**, row now `version 6` (proves the edit
  went through the app's real save pipeline, not a DB poke) → re-`cat` the SAME
  files (by-title AND by-id) showed the NEW bytes, **app never relaunched** (pid
  stayed up). Read-only not regressed (writes rejected / staged-then-reverted;
  SQLite untouched). 24/24 tests; real Apple Development signing chain.

**Caveat (carry into Phase 4)**
- **Refresh is eventually-consistent (~5 s):** `signalEnumerator` →
  `enumerateChanges` → re-fetch is async, so a `cat` within ~1 s of saving can
  briefly show stale bytes before refreshing on its own (no relaunch needed). A
  tightly-polling agent (Phase 4) may want a short settle or an explicit sync
  step before reading just-written content.

## 2026-06-15 — Phase 2 (M2+M3): File Provider projection from SQLite — DONE ✅ (gate passed)

The File Provider extension now serves a **read-only filesystem projection of the
SQLite wiki**, shared with the app via the App Group container. Branch
`phase-2-file-provider` (stacked on `phase-1-local-wiki`, unmerged). A swap of
the spike's static `Catalog` for a live SQLite projection — the appex plumbing,
entry-point flag, inside-out signing, and domain registration all carried over.

**Added / changed**
- `Sources/WikiFSFileProvider/Projection.swift` (NEW; `Catalog.swift` deleted) —
  identity↔row mapping, static `README.md`, filename escaping, and
  `node(for:)`/`children(of:)`/`contents(for:)`, each opening a **short-lived
  read connection** to the App Group DB via `extensionContainerURL()`.
  Virtual ids carry the **full ULID, never the filename** (paths are
  presentation — INITIAL §6).
- `WikiFSCore/SQLiteWikiStore.swift` — `init(readOnlyURL:)` opens a read-WRITE
  handle then `PRAGMA query_only=ON` (NOT `SQLITE_OPEN_READONLY`): robustly
  attaches the WAL `-shm` even when no writer is running (matters for Phase-4
  agents reading with the app closed) while still rejecting writes.
- `WikiFSCore/DatabaseLocation.swift` — `appGroupContainerURL()` (literal path,
  used by the un-sandboxed app, no entitlement needed), `extensionContainerURL()`
  (`containerURL(forSecurityApplicationGroupIdentifier:)`, sandboxed extension;
  same inode), `migrateFromApplicationSupportIfNeeded()` (checkpoint-TRUNCATE +
  copy the single `.sqlite`).
- `WikiFSFileProvider/WikiFSItem.swift` — real `documentSize` (=`utf8.count`,
  never nil → no truncated `cat`), `contentType`, creation/mod dates, and
  content/metadata `itemVersion` from the row. Read-only capabilities.
- `WikiFSFileProvider/WikiFSEnumerator.swift` — queries `Projection`,
  offset-paginated (256/page), sync anchor bumped to `"v2-sqlite"` so any cached
  spike enumeration expires.
- `WikiFS/WikiFSApp.swift` + `FileProviderSpike.swift` — open the App Group DB
  (after migration); `registerIfNeeded()` does `remove(_, mode: .removeAll)` then
  `add` on launch so the daemon re-enumerates from the SQLite extension.
- `Package.swift` — extension target depends on `WikiFSCore`; `-e
  _NSExtensionMain` flag + `FileProvider` framework preserved. `build.sh`
  unchanged.
- Tests: +13 (FilenameEscaping, ReadOnlyStore) → **23 total, all pass**.

**Decision — Option B: app stays UN-sandboxed**
Both processes share the literal `~/Library/Group Containers/group.org.sockpuppet.wiki/WikiFS.sqlite`
(app writes the literal path; sandboxed extension resolves the same inode via
`containerURL`). Rejected sandboxing the app (Option A) because it would (1)
redirect `Application Support` and orphan the Phase-1 DB, and (2) front-load the
Phase-4 `Process`/agent-spawn restriction (`signing.md`) for zero Phase-2
benefit. The container dir is user-owned and writable by a non-sandboxed
process. Phase-1's `Home` row **migrated** intact (same ULID
`01KV6EAH410NWC9K9ZM44DNMXT`).

**Verified (independent gate, fresh `make clean && make install`, real-signed)**
- `find .` → `README.md` + `pages/by-id/<ULID>.md` + `pages/by-title/Home--<id8>.md`
  (the SQLite ULID, not the static spike tree).
- `cat` of by-title AND by-id → byte-identical Home body (`VERIFY-7Q4Z` sentinel,
  62 bytes, `shasum b6ef887f…`), exactly matching the SQLite row.
- Read-only: `createItem` → FP -2010; shell writes stage client-side then revert;
  SQLite source of truth never altered. Extension `+`-enabled, fresh appex
  (Timestamp 20:44:24) serving.

**Notes / caveats (carry into Phase 3)**
- **macOS 26 TCC gate:** first App Group access raises *"WikiFS would like to
  access data from other apps"* (Allow/Don't-Allow, NOT Touch ID). It fires
  synchronously in SwiftUI `App.init()`, so the window is hostage to it, and a
  re-signed `make install` re-prompts. Consent persisted across the gate launch.
  *Cleanup idea:* move the DB open off `App.init()` so the window renders while
  the prompt is pending.
- **Read-after-write staleness on EDITS is still present — that's Phase 3's job.**
  The blunt `remove(.removeAll)` refresh on launch is replaced in Phase 3 by
  per-item version bumps + `signalEnumerator`.
- Read-only root: a shell `echo > f` stages then reverts (File Provider client
  framework behavior); never reaches SQLite. Optional polish: disallow
  adding-sub-items on the root capabilities for up-front shell rejection.
- All 5 File Provider gotchas intact (entry-point flag, entitlements⊆profile,
  user-enabled, /Applications via `make install`, real codesign).
- **Operational:** the Mac went to the **lock screen** during the Phase-2 run;
  the gate's load-bearing evidence was read directly from the live mount
  (identical regardless of GUI lock), but the GUI-driven Phase-3 gate (edit in
  app → re-read in Terminal) needs the screen unlocked + kept awake.

## 2026-06-15 — Phase 1 (M0+M1): Local SQLite wiki — DONE ✅ (gate passed)

A usable standalone Markdown wiki, persisted in SQLite, verified on the running
app (not just a green build). Branch `phase-1-local-wiki` (stacked off `main`,
unmerged — review locally; the pipeline keeps `main` pristine and stacks each
phase branch on the prior).

**Added**
- `Sources/WikiFSCore/` — new **library** target (so the store is unit-testable
  now and the read surface is reusable by the Phase-2 extension):
  - `SQLiteWikiStore.swift` — hand-wrapped system `SQLite3` (no third-party
    dep). `READWRITE|CREATE|FULLMUTEX`; pragmas `journal_mode=WAL` (return row
    asserted == `wal`) / `foreign_keys=ON` / `busy_timeout=5000`;
    `user_version`-guarded idempotent bootstrap of `pages`+`attachments`+
    `page_links` + unique slug index; statement cache; **`SQLITE_TRANSIENT`**
    text binding (not STATIC); slug collision suffix `-<first6 of ULID>`.
  - `ULID.swift` (48-bit ms ‖ 80 random bits, Crockford base32 — lexical sort
    == creation order, for cheap Phase-4 by-date views), `PageID`, `WikiPage`,
    `WikiPageSummary`, `WikiStore`(+`WikiStoreError`), `DatabaseLocation`,
    `WikiStoreModel`.
  - `WikiStoreModel.swift` — `@MainActor @Observable`. `summaries` always
    rebuilt from `store.listPages()` (never patched — SWIFTUI-RULES §3.1); live
    `draftTitle`/`draftBody` buffers (drafts live in the model so flush can read
    them — §3.5); 500 ms debounced autosave; `save()` reads live values at fire
    time and writes to the *loaded* page (correct even after selection advances);
    `flushPendingSave()` on page-switch and on app backgrounding.
- `Sources/WikiFS/` UI: `SidebarView` (List, +New, rename, delete via
  contextMenu **and** swipeActions), `PageDetailView` (title + `TextEditor` +
  live preview), `MarkdownPreview` (`AttributedString(markdown:)`, inline-only
  per INITIAL §4), `PageEditorMetrics`; `ContentView` rewired to
  `NavigationSplitView` + `ContentUnavailableView` empty state; `WikiFSApp`
  flushes autosave on `scenePhase != .active`. Spike files kept (Phase-2 ref),
  unhosted.
- `Tests/WikiFSTests/` — 10 tests incl. the §3.5/§9.4 stale-snapshot autosave
  regression and persistence-across-reopen.

**Decisions**
- **DB at `~/Library/Application Support/WikiFS/WikiFS.sqlite` for Phase 1**
  (option c), path injected via `DatabaseLocation`. The App Group container API
  (`containerURL(forSecurityApplicationGroupIdentifier:)`) returns `nil`
  without the sandbox + app-groups entitlement, and enabling the sandbox now
  would front-load the Phase-4 `Process`/agent-spawn restriction for zero
  Phase-1 benefit. **Phase 2 must repoint to the App Group container + run a
  one-time `migrate(from:to:)`** (hook noted in `DatabaseLocation.swift`). No
  entitlement/sandbox change this phase.
- Split `WikiFSCore` library (vs. `@testable import` of an executable) — clean
  testability + a shared store surface for the Phase-2 reader.
- Hand-wrapped SQLite3, no GRDB (dependency-free default honored).

**Verified (independent computer-use gate, fresh `make clean && make`)**
- Live preview: unique sentinel `VERIFY-7Q4Z` typed → preview rendered bold/
  italic live (screenshot read back, not just asserted).
- Persistence: clean-DB start → create `Home` → quit → relaunch → `Home` + body
  reload from disk. Running binary confirmed to be the fresh `build/` copy
  (`lsof`), alive 4 s past launch (no constraint crash).
- Data layer: `sqlite3 … "select … from pages"` → exactly one `Home` row with
  the exact sentinel body; DB at the literal Application Support path (no
  sandbox redirect). `make test` → 10/10 pass.

**Notes / caveats**
- Synthetic keystrokes don't reach SwiftUI `TextEditor`; the gate drove text via
  the AX `value` API (fires `.onChange` → autosave). Real user typing is
  unaffected. A bug found *by* the live gate — sidebar `List(selection:)` wrote
  the property directly, bypassing the load path — was fixed (`.onChange(of:
  selection)` → `handleSelectionChange`) with a regression test.
- Context-menu Rename / swipe-Delete are implemented + unit-tested but not
  visually gate-confirmed (outside the acceptance bar).
- DB state for Phase 2: fresh DB holds one clean `Home`; the pre-gate DB is
  preserved as `WikiFS.sqlite.verifier-bak` in the same dir.

## 2026-06-15 — File Provider spike PROVEN end to end ✅

De-risked the riskiest part of the project before Phase 1. A real
`NSFileProviderReplicatedExtension` (SwiftPM, no Xcode project), serving a
static tree, is mounted and readable from Terminal:
`cd ~/Library/CloudStorage/WikiFS-WikiFS && find . && cat README.md && grep -R …`
all work. Full writeup + the five gotchas: `plans/file-provider.md`.

**Added (spike code — kept as the Phase 2 reference, serves static content):**
- `Sources/WikiFSFileProvider/` — extension (`FileProviderExtension`,
  `WikiFSEnumerator`, `WikiFSItem`, `Catalog`, `main.swift`).
- `Sources/WikiFS/FileProviderSpike.swift` + `WelcomeView.swift` — register the
  domain, resolve the user-visible path, reveal/copy it.
- `WikiFS/WikiFSFileProvider.entitlements`; second SwiftPM target in
  `Package.swift`; `build.sh` now assembles + inside-out-signs the `.appex`.

**Five gotchas solved (each cost time — see plans/file-provider.md):**
1. Entitlements must be ⊆ the profile — claiming `get-task-allow` (which these
   profiles lack) → AMFI SIGKILL at exec, no crash log.
2. Mach-O entry must be `_NSExtensionMain` via `-e` linker flag; a Swift
   `main()` calling `NSExtensionMain()` recurses → SIGSEGV.
3. Third-party File Provider must be user-enabled in System Settings (consent
   gate); `EnabledByDefault` doesn't bypass it.
4. App must be in `/Applications` + launched once for `pluginkit` discovery →
   dev loop is `make install`.
5. First codesign with a fresh cert needs a one-time keychain approval
   (errSecInternalComponent until then).

**Verified strings/tools:** mount at `~/Library/CloudStorage/WikiFS-WikiFS`;
`fileproviderctl dump` + `pluginkit -m` + `.ips` backtraces were the usable
diagnostics (sandboxed shell can't read the unified log).

## 2026-06-15 — Apple provisioning done up front (pre-Phase 2)

Per the user's call, knocked out the File Provider / App Group portal setup
*before* starting feature work, to de-risk Phase 2. Full detail + verified
strings in `plans/signing.md`.

- Apple Development cert installed: `Apple Development: Thomas Ptacek
  (7F2QE7P59D)` — already matches `DEV_IDENTITY` in the `Makefile`.
- This Mac registered as a dev device (`00006050-00190839016B401C`).
- App IDs created: `org.sockpuppet.WikiFS`, `org.sockpuppet.WikiFS.FileProvider`
  (both with App Groups capability).
- **App Group is `group.org.sockpuppet.wiki`** — NOT `…wikifs`. The `…wikifs`
  group got fouled up in the portal; adopted the working `…wiki` name rather
  than redo + regenerate profiles. Docs updated to match. DB will live at
  `~/Library/Group Containers/group.org.sockpuppet.wiki/WikiFS.sqlite`.
- Two macOS App Development profiles downloaded to `signing/` (gitignored),
  decoded + verified: team `KK7E9G89GW`, this device included, expire
  2027-06-15, authorize the exact entitlements recorded in `plans/signing.md`.
- Remaining signing work (embed profiles, inside-out codesign, `make install`
  loop) is wired in Phase 2.

## 2026-06-15 — Milestone 0: app skeleton on its legs

Bootstrapped the SwiftPM build environment from `Makefile.example` and got a
hello-world WikiFS SwiftUI app building, signing, and launching.

**Added**

- `Package.swift` — executable target `WikiFS`, macOS 14+, Swift tools 6.0.
- `Sources/WikiFS/WikiFSApp.swift` — `@main` App + `WindowGroup`.
- `Sources/WikiFS/ContentView.swift` — `NavigationSplitView` shell (foreshadows
  the sidebar/editor split).
- `Sources/WikiFS/WelcomeView.swift` — hello-world detail pane.
- `WikiFS/WikiFS.entitlements` — minimal (no sandbox yet).
- `scripts/make-icon.swift` — generates the app icon (white `books.vertical.fill`
  on a blue→indigo squircle) at all macOS sizes.
- `build.sh` — `swift build` → assemble `.app` → write `Info.plist` → codesign.
- `Makefile` — adapted from `Makefile.example` (Moves → WikiFS): app name,
  entitlements path, icon comment, notary profile `wikifs-notary`.
- `.gitignore` — `build/ .build/ dist/`.
- Docs: `PLAN.md` (index), `plans/build-environment.md` (build deep-dive).

**Verified**

- `make` builds `build/WikiFS.app` (debug, v0.0.0-dev). Dev cert not in this
  keychain → ad-hoc signature (expected; `make run` still works).
- `make check` compiles clean.
- Live gate (`SWIFTUI-RULES` §9.1): `make run` launches, window renders the
  native two-column layout with the books hero, process stays alive past the
  first display cycle. Screenshot confirmed the UI.

**Notes / decisions**

- Bundle id `org.sockpuppet.WikiFS`; min macOS 14 (matches `Makefile.example`).
- Ran the `swiftui-pro` skill on the sources (CLAUDE.md requirement). Only
  finding: one-type-per-file — extracted `WelcomeView` out of `ContentView.swift`.
- Toolchain present: Apple Swift 6.3.2, macOS 26.5 host.

**Next (Milestone 1 / setup)**

- Add a `WikiFSTests` target so `make test` does something.
- Begin SQLite store + page model (Milestone 0 deliverables in `plans/INITIAL.md`
  also include persistence; the build skeleton is done, the data layer is not).
