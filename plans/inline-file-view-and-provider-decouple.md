# Inline file view + File Provider permission-decouple — handoff

**Status:** Planning / not started. Handoff written 2026-06-20 after an
investigation session (picked up from a crashed `polytoken` run, session
`040163-lemon`). All code seams cited below were re-verified against `main` at
commit `1d9b6a4`.

> **This is the umbrella doc.** Two pieces of the work now have their own
> ready-to-implement design docs:
> - [`plans/wikictl-file-reads.md`](wikictl-file-reads.md) — the first concrete
>   step of PR1: a `wikictl file` family so the agent reads raw files from SQLite
>   instead of the mount during Query.
> - [`plans/file-versioned-editing.md`](file-versioned-editing.md) — **PR2**, now
>   fully designed: inline browsing/editing + a git-lite versioned store for
>   processed markdown (immutable source, append-only version chain, v7→8
>   migration). Supersedes the "sibling row / `extracted_markdown` column"
>   sketch in the PR2 section below.

## What the user asked for

> "Remove the File Provider extension and instead have the text of the file be
> displayed inline in `IngestedFileDetailView`, using the markdown view if
> markdown, using inline PDF preview if PDF. There should be an editor button for
> markdown that functions the same way that `PageReaderView` and `PageEditorView`
> operate if it's editable markdown. If a PDF has been ingested and there is
> markdown available in the database, it should display a tabbed view to swap
> between markdown and PDF."

After three scoping questions, the user **refined** the intent (free-text
answers, verbatim):

1. **Scope of "remove the File Provider":** *"I don't need all the functionality
   gone, but I do need it to not need special permissions that require it to be
   in `/Applications` and there's something to do with file providers that need
   an Apple Developer Account. If we can change the internal workings of it so it
   doesn't need those permissions it's fine."*
2. **PDF markdown source:** *"What does PDF extraction do in that case? Where
   does the markdown go? Does it only go to the agent for processing? If so, I
   think that's silly, there should absolutely be an associated processed
   markdown column or 1:1 table for non-native markdown. … But I think this
   should go in a different PR — reworking the provider is enough for one PR
   itself."*
3. **Editor target:** *"I think this goes back to storing the processed markdown
   — it should edit that table."*

So the work splits into **two PRs**, and the user is explicit that PR1
(provider) is enough on its own.

## ⚠️ Architectural tension to resolve with the user FIRST

`PLAN.md` (lines 12–15) states a **non-negotiable**:

> **Core goal (non-negotiable).** This is a proof-of-concept of the macOS File
> Provider API. The extension is essential, not optional — do **not** replace it
> with a plain-folder export, even though that would dodge the signing
> requirement.

The user's new request directly tensions with this. **The hard truth:** the
`/Applications` requirement and the Apple-Developer-Account requirement are
*inherent to the File Provider API itself*, not to our "internal workings":

