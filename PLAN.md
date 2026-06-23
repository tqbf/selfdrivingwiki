# Self Driving Wiki

**What this is.** A native macOS SwiftUI wiki backed by SQLite. An optional
**File Provider extension** mirrors content read-only onto the filesystem under
`~/Library/CloudStorage/Self Driving Wiki-<wiki name>` so Unix tools and agents
can browse it (`find`, `cat`, `grep`). When the extension is not available (e.g.
unsigned dev builds outside `/Applications`), the app reads everything from
SQLite directly. You edit in the app; the mount reflects every change when
enabled. It ingests dropped files, stores them as verbatim BLOBs, and projects a
singleton agent system prompt as `CLAUDE.md` + `AGENTS.md` at the root. Runs
locally only — free, local dev signing; no Developer ID / notarization.

**The File Provider extension is now optional.** The in-app experience —
displaying pages, browsing ingested files, and running agent operations — reads
from SQLite via `wikictl` (pages, raw files) and staged scratch directories
(sources, wiki-state). The extension remains in the tree as an opt-in mount for
Terminal and Finder browsing when signing is available, but it is no longer
load-bearing for the app to function.

**Where to find things.**

- **This file (`PLAN.md`)** — the master index: the doc map below, milestone
  status, and the build quick-reference.
- **`PROGRESS.md`** — the running log, newest first: what was built each step and
  the evidence each gate passed. *To get a future agent up to speed, read
  `PLAN.md` then `PROGRESS.md`.*
- **`plans/`** — the deep design docs (architecture, build, File Provider,
  signing); see the table below for which is which.
- **`ISSUES.md`** — known limitations we've chosen to live with.
- **`SWIFTUI-RULES.md`** / **`CLAUDE.md`** — coding rules and the working
  agreement (docs to keep, skills to use, PR rules).

## Documentation index

