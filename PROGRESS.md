# Progress log

Newest first. To get up to speed: read `PLAN.md` then this file.

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