- **`/Applications` + Apple Developer Account are intrinsic to File Provider.**
  Per `plans/file-provider.md` (the 2026-06-15 spike's hard-won gotchas):
  - Gotcha #4: `pluginkit` only discovers the `.appex` when its containing app
    lives in `/Applications` and is registered with LaunchServices.
  - Gotcha #1: extension entitlements must be a **subset of the provisioning
    profile**, and the profile (`com.apple.application-identifier` +
    `com.apple.developer.team-identifier`) requires an Apple Developer Account.
    `plans/signing.md` is the full Apple-portal checklist.

  You **cannot** keep an `NSFileProviderReplicatedExtension` and drop these — the
  permissions are the price of the API. "Change the internal workings so it
  doesn't need those permissions" is, strictly, impossible while it remains a
  File Provider extension.

- **Therefore the only way to satisfy the user is to stop *depending* on the
  extension for the in-app experience** — read ingested-file content straight
  from SQLite in the app (which is what the original message asks for: "display
  inline … instead"). That makes the extension *optional*: keep it for the
  Terminal/Finder mount when signing is available, but the app works fully
  without it (no `/Applications`, no Dev Account).

**Action for the implementing agent:** before writing PR1 code, confirm with the
user that the intended end state is *"File Provider becomes optional; the app
reads files from SQLite directly so it runs unsigned outside `/Applications`."*
This contradicts the current `PLAN.md` non-negotiable, so `PLAN.md` must be
amended as part of PR1 — that's a deliberate decision the user needs to own, not
a silent override.

## Verified findings (re-checked against `main`)

**The good news — staging is already half-decoupled:**

- `AgentStaging.stageSources` (`Sources/WikiFSCore/AgentStaging.swift:72`) writes
  raw `source.<ext>` bytes into a **scratch dir** — it does **not** read from the
  mount. Staging the agent's input never depended on the File Provider.
- `AgentOperationRunner.swift:47` already pulls bytes via
  `store.ingestedSourceBytes(id: fileID)` — the SQLite path exists today.
- The mount coupling in `AgentOperationRunner` is narrow: `fileProvider.signalChange()`
  + `fileProvider.path` at lines **155–156** and **197–200** (refresh/resolve the
  mount root), not source staging.

**The store seams that make inline display cheap:**

- `WikiStoreModel.ingestedSourceBytes(id:)` (`WikiStoreModel.swift:802`) →
  `store.ingestedFileContent(id:)` (`SQLiteWikiStore.swift:764`) returns the
  verbatim `BLOB`. Reading file contents in-app needs **no new code**.
- `WikiStoreModel.hasIngestedFile(_:)` (`WikiStoreModel.swift:806`) reconstructs
  the "has been ingested into the wiki" flag by **grepping `log.md`** for the
  filename / `by-id` leaf — there is **no structured FK** from a wiki page back
  to its source ingest ID.

**The PDF-markdown gap (drives PR2):**

- `PdfExtractionService.convert` produces markdown, but in
  `AgentOperationRunner.swift:82` it becomes `sourceBytes = markdown.data(...)`
  and is **staged to the agent only — never persisted**.
- The `ingested_files` table holds **verbatim bytes only**:
  ```sql
  CREATE TABLE ingested_files (
    id TEXT PRIMARY KEY,             -- ULID
    filename TEXT, ext TEXT, mime_type TEXT, byte_size INTEGER,
    content BLOB,                    -- verbatim bytes only
    created_at REAL, updated_at REAL, version INTEGER, ingested_at REAL
  );
  ```
  No `extracted_markdown` column; full table list: `pages`, `attachments`,
  `page_links`, `ingested_files`, `system_prompt`, `log`, `wiki_index`,
  `wiki_embeddings`/`page_embeddings`. The user is right that this is "silly" and
  wants extraction output stored.
- Note `plans/pdf-extraction.md` already envisioned storing extracted markdown as
  a **sibling `ingested_files` row**; reconcile PR2 with that design (sibling row
  vs. new `extracted_markdown` column vs. 1:1 table — see PR2 below).

## PR1 — Decouple the app from the File Provider extension

**Goal:** the app displays ingested-file content inline and runs fully without
the extension — no `/Applications`, no Apple Developer Account. The extension
stays in the tree as an *optional* mount for Terminal/Finder when signing is
available.

> **First concrete step has its own design:**
> [`plans/wikictl-file-reads.md`](wikictl-file-reads.md) covers removing the
> agent's Query-time raw-file dependency on the mount (the `wikictl file` family).
> Do that before/alongside the view + build-system work below.

1. **Inline display in `IngestedFileDetailView`** (`Sources/WikiFS/IngestedFileDetailView.swift`):
   - Load bytes via `store.ingestedSourceBytes(id:)`.
   - Markdown / text (`ext ∈ {md, markdown, txt}`): render via `MarkdownPreview`
     (the same path `PageReaderView` uses).
   - PDF: inline preview. **Adds PDFKit** (no PDFKit in the project today —
     confirmed). Wrap `PDFView` in an `NSViewRepresentable`.
   - Other binaries: keep a metadata/"open externally" fallback.
   - Stop calling `fileProvider.openIngestedFile(id:)` from this view.
2. **Make `FileProviderSpike` optional, not load-bearing.** Audit every
   `fileProvider:` parameter (`PageDetailView`, `WikiDetailView`,
   `QueryConversationView`, `FilesSectionView`, `IngestedFileRow`,
   `WikiFSApp.onPageDidChange`, `WikiChangeBridge`). Where the mount is just a
   convenience (open-in-default-app, status), guard it so its absence is a
   no-op rather than a crash/empty view.
3. **`AgentOperationRunner`:** confirm the run path is fully SQLite-fed (staging
   already is). The `signalChange()`/`path` calls at 155–200 should become
   best-effort no-ops when no domain is registered.
4. **Build/run without `/Applications`:** make `make run` from `build/` a
   first-class, fully-functional dev loop (today `plans/file-provider.md` gotcha
   #4 forces `make install` into `/Applications`). The `.appex` packaging +
   signing in `build.sh`/`Makefile` becomes **opt-in** (e.g. a flag/target),
   not required for a working app.
5. **Docs:** amend the `PLAN.md` non-negotiable (per the tension section above),
   update `README.md`'s "read via mount, write via wikictl" invariant to "mount
   optional," and note the change in `ISSUES.md`.
6. **Tests:** the suite currently asserts a "clean signed bundle (app + appex +
   wikictl)" (PLAN.md). Re-scope so green doesn't require signing.

## PR2 — Store processed markdown; tabbed view + editor (separate, later)

**→ Fully designed in [`plans/file-versioned-editing.md`](file-versioned-editing.md).**
The shape question below is now decided: a **git-lite versioned store** — an
immutable source plus an append-only `file_markdown_versions` chain (v7→8
migration), with revert-by-append. This supersedes the (a)/(b)/(c) sketch and the
`plans/pdf-extraction.md` "sibling row" idea. The bullets below are kept only as
the original framing; read the design doc for the implementation.

Depends on PR1. Per the user's answers #2 and #3:

1. **Persist extraction output.** ~~Decide the shape~~ → done: versioned
   `file_markdown_versions` table; wire `PdfExtractionService` output in as
   version 1 (reused at ingest time, plus a standalone "Extract Markdown" action).
2. **Tabbed markdown ⇄ PDF** in `IngestedFileDetailView` when a PDF has stored
   processed markdown.
3. **Editor button** mirroring `PageReaderView`/`PageEditorView`, bound to the
   **versioned processed-markdown** (user answer #3) — each edit session appends a
   new version; the source bytes stay immutable.

## Where to resume

The crashed session ended right here: the user said *"please write out a plan to
markdown as handoff"* → *"okay, please do that."* **This document is that plan.**

Next step for whoever picks this up: get the user's explicit sign-off on the
PR1 end-state (File Provider → optional; `PLAN.md` non-negotiable amended), then
implement PR1. Use the `swiftui-pro`, `typography-designer`, and `macos-design`
skills per `CLAUDE.md` before and after the UI work.
