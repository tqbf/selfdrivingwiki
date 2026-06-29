# Clean up context menus and centralize batch operations

**Status:** Implemented on `fix/clean-up-context-menu` (commit `a173cbe`). 
**Depends on:** [`share-pages-and-sources.md`](share-pages-and-sources.md), [`tab-context-menu-rebuild.md`](tab-context-menu-rebuild.md), [`url-context-menu-add.md`](url-context-menu-add.md).

## Goal

Remove redundant and low-value actions from the link context menu and sidebar
context menus, add missing "Open in Background" actions throughout, and
centralize ingest/extract/lint operations so they flow through `AgentLauncher`
rather than through ad-hoc callbacks in `ContentView`.

## Changes

### Link context menu (`WikiReaderView` / `WikiLinkMenuNSItems`)

The right-click menu on links in both the page and source WKWebView readers was
cluttered with items that duplicated what the native Share service already covers.

**Removed:**
- "Copy File Path" — low value; superseded by Share.
- "Download…" — superseded by Share (file transfer services in the picker).
- "Copy Link" (WebKit's built-in) — removed from the menu for wiki links; the
  custom items already let you copy or share the target.
- "Open in Browser" — WebKit's native "Open Link" item covers this for external
  links; removed from the custom items list.

**Added / reorganized:**
- "Open in Background" inserted right after WebKit's "Open Link" for resolved
  wiki links (pages and sources), giving quick access to background-tab opening
  without leaving the current page.
- Share item added for non-link right-clicks: when the user right-clicks on
  plain text (no link), a Share item is inserted below the native "Reload" so
  the current document can still be shared without clicking the toolbar.
- WebKit's own Share item is replaced by the custom Share item (resolved via
  `getUserVisibleURL` for wiki links, raw URL for external links) so the picker
  shows the correct human-readable filename rather than the raw `wiki://` URL.
- "Open in Background Tab" renamed to "Open in Background" for consistency with
  the sidebar menus.

The menu is now consistent between page detail and source detail views.

### Page sidebar context menu (`SidebarView`)

**Added:**
- "Open" / "Open N Pages" at the top — opens the page(s) in a new tab.
- "Open in Background" / "Open N in Background" — opens in a background tab
  without switching to it.
- "Find Similar…" submenu (semantic search, excludes the current page).

**Reorganized:**
- Rename moved next to Delete at the bottom.
- Delete given a trash icon.
- Lint Page / Lint N Pages placed in a dedicated section with a separator.
- Lint is now batch-aware: when multiple pages are selected, a single agent pass
  runs against all of them (via the updated `runLintPages` method).

### Source sidebar context menu (`SourcesSectionView` / `SourceRow`)

**Added:**
- "Open in Background" below "Open" (single source).
- "Open N in Background" below "Open N Sources" (multi-select).
- Single-source "Ingest" in the context menu (previously only batch ingest was
  exposed via a callback).
- Extract action for PDF sources that haven't been extracted yet.
- Batch extract for multi-selected PDF sources.
- Re-ingest confirmation dialog: when the user triggers ingest on sources that
  are already ingested, a `confirmationDialog` lists the conflicting names and
  asks before re-running (preventing accidental duplicate pages).

### Centralized `AgentLauncher` operations

Previously, ingest, extract, and lint operations were triggered by callbacks
(`onBatchIngest`) threaded from `ContentView` down to `SourcesSectionView`
through `SidebarView`. This made it impossible for the source row context menu
to trigger these operations directly.

**Moved into `AgentLauncher`:**
- `ingestSource(sourceID:store:manager:fileProvider:)` — ingest a single source.
- `ingestSources(sourceIDs:store:manager:fileProvider:)` — ingest one or more
  sources (the single entrypoint for both the detail view and the sidebar menu).
- `extractPDF(store:id:filename:data:)` — extract markdown from a PDF source,
  serializing through the extraction slot, updating `isExtracting` /
  `extractingSourceIDs`, and seeding the result via `store.seedPdfMarkdown`.

The `onBatchIngest` callback in `SidebarView` and `ContentView.batchIngest`
helper are deleted. `SourcesSectionView` and `SourceRow` now call
`launcher.ingestSources` / `launcher.extractPDF` directly after receiving
`launcher: AgentLauncher` and `manager: WikiManager` as direct dependencies.

**`AgentOperationRunner.runLintPages`** (renamed from `runLintPage`) now
accepts an array of `(id: PageID, title: String)` pairs, runs preflight on each
independently, and passes the combined titles and flattened broken-link list to
a single LLM lint agent call.

## Files changed

- `Sources/WikiFS/AgentLauncher.swift` — `ingestSource`, `ingestSources`,
  `extractPDF` methods; `extractionCoordinator` promoted to a stored property
  (injected in init) so the sidebar can trigger extractions without
  `ContentView` involvement.
- `Sources/WikiFS/AgentOperationRunner.swift` — `runLintPage` → `runLintPages`
  (accepts an array; single page is a one-element array).
- `Sources/WikiFS/ContentView.swift` — removed `batchIngest` helper and
  `onBatchIngest` wiring.
- `Sources/WikiFS/SidebarView.swift` — removed `onBatchIngest`; passes
  `manager` and `launcher` to `SourcesSectionView`; page context menu gains
  Open, Open in Background, Find Similar, and batch-aware Lint.
- `Sources/WikiFS/SourcesSectionView.swift` — gains `manager` and `launcher`;
  ingest/extract logic now calls `AgentLauncher` directly; re-ingest
  confirmation dialog; single-source ingest added.
- `Sources/WikiFS/SourceRow.swift` — gains `onOpenSelected`,
  `onOpenInBackgroundSelected`, `onOpenInBackground`, `onIngest`,
  `onExtract`, `onExtractSelected`, `onRemoveSelected`, and associated count
  parameters for batch-aware labels.
- `Sources/WikiFS/WikiReaderView.swift` — non-link Share item; "Open in
  Background" placement; Share replacement; `currentSelection` property on
  `WikiReaderWebView`; removal of Copy Link from the WebKit items removed set.
- `Sources/WikiFS/WikiLinkMenuNSItems.swift` — removed `copyFilePath`,
  `openInBrowser`, and `downloadLink` action cases; renamed "Open in Background
  Tab" to "Open in Background".
- `Sources/WikiFSCore/WikiLinkMenuBuilder.swift` — removed the corresponding
  action cases from the builder.
- `Sources/WikiFS/PageDetailView.swift` — passes `currentSelection` to the
  web view.
- `Sources/WikiFS/WikiFSApp.swift` — minor wiring update.
- `Tests/WikiFSTests/AgentOperationRunnerTests.swift` — new tests for
  `runLintPages` combination logic (preflight independence, title joining,
  broken-link flat-map).
- `Tests/WikiFSTests/EditorTabTests.swift` — new tests.
- `Tests/WikiFSTests/WikiLinkMenuBuilderTests.swift` — updated for removed
  actions.

## Test strategy

- `AgentOperationRunnerTests` — new test file covering the three combination
  paths in `runLintPages`: independent preflights, title joining, and
  broken-link aggregation.
- `WikiLinkMenuBuilderTests` — updated to reflect removed actions.
- `EditorTabTests` — additional coverage added.
- Full suite: 15 files changed, 664 insertions, 267 deletions.