| Doc | What it covers |
| --- | --- |
| [`README.md`](README.md) | **Start here (new developers).** What Self Driving Wiki is, the non-negotiable read-only-mount / write-via-`wikictl` invariant, quick start (`make` targets + the runtime gotchas), repo layout, and a tour of how it works. |
| [`plans/architecture.md`](plans/architecture.md) | **The system map.** Components/targets, the per-wiki SQLite data model + migration ladder + `changeToken()`, the File Provider projection, the read/write split + change bridge, the `claude -p` operations (Ingest tiering, Query, Lint), URL ingest, and the key invariants/gotchas. Read after the README to go deep. |
| [`plans/INITIAL.md`](plans/INITIAL.md) | Original full product/architecture plan (milestones, schema, File Provider design, definition of done). Source of truth for *what we're building*. |
| [`plans/llm-wiki.md`](plans/llm-wiki.md) | **Next major effort:** turning Self Driving Wiki into a self-maintaining LLM Wiki — **many** wikis (one SQLite DB + one File Provider domain each), with `claude -p` authoring/maintaining each one by writing via a new `wikictl` CLI (read via the mount, write via the CLI). Locked decisions, components, and the Phase 0 → A–D plan. Read before Phase 0. |
| [`plans/page-reader-ui.md`](plans/page-reader-ui.md) | **Current UI direction:** page detail is reader-first because the agent should maintain wiki content; manual source editing is an explicit, rare mode. |
| [`plans/query-conversation.md`](plans/query-conversation.md) | **Current Query direction:** a dedicated sidebar page with an interactive Claude session; output-first chat by default, hidden tool/internal rows behind a checkbox, and writes via `wikictl` only when the user asks to persist changes. |
| [`plans/BRINGUP.md`](plans/BRINGUP.md) | The 4-phase bring-up plan from skeleton to v0 (groups INITIAL.md's M0–M6). Source of truth for *the order we build in*. |
| [`plans/build-environment.md`](plans/build-environment.md) | How the app is built: SwiftPM + `build.sh` + `Makefile`, signing, icon generation, app-bundle layout. Source of truth for *how we build and run*. |
| [`plans/file-provider.md`](plans/file-provider.md) | File Provider extension build + the 5 hard-won gotchas (entry-point recursion, entitlements⊆profile, user-enable toggle, /Applications, keychain). Proven by the 2026-06-15 spike. Read before Phase 2. |
| [`plans/signing.md`](plans/signing.md) | The Apple cert / App Group / File Provider provisioning checklist (manual portal). Do this before Phase 2. Source of truth for *the Apple incantations*. |
| [`plans/zotero-integration.md`](plans/zotero-integration.md) | browse a Zotero library from inside the app, ingest PDF/Markdown attachments through the existing ingest pipeline. |
| [`plans/zotero-source-link.md`](plans/zotero-source-link.md) | Stamp Zotero item key+title on ingested files (v8→v9 migration) and show a "View in Zotero" link in the ingested-file detail view. |
| [`plans/pdf-extraction.md`](plans/pdf-extraction.md) | Add docling + granite-docling pipeline. A `pdf2md` CLI converts PDFs to markdown at ingest time; extracted markdown stored as a sibling `ingested_files` row, projected on the mount. Agent prefers `.md` siblings, falls back to `Read` on the original. |
| [`plans/pdf-extraction-backends.md`](plans/pdf-extraction-backends.md) | **Pluggable extraction backends.** A `MarkdownExtractor` protocol + `ExtractionCoordinator` so PDF→Markdown can run via **local pdf2md** (default), **Claude** (Anthropic API), **Gemini** (Google AI), or a self-hosted **Docling Serve**. Backend-agnostic storage (no schema change), a Settings tab that shows only the selected backend's config + per-backend Test Connection, and config/Keychain/HTTP patterns mirroring Zotero. |
| [`plans/semantic-search.md`](plans/semantic-search.md) | Semantic (meaning-based) search over pages using sqlite-vec + Apple NLEmbedding. Embedding at save time, cosine-similarity ranking inside SQLite, search bar in the sidebar, `wikictl search` for the agent. v7 migration. |
| [`plans/markdown-folder-import.md`](plans/markdown-folder-import.md) | Import an entire folder of Markdown files (Obsidian vault, LogSeq graph, or any `.md` directory) as source material. Recursive walk, .md filter, filename dedup; lands files in `ingested_files` for the agent to curate via Ingest. |
| [`plans/sources-redesign.md`](plans/sources-redesign.md) | **Design phase:** rebrand "ingested files" as first-class **sources** — `[[source:...]]` wikilinks, display-name editing, processed-markdown projection, full rename + v10 migration. |
| [`plans/fix-phase-a-source-bugs.md`](plans/fix-phase-a-source-bugs.md) | **Blocks Phase B.** Fixes two bugs shipped in Phase A (PR #31): `source_links` FK missing `ON DELETE CASCADE` (v11 rebuild migration) and the File Provider still projecting `files.jsonl`/`files/` instead of `sources.jsonl`/`sources/`. |
| [`plans/phase-b-source-wikilinks.md`](plans/phase-b-source-wikilinks.md) | **Phase B, re-grounded.** Implements `[[source:...]]` wiki links correctly, superseding the Phase B portion of `sources-redesign.md` wherever they conflict. Render source links as `wiki://source?title=` (mirror pages), shared normalizer + case-insensitive resolution, single-transaction `replaceLinks` over both link tables, unified `links.jsonl` with a `type` field. Depends on `fix-phase-a-source-bugs.md`. |
| [`plans/content-type-over-extension.md`](plans/content-type-over-extension.md) | **Cross-cutting prerequisite.** Make the content-derived `mime_type` the behavioral authority: extract a `ContentSniff` helper, make `addSource` sniff bytes (not trust the extension), MIME-first `WikiFSItem.contentType`, Zotero filter, and a grep guard against new extension checks. Phase C depends on it. |
| [`plans/phase-c-source-markdown-projection.md`](plans/phase-c-source-markdown-projection.md) | **Phase C, re-grounded.** Project a `.md` sibling (HEAD of `source_markdown_versions`) for sources with a conversion chain. Fixes the parent design's two false assumptions (the change bridge doesn't see chain edits; markdown sources don't get chains) and encodes the git-lite model: PDF-only chains, HEAD-only projection, revert/compare-ready. Depends on `content-type-over-extension.md`. |
| [`plans/markdown-anchors.md`](plans/markdown-anchors.md) | **New feature.** In-document anchors and footnote citations: `[[Page#Section]]` (heading slug) for pages, `[[source:Name#"quoted passage"]]` (text-quote) for sources — quote-based so citations survive PDF re-extraction (nothing stored in the source text). Render-time block ids + navigate-then-scroll via a pending anchor. Footnotes already linkify, so they get it free. Includes agent-prompt docs for footnote + cite-by-quote conventions. |
| [`plans/phase-d-display-names-rename.md`](plans/phase-d-display-names-rename.md) | **Phase D, re-grounded.** Editable source display names + rename propagation. Supersedes the parent's Phase D (fragment-blind, body-scan): rewrite swaps the link base only — preserving `#fragment` and `\|alias` (markdown-anchors) — driven off the `source_links` graph (new read helper), code-span-safe, transactional, with by-name projection switched to `display_name` and the change bridge refreshed on rename. Drops the false "general capability" claim (page-rename rewriting is a follow-up). |
| [`plans/extraction-vs-ingestion-lock.md`](plans/extraction-vs-ingestion-lock.md) | **Current direction:** treat markdown *extraction* (pdf2md) and agent *ingestion* (the `claude -p` run) as two phases. Extraction must never lock queries, edits, or another file's ingest. Split the overloaded `ingestingFileIDs` into `extractingFileIDs` (pdf2md phase) + `ingestingFileIDs` (agent-spawn phase), plus an optional separate extraction lock to serialize pdf2md without touching the spawn slot. |
| [`plans/wikictl-file-reads.md`](plans/wikictl-file-reads.md) | A `wikictl file` command family (`list` / `cat` / `export`) so the agent reads raw ingested files from SQLite instead of the File Provider mount during Query. First concrete step of the provider-decouple effort; rewrites the Query prompt off `$WIKI_ROOT/files/...`. |
| [`plans/tab-context-menu-rebuild.md`](plans/tab-context-menu-rebuild.md) | Multi-tab editor space — design of record. `activeTabID: UUID?` source of truth (no index arithmetic), one-intent-per-method tab ops, tab reuse, native SwiftUI `.contextMenu` (Close / Close Others / Close Tabs After / Close All), opacity-fade close button, responsive shrink-to-fit strip with overflow menu. 43 `EditorTabTests` + 7 `TabBarLayoutTests`. |
| [`plans/link-context-menus.md`](plans/link-context-menus.md) | **Implemented (`feature/link-context-menus`).** Right-click link context menus (Suggest for missing links, Find Similar for any link, Copy as wiki-link, Open in Browser + Copy Link) — right-click now selects the **whole link**, not the word under the cursor. Documents the Textual blocker (its `NSTextInteractionView` owns right-click + the menu internally; `model.url(for:)` hit-test is internal) and the decision to vendor Textual in-repo. Copy File Path + Edit Link are classified but deferred (see `PROGRESS.md`). |
| [`plans/reader-editor-zoom.md`](plans/reader-editor-zoom.md) | Safari-style text zoom for the page reader and monospace editors. Pure `ZoomScale` model (0.5–3.0, ×/÷1.1 step, scroll-step accumulation); `@AppStorage` keys `reader.zoom` and `editor.zoom` (first in the app); ⌘+/⌘=/⌘−/⌘0 via `.opacity(0)` buttons (`ZoomShortcuts`) and ⌘+scroll (`ZoomScroll`) in `PageDetailView` and `SourceDetailView`. No menu item. 21 `ZoomScaleTests`. |
| [`plans/link-context-menus.md`](plans/link-context-menus.md) | **Implemented (`feature/link-context-menus`).** Right-click link context menus (Suggest for missing links, Find Similar for any link, Copy as wiki-link, Open in Browser + Copy Link) — right-click now selects the **whole link**, not the word under the cursor. Documents the Textual blocker (its `NSTextInteractionView` owns right-click + the menu internally; `model.url(for:)` hit-test is internal) and the decision to vendor Textual in-repo. Copy File Path + Edit Link are classified but deferred (see `PROGRESS.md`). |
| [`plans/reader-editor-zoom.md`](plans/reader-editor-zoom.md) | Safari-style text zoom for the page reader and monospace editors. Pure `ZoomScale` model (0.5–3.0, ×/÷1.1 step); `@AppStorage` keys `reader.zoom` and `editor.zoom` (first in the app); ⌘+/⌘=/⌘−/⌘0 via hidden buttons in `PageDetailView` and `SourceDetailView`. Keyboard-only; no menu item. 15 `ZoomScaleTests`. |
| [`plans/quote-highlight-and-scroll.md`](plans/quote-highlight-and-scroll.md) | **Implemented (`main`).** Extends markdown-anchors' navigate-then-scroll with **highlight the exact quoted passage** and **work on PDF sources**. Markdown: `WikiLinkStylingParser.highlightQuote` + pure `quoteRange` whitespace-tolerant first-match → `.backgroundColor` (`NSColor.findHighlightColor`). PDF: `PDFKit.findString` → `currentSelection` → `scrollSelectionToVisible`. `pendingScrollAnchorVersion` counter for re-click reactivity. 17 new `QuoteHighlightTests` + 2 `AnchorBlockTests` regression; 911 total. |
| [`plans/source-web-reader.md`](plans/source-web-reader.md) | **Planned (`feat/source-web-reader`).** Productionize the WKWebView reader prototype for large sources (500 KB+), where the native Textual reader freezes on whole-document layout (preprocess + parse is only ~260 ms on 513 KB — the freeze is layout). Size-gated (native reader stays for small docs / pages), async load, shared `WikiFootnoteMarkdown` / `WikiLinkMarkdown` pre-pass, full feature parity (wiki links, footnotes, anchors, quote highlight), app-matched theming. Open decisions: converter (`swift-markdown` vs `cmark-gfm`), threshold value, whether to prewarm the WebContent process. |
| [`SWIFTUI-RULES.md`](SWIFTUI-RULES.md) | Hard-won SwiftUI/macOS rules. Apply when writing or reviewing any view. |
| [`CLAUDE.md`](CLAUDE.md) | Working agreement (docs, skills to use, PR rules). |
| [`ISSUES.md`](ISSUES.md) | Known limitations we've chosen to live with (with context to revisit), e.g. the ~5s replicated-File-Provider read-after-write window. |

## Status

See `PROGRESS.md` for the running log. Current: **🎉 LLM Wiki COMPLETE ✅ — all
five phases (0, A, B, C, D) gate-passed.** Self Driving Wiki is now a self-maintaining LLM
wiki: a user keeps **many** wikis (one SQLite DB + one File Provider domain
each); an LLM (`claude -p`, run as **Ingest / Query / Lint** from the app)
authors and maintains each one — reading the read-only mount and writing via the
new **`wikictl`** CLI — keeping curated `index.md` + chronological `log.md`
current, cross-linking pages with clickable `[[wiki-links]]`, all under a real
maintainer schema projected as `CLAUDE.md`/`AGENTS.md`. Agent runs stream live
(tool calls + text, `--output-format stream-json`) with per-run backend
`run.jsonl` logs and an editor edit-lock. **All five phases plus the post-completion
features below are merged to `main` (single-branch repo, ready for developer
handoff). 341 tests green; clean signed bundle (app + appex + `wikictl`).**

**Post-completion features (also on `main`):**
- **File filter + batch ingest** — the Files section has a filter picker
  (All / Ready / Ingested) and a "Select…" button that enables batch mode with
  checkboxes. Selected files are ingested in a SINGLE agent run — all sources staged
  together so the agent cross-references and synthesizes holistically. The ingest
  pipeline was generalized from one source → N sources (`WikiOperation.ingest`,
  `AgentStaging.stageSources`, `AgentOperationRunner.runMultiIngest`).
- **Import Markdown Folder** — a one-shot "Import Markdown Folder…" action that
  recursively walks a directory of `.md` / `.markdown` files (Obsidian vault, LogSeq
  graph, or any folder) and lands them in `ingested_files` for the agent to curate
  via Ingest. Hidden files/dirs are skipped; duplicate filenames get a disambiguating
  suffix. `MarkdownFolderReader` (pure core) + `ImportMarkdownSheet` (phase-enum UI).
  26 new tests. See `plans/markdown-folder-import.md`.
  wiki, export its checkpointed standalone SQLite file, and import a SQLite wiki
  backup under a new display name/new ULID. Rename refreshes the File Provider
  display name while preserving identity; export refuses to overwrite its source.
- **Ingest model-tiering** — Ingest is now **Opus-curated**: Opus decides what goes
  in the wiki and writes every page; for a large source it fans out **2–19 Sonnet
  `source-reader` subagents** (via `claude -p --agents`) that only *digest* the
  bulk content and return extracts (they never write), and Opus may fork follow-up
  readers / pull pages to double-check. Tiny sources are a single Opus pass. The
  per-run scratch dir stages the source + a live `WIKI_STATE.md` snapshot from
  SQLite so the agent never re-derives structure from the laggy mount.
- **Ingest a resource by URL** — an "Add from URL…" sheet fetches a URL, normalizes
  known file-share links (Dropbox `www`→`dl`; Drive/OneDrive stubbed), content-sniffs
  the bytes, converts HTML→Markdown (hand-rolled, dependency-free) or stores
  PDFs/binaries verbatim — landing through the same ingest path as drag-drop.
- **PDF extraction pipeline** — local `pdf2md` script (docling + granite-docling VLM)
  converts PDFs to Markdown before the agent sees them. `PdfExtractionService` spawns
  `pdf2md` as a subprocess with continuous pipe draining; `PdfExtractionView` shows
  readiness, download progress, and live conversion log during ingest. 22 Swift tests
  + 67 Python tests. (PR #11.)
- **Serialized claude spawn slot** — the single shared `AgentLauncher` now serializes
  all `claude -p` spawns (ingest / query / lint) through a FIFO, cancellation-aware
  spawn slot (`awaitSpawnSlot` / `releaseSpawnSlot`). Two claude runs never overlap;
  a `pdf2md` extraction may overlap a claude query run (it does NOT take the slot).
  The old silent-drop `guard !isRunning` is gone — a query started during an ingest's
  extraction now runs, and the ingest agent waits for the slot and runs afterward. The
  edit lock (`store.isAgentRunning`) is unchanged in meaning: locked only while a
  claude process runs, unlocked during extraction. The Query page mounts the orange
  `AgentRunBanner` and scopes its debug cluster to active query runs only. 6 new
  `AgentSpawnSlotTests`.

**Phase summary (newest first; see `PROGRESS.md` for each gate's evidence):**
- **Phase D — the schema** ✅ real maintainer `CLAUDE.md` schema (layout,
  conventions, `wikictl` reference, read-after-write rule, Ingest/Query/Lint
  playbooks); `-p` prompts slimmed to rely on it; new wikis seed it, existing
  unaffected. Also hardened File Provider domain registration (verify/retry/nudge/
  surface-errors).
- **Phase C — `claude -p` operations** ✅ Ingest/Query/Lint scoped runs +
  `--dangerously-skip-permissions` + layout-up-front (`TREE.md`) + live streaming
  panel + backend logs + per-wiki edit-lock + clickable `[[wiki-links]]`.
- **Phase B — `log.md` + `index.md`** ✅ v3→4 `log` table + v4→5 `wiki_index`
  singleton; `wikictl log append` / `index set`; both projected read-only at root;
  `changeToken()` folds.
- **Phase A — write path + change bridge** ✅ `wikictl` (page upsert/get/list/
  delete) + shared `PageUpsert` link-reparse + per-wiki Darwin notification →
  debounced sidebar rebuild + `signalChange()`.
- **Phase 0 — many wikis** ✅ wiki registry (ULID identity), per-wiki DBs +
  per-wiki File Provider domains, in-app switcher, v0 wiki migrated as wiki #1.

**Prior: LLM Wiki Phase A (Write path + change bridge) DONE ✅ — live gate
passed.** The `wikictl` CLI (`page list/get/upsert/delete`, selecting a wiki via
`--wiki`/`WIKI_DB`) writes straight to a wiki's `<ulid>.sqlite`; a shared
`PageUpsert` op keeps the `[[link]]` graph identical across the app and the CLI;
`wikictl` posts a per-wiki Darwin notification and the app's debounced change
bridge rebuilds the sidebar + `signalChange()`s that wiki's mount. 113 tests;
clean signed bundle (app + appex + `wikictl`). Branch `llmwiki/phase-a-write-path`
(stacked on `llmwiki/phase-0-many-wikis`, unmerged).

**Prior: LLM Wiki Phase 0 (Many wikis) DONE ✅ — live gate passed.** One SQLite DB
+ one File Provider domain **per wiki**, a `wikis.json` registry, an in-app
create/select/delete switcher, and the single v0 wiki migrated in as wiki #1
(idempotently). Branch `llmwiki/phase-0-many-wikis`. See `plans/llm-wiki.md` for
the Phase 0 → A–D plan.

**Prior baseline: 🎉 v0 DONE ✅ — all four phases gate-passed (M0–M6).** A native macOS SwiftUI wiki, SQLite-backed,
projected read-only onto the filesystem via a File Provider extension, kept
fresh on edit, and traversable by an agent launched with `WIKI_ROOT`. Delivered
across four stacked, **unmerged** branches off a pristine `main`
(`phase-1-local-wiki` → `phase-2-file-provider` → `phase-3-verify-fresh` →
`phase-4-agent-wiki`) — review and merge locally. See `PROGRESS.md` for each
gate's evidence and the known v0 gaps.

**Post-v0 features** (also stacked, unmerged):

- `phase-5-file-ingest` — drag a file in to **ingest** it (raw bytes + metadata
  stored in a new `ingested_files` SQLite table, NOT a wiki page; surfaced
  read-only under `files/by-id` & `files/by-name`; removable "Files" list).
  Verified with a real 8 MB PDF served byte-identical from the mount.
- **System-prompt document** — a user-editable singleton "system prompt" (DB
  `system_prompt` table, v2→3 migration) projected **read-only at the wiki root
  as both `CLAUDE.md` and `AGENTS.md`** (identical bytes). Edited in-app via a
  pinned sidebar item. Code complete + unit-tested (69 tests); **live-mount gate
  pending**. See `PROGRESS.md`.

## Milestones (from `plans/INITIAL.md`)

- **M0 — App skeleton** ✅ build environment + launching SwiftUI window.
- **M1 — Markdown editor** ✅ sidebar page list, `TextEditor`, preview, autosave, SQLite persistence.
- **M2 — File Provider domain** ✅ extension target, domain registration, static root + `README.md`.
- **M3 — SQLite-backed page files** ✅ `pages/by-id`, `pages/by-title`, content from SQLite.
- **M4 — Path button** ✅ `Copy Unix Path`, verification commands in-app.
- **M5 — Change signaling** ✅ edits increment version; Terminal reads see updates (no relaunch).
- **M6 — Agent launch** ✅ spawn agent with `WIKI_ROOT` env pointing at the projection.

## Build quick reference

```sh
make          # debug build → build/Self Driving Wiki.app
make run      # build + launch
make check    # compile-only gate (no bundle/sign)
make help     # all targets
```

Full detail: [`plans/build-environment.md`](plans/build-environment.md).
