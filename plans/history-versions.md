# History / Versioning Investigation — Time-Travel History Tab

Read-only investigation of the existing versioning + diff infrastructure, to scope a
"History" tab that: (1) browses pages/sources at earlier points in time,
(2) diffs any two versions side-by-side, (3) restores/views a specific historical
version.

Issue: #817.

---

## TL;DR — what already exists

The backend is **remarkably complete**. A PROV-DM content-graph model with
append-only, full-text-snapshot version chains already backs BOTH pages and
sources, with blob-level dedup, provenance (agent/activity), revert, and a polished
side-by-side diff view. What's missing is **mostly UI wiring**: a version *picker*
and a *rendered historical view*, plus lifting a couple of store methods
(`revertPage`, a "read arbitrary page-version body") up to the model and into a view.

| Capability                          | Pages                              | Sources (extraction markdown)        |
|-------------------------------------|------------------------------------|--------------------------------------|
| Append-only version chain           | ✅ `page_versions`                 | ✅ `source_markdown_versions`        |
| Full snapshot per version (not delta) | ✅ via `blobs`                   | ✅ via `blobs`                        |
| Version-chain traversal (history list) | ✅ `pageVersionHistory` / `pageEditHistory` | ✅ `processedMarkdownHistory` |
| Provenance (author/agent/activity/time) | ✅ `PageOrigin` (joined)        | ✅ `ExtractionAlternative` (joined)  |
| Read full content of any version    | ⚠️ only inside `revertPage` (no public read) | ✅ `processedMarkdownVersion(id:)` / `HEAD` carry `.content` |
| Revert / restore to a version       | ✅ store `revertPage` (NOT on model/UI) | ✅ `revertProcessedMarkdown` (model + UI) |
| Side-by-side line diff              | ❌ not wired for page versions     | ✅ `SplitDiffView` (source alternatives only) |
| Diff algorithm                      | ✅ `MarkdownDiff` (LCS line diff) + `SplitDiff` (alignment) + `Diff3` (3-way merge) | same |
| Browsable history UI                | 🟡 "History" inspector tab — timestamps + badges, click navigates to *writer* (chat/job), does NOT view/diff/restore | 🟡 "Compare Extractions…" window — full diff + active-switch |

---

## 1. Versioning schema

All schemas live in `Sources/WikiFSCore/Store/GRDBWikiStore.swift` (fresh-schema
block ~L2210–2570; the same tables are reproduced in the migration ladder).

### 1a. Content-addressed blobs (shared dedup store)
```
blobs (hash TEXT PK, byte_size INTEGER NOT NULL, content BLOB NOT NULL)
```
Identical bytes → one row ever (`INSERT OR IGNORE`). Every version is a
**full snapshot**, not a delta — but byte-identical snapshots dedup to one blob row.

### 1b. Provenance substrate (PROV-DM: agents + activities)
```
agents    (id, kind, name, version?, external_ref?)
activities(id, kind, agent_id→agents, plan?, external_ref?, started_at, ended_at?)
```
An `activity` is "an edit / an extraction / an import / a fetch"; `wasAssociatedWith`
an agent. A version row's `activity_id` is its `wasGeneratedBy`. `PageAuthor`
(`Sources/WikiFSTypes/PageAuthor.swift`) owns the `agents.name` convention
(`chat:<id>`, `agent:<kind>`, `user`, `legacy-import`).

### 1c. Page version chain (`page_versions`, v30 / W0)
```
page_versions (
  id              TEXT PK,          -- ULID, sorts chronologically
  page_id         TEXT → pages(id) ON DELETE CASCADE,
  parent_id       TEXT,             -- previous version (the chain link)
  merge_parent_id TEXT,             -- 2nd parent for merge commits (W2+; nil in linear history)
  blob_hash       TEXT → blobs(hash),  -- the full body
  title           TEXT NOT NULL,
  activity_id     TEXT → activities(id),
  saved_at        REAL NOT NULL
)
INDEX page_versions_page ON page_versions(page_id, id)
```
`merge_parent_id` is plumbed for the workspace three-way-merge feature (W2) but is
NULL for ordinary edits.

### 1d. Source content chain (`source_versions`, v20) — the *original bytes*
```
source_versions (
  id, source_id→sources, parent_id, blob_hash→blobs, mime_type,
  original_path, thumbnail_hash→blobs, activity_id→activities,
  external_identity, fetched_at)
```
This is the **raw fetched bytes** chain (e.g. the original PDF, the website
snapshot). Separate from the processed-markdown chain below.

### 1e. Source markdown chain (`source_markdown_versions`, v8 → CAS-moved in v21)
```
source_markdown_versions (
  id              TEXT PK,          -- ULID
  file_id         TEXT → sources(id) ON DELETE CASCADE,
  parent_id       TEXT,             -- previous version
  origin          TEXT NOT NULL,    -- extraction | user | revert | source | transcript
  note            TEXT,
  created_at      REAL NOT NULL,
  activity_id     TEXT → activities(id),
  source_version_id TEXT,           -- which source_bytes version this was extracted from
  blob_hash       TEXT → blobs(hash),  -- the full markdown body (CAS)
  mime_type       TEXT NOT NULL DEFAULT 'text/markdown',
  technique       TEXT)             -- "pdf2md" | "anthropic" | "gemini" | "docling" | …
INDEX file_markdown_versions_file ON source_markdown_versions(file_id, id)
```
**Full-text snapshot per version** (`SourceMarkdownVersion.content` is the
blob-decoded body — the `content` column itself was DROPPED in v21 in favor of
the blob join; `smvSelectColumns` + `smvBlobJoin` are the read helpers).

### 1f. Refs — the "active HEAD" pointer (v20 / v34)
```
refs (kind, owner_id, version_id, generation INTEGER, updated_at, PK(kind, owner_id))
kind ∈ ('source-content','source-derived','page-content')
```
A ref points at the **active** version for an owner. **Default-active rule:** when no
ref row exists, `MAX(id)` (the newest ULID) is the head. This lets `setActiveMarkdown`
/ `revertPage` *repoint* HEAD without rewriting history.

### 1g. Workspaces (W1–W3, v31–32) — orthogonal but relevant
```
workspaces         (id, name, status FSM, activity_id, index_body, index_base_version, created_at, updated_at)
workspace_refs     (workspace_id, kind='page-content', owner_id, base_version_id, version_id, blob_hash, title, updated_at)
workspace_conflicts(workspace_id, page_id, base/main/ws version ids, created_at)
```
Branches for parallel agent edits + three-way merge. **Not needed** for read-only
time-travel browsing, but the conflict rows show the base/ours/theirs version-ids
pattern that a diff view reuses.

---

## 2. Version-chain traversal — what queries exist

### Pages (`GRDBWikiStore` + `WikiStoreModel`)
| Method | Returns | Notes |
|--------|---------|-------|
| `pageHeadVersionID(pageID:)` | `String?` | ref → version_id, else `MAX(id)` |
| `pageVersionHistory(pageID:)` | `[PageVersionSummary]` | raw chain, `ORDER BY id ASC` (oldest-first). Has id/parent/merge/blob/title/activity/savedAt. |
| `pageOrigin(pageID:)` | `PageOrigin?` | **active** version joined to activity+agent (kind/plan/externalRef/runTitle/savedAt). |
| `pageEditHistory(pageID:)` | `[PageOrigin]` | **every** version joined to its PROV agent/activity, `ORDER BY id DESC` (newest-first). ← richest history query. |

`WikiStoreModel` wraps `pageOrigin(for:)` and `pageEditHistory(for:)` (L2796/2804).
`PageOrigin` projects to `ProvenanceEntry` (the UI display model).

### Sources
| Method | Returns | Notes |
|--------|---------|-------|
| `processedMarkdownHead(sourceID:)` | `SourceMarkdownVersion?` | active HEAD (ref or MAX). **Carries `.content`** (full body). |
| `processedMarkdownHistory(sourceID:)` | `[SourceMarkdownVersion]` | all versions newest-first, **each with full `.content`**. |
| `processedMarkdownVersion(id:)` | `SourceMarkdownVersion?` | read one version by smv id — **has full `.content`**. |
| `processedMarkdownAlternatives(sourceID:)` | `[ExtractionAlternative]` | versions + agent name/model/charCount/isActive (the compare-sheet feed). |
| `sourceEditHistory` / `sourceOrigin` (on store) | `[SourceOrigin]` / `SourceOrigin?` | the **raw-bytes** chain provenance (parallel to page's). |

**Walking the chain:** `parent_id` links each version to its predecessor; ULID
ordering makes `MAX(id)` the HEAD. A linear walk from HEAD back is a
`parent_id`-follow; in practice `pageEditHistory`/`processedMarkdownHistory`
materialize the whole list in one query, so you rarely walk link-by-link.

---

## 3. Existing diff view — what's built, what algorithm, what it renders

### Algorithms (all in `Sources/WikiFSMarkdown/`, pure value types, Sendable)
- **`MarkdownDiff.lineDiff(left:right:)` → `[DiffLine]`** (`MarkdownDiff.swift`):
  classic LCS dynamic program over **lines**, with a 4M-cell cap that degrades to
  whole-doc removed/added on huge inputs. Emits `equal`/`added`/`removed` lines,
  removals grouped before additions in each hunk.
- **`SplitDiff`** (`SplitDiff.swift`): turns `[DiffLine]` into a **two-column** model
  — `SplitRow{left?, right?}` with per-side line numbers, plus
  `SplitDiff.elements(from:context:threshold:)` for **collapsible unchanged bands**
  and `hunkAnchors(from:)` for prev/next-change navigation.
- **`Diff3.merge(base:ours:theirs:)`** (`Diff3.swift`): a **three-way merge**
  engine (the workspace-merge algorithm). Not needed for read-only time-travel,
  but available if "merge two branches" is ever wanted.

### UI: `SplitDiffView` (in `ExtractionCompareSheet.swift`, L370–583)
A polished **synchronized two-column line-diff**:
- single shared `ScrollView` (scroll synced by construction)
- per-row line numbers + change gutter (`−`/` `/`+`), red/green tinting + row backgrounds
- collapsible "Show N unchanged lines" bands
- `⌥↑`/`⌥↓` prev/next-change navigation with `N/M` counter
- diff computed **once, off the main thread** (`Task.detached(.userInitiated)`) into
  `@State`, recomputed only when left/right change — never on scroll/hover

**Important wiring detail:** `SplitDiffView` takes raw `left: String` / `right: String`
(+ labels). It is **content-agnostic** — it diffs any two markdown bodies. It is
currently used ONLY by `ExtractionCompareSheet` (source-extraction alternatives).
**It is directly reusable for page-version diffs with zero changes.**

`ExtractionCompareSheet` itself (L59–357) is a full reference implementation for the
*window chrome* around a diff: header, segmented Rendered/Diff toggle, two
`Menu`-based pane pickers (Base ▾ / Compare ▾ with colored dots), an alternatives
list sidebar with Active badges + "Set Active", and a `renderedSplit` that shows two
`WikiReaderView`s side-by-side (the rendered-preview mode). It is opened via a
value-driven `WindowGroup(for: ExtractionCompareContext.self)` (multi-window
resizable, non-modal).

---

## 4. Existing history UI — what's there today vs. what #244 wants

### Today: the "History" tab is an *inspector* sub-tab, not a full browser
- `DetailInspectorView` (`Sources/WikiFS/Detail/DetailInspectorView.swift`): a
  segmented **Outline / History** inspector column (resizable width) shared by
  `PageDetailView` and `SourceDetailView`.
- `InspectorTab` enum: `.outline | .history` — persisted per-caller in `@AppStorage`.
- The History tab renders **`ProvenancePanel`** (`Sources/WikiFS/Detail/ProvenancePanel.swift`):
  a single newest-first timeline of `ProvenanceEntry` (date + operation badge
  `Import`/`Edit` + a "current" checkmark). Clicking a row **navigates to the
  *writer*** — `chat:<id>` → chat tab; `agent:<kind>` → Activity window (NOT to the
  version's content). Right-click → "Copy Date" / "Copy Version ID".
- It is **read-only provenance display**: it does NOT let you view a past version's
  content, diff two versions, or restore.

### Issue #244 is a DIFFERENT feature (navigation history, not content history)
`gh issue view 244` → **"persistent, browsable navigation History (like a browser's)"**.
It asks for a *visit log* (page/source/chat id + kind + timestamp) persisted to
SQLite, grouped by day, searchable — explicitly **"Out of scope: content/version
history (reverting page edits)"**. The current `WikiStoreModel.backStack`/
`forwardStack` are in-memory `[WikiSelection]` capped at 100, lost on relaunch.

> ⚠️ **Naming collision to resolve.** Both the existing inspector tab and issue #244
> use the word "History." This time-travel feature is **content/version history**
> (#244 explicitly excludes it). Recommend naming the new surface **"Versions"**
> to avoid confusing it with #244's browser-history log.

---

## 5. Content retrieval — can we get the full content of any historical version?

### Sources: ✅ YES, fully
`SourceMarkdownVersion.content` is the **fully-resolved body** on every method:
`processedMarkdownHistory`, `processedMarkdownVersion(id:)`, `HEAD`, and
`processedMarkdownAlternatives` all return the real markdown text (blob-decoded).
The `ExtractionCompareSheet` already renders/diffs arbitrary historical versions.

### Pages: ⚠️ ALMOST — read exists, but not as a public method
- The body lives in `blobs.content`, keyed by `page_versions.blob_hash`.
- `revertPage(pageID:to:)` does the join internally:
  `SELECT pv.blob_hash, pv.title, b.content FROM page_versions pv JOIN blobs b …`
  — proving the retrieval is trivial.
- **There is NO public `pageVersionBody(versionID:)` / `pageVersion(versionID:)`.**
  `pageVersionHistory`/`pageEditHistory` return summaries/`PageOrigin` (metadata),
  not the body bytes.

**Gap (small, one method):** add `pageVersionBody(versionID:) throws -> String?`
on the store + a `WikiStoreModel` wrapper. Same `JOIN blobs` pattern as `revertPage`.

SQL for "all versions of page X in chronological order with content":
```sql
SELECT pv.id, pv.parent_id, pv.title, pv.saved_at, b.content,
       act.kind AS activity, a.name AS agent, a.kind AS agent_kind
FROM page_versions pv
JOIN blobs b ON b.hash = pv.blob_hash
LEFT JOIN activities act ON act.id = pv.activity_id
LEFT JOIN agents a ON a.id = act.agent_id
WHERE pv.page_id = ?
ORDER BY pv.id ASC;   -- ASC = oldest-first (DESC for newest-first)
```

### Metadata each page version carries
`saved_at` (timestamp), `title` (the title *as it was* at that version),
`activity_id` → activity kind (`import`/`edit`) + agent name/kind/version + plan +
external_ref + (chat runTitle). No free-text "author" field beyond the agent.

---

## 6. Source markdown version storage — details

(Full schema in §1e.) Retrieval is solved: `processedMarkdownHistory` returns every
version with full content; `processedMarkdownVersion(id:)` reads one.

SQL for "all extraction versions of source X" (what the compare sheet uses):
```sql
SELECT <smvSelectColumns>
FROM source_markdown_versions smv
<smvBlobJoin>
WHERE smv.file_id = ?
ORDER BY smv.id DESC;   -- newest-first
```

### "Coexisting alternatives" (extraction framework #799)
A source can have **multiple extraction versions that are NOT a linear parent→child
chain** — e.g. one from `pdf2md`, one from `anthropic`, one from `gemini`. They all
share `file_id`, each links via `parent_id` to whatever was head when it ran, but
they represent **parallel renditions** of the same source. The `source-derived` ref
nominates which one is currently "active" (`isActive`), and `setActiveMarkdown`
repoints it without deleting the others. `ExtractionCompareSheet` is the UI for
choosing among these. For a *time-travel* view, these alternatives are just "more
rows in the history list" — the diff and restore mechanics are identical.

---

## 7. Snapshot/restore — what exists, what's needed

### Restore to a previous version
| | Store | Model | UI |
|---|---|---|---|
| **Page** `revertPage(pageID:to:)` | ✅ reads target blob → updates `pages` mirror → repoints `page-content` ref. Appends nothing; the ref now points at the old version. | ❌ **NOT wrapped** | ❌ none |
| **Source** `revertProcessedMarkdown(sourceID:to:)` | ✅ appends a NEW row (origin `.revert`, reusing target's blob_hash) → repoints `source-derived` ref | ✅ used in UI | 🟡 `setActiveMarkdown` menu + compare sheet's "Set Active" (effectively restore-via-nominate) |
| **Source** `setActiveMarkdown(sourceID:to:)` | ✅ repoint ref only | ✅ | ✅ source detail menu |

> Note the two models: **pages** revert by repointing the ref to an *existing* old
> version (no new row); **sources** revert by *appending a new `.revert` version row*
> that reuses the target's blob (so the chain stays append-only and the revert is
> itself auditable). Both are correct; they differ in whether a revert is a new node.

### Read-only historical viewing
- **Sources:** fully supported — `processedMarkdownVersion(id:).content` + the
  compare sheet's rendered pane already show old versions read-only.
- **Pages:** NOT supported in UI today — needs the new `pageVersionBody` read +
  a rendered view (reuse `WikiReaderView(markdown:body, store:)`, exactly as the
  compare sheet does).

---

## 8. UI patterns to follow

- **Two-pane diff window:** `ExtractionCompareSheet` + `SplitDiffView` is the
  template — `HSplitView{ alternativesList; content }`, segmented Rendered/Diff
  toggle, `Menu` pickers, `WikiReaderView` for rendered preview. A page-version
  diff can clone this structure almost verbatim.
- **History list:** `ProvenancePanel`'s row style (date + operation badge +
  current-marker) is the established look; extend it with selection + a diff/restore
  affordance rather than restyling.
- **Inspector tab:** `DetailInspectorView`'s segmented Outline/History + resizable
  divider is the shared container. A "Versions" surface could live here OR be its
  own window (the compare sheet precedent favors a dedicated `WindowGroup`).
- **Rendered markdown:** always `WikiReaderView(markdown:body, store:)` — no new
  rendering code anywhere (the compare sheet relies on this).
- **Window scenes:** value-driven `WindowGroup(for: <Context>.self)` pattern
  (`ExtractionCompareContext`) for multi-window, resizable, non-modal surfaces.
- **No 3rd-party diff lib** — `MarkdownDiff`/`SplitDiff`/`Diff3` are all in-tree.

---

## 9. Gap analysis — what's missing for the time-travel History tab

1. **Read arbitrary page-version body** — add `pageVersionBody(versionID:)` (store) +
   `WikiStoreModel` wrapper. ~10 lines (clone `revertPage`'s JOIN as a read). **High value, low effort.**
2. **Page-version diff UI** — `SplitDiffView` is content-agnostic and reusable; build
   a `PageVersionCompareSheet` that mirrors `ExtractionCompareSheet` but feeds it two
   `pageVersionBody` reads instead of `processedMarkdownAlternatives`. **Medium effort (mostly window chrome reuse).**
3. **Version picker + selection in the history list** — `ProvenancePanel` rows today
   are not selectable for diffing. Add selection state + a "Compare…" action (or two-
   pick selection like the compare sheet's Base/Compare menus).
4. **Restore UI for pages** — wire `revertPage` through `WikiStoreModel` (missing!)
   and add a "Restore this version" button/confirmation. **Low effort once #2 lands.**
5. **Historical rendered view (read-only time-travel)** — a `WikiReaderView` bound to
   a chosen version's body (not the live page). Trivial once #1 exists.
6. **(Optional) Naming** — call it "Versions" to avoid collision with #244's
   navigation "History."

Everything below this line is plumbing that **already exists and should be reused**:
version chains, provenance, refs/HEAD, `MarkdownDiff`/`SplitDiff`/`SplitDiffView`,
`WikiReaderView`, the `WindowGroup(for:)` window pattern.

---

## 10. Design sketch (rough architecture)

```
┌─ New: VersionBrowser (a WindowGroup<VersionBrowserContext>, like ExtractionCompareContext)
│   ├─ LEFT: version list (clone ProvenancePanel row style, but selectable)
│   │        • newest-first, date + author badge + "current" marker
│   │        • click → load that version's body into the preview (read-only)
│   │        • ⌘-click two → populate Base/Compare for diff
│   ├─ RIGHT (segmented): [ Rendered | Diff ]
│   │        • Rendered: WikiReaderView(markdown: selectedBody)  [read-only time-travel]
│   │        • Diff:     SplitDiffView(left: baseBody, right: compareBody)  ← reuse as-is
│   └─ FOOTER/toolbar: "Restore this version…" → store.revertPage (after model wrapper)
│
└─ Entry points (context menus / inspector):
    • PageDetailView inspector "History" tab: add "Compare Versions…" + "View" + "Restore"
    • SourceDetailView: the extraction-provenance chip already has Compare — extend to full history
```

Data flow:
```
pageVersionHistory(pageID) → [PageVersionSummary]      (metadata list)
pageVersionBody(versionID) → String                     (NEW — full body)
store.revertPage(pageID, to:) → wrapped on model        (NEW wrapper)
MarkdownDiff.lineDiff(a,b) → SplitDiff.rows → .elements → SplitDiffView   (reuse)
```

---

## 11. Files to touch (likely)

**New files:**
- `Sources/WikiFS/…/VersionBrowserView.swift` (or `PageVersionCompareSheet.swift`) —
  clone of `ExtractionCompareSheet`'s shape, fed by page versions.
- `Sources/WikiFS/…/VersionBrowserContext.swift` — `Codable/Hashable` window-context
  (mirror `ExtractionCompareContext`).
- `Sources/WikiFS/Window/WikiFSApp.swift` — register a `WindowGroup(for:)` (mirror
  the "Compare Extractions" group at L521).

**Edits:**
- `Sources/WikiFSCore/Store/GRDBWikiStore.swift` — add `pageVersionBody(versionID:)`
  (read JOIN from `revertPage`'s pattern); add to `WikiStore` protocol.
- `Sources/WikiFSCore/Store/WikiStoreModel.swift` — add
  `pageVersionBody(for:)`, `revertPage(for:to:)` wrappers (currently absent).
- `Sources/WikiFS/Detail/ProvenancePanel.swift` — add selection + "Compare"/"View"/
  "Restore" actions to the existing history rows.
- `Sources/WikiFS/Detail/DetailInspectorView.swift` — possibly add a 3rd tab or a
  "Versions" disclosure (optional; a dedicated window may be cleaner).
- `Sources/WikiFS/Pages/PageDetailView.swift` — wire entry points (it already loads
  `pageOrigin`/`pageEditHistory` at L168–169).

**Reuse as-is (no edits):**
- `Sources/WikiFSMarkdown/MarkdownDiff.swift`, `SplitDiff.swift`, `Diff3.swift`
- `Sources/WikiFS/Sources/ExtractionCompareSheet.swift` → `SplitDiffView`
  (lift `SplitDiffView` to its own file if you want it shared cleanly — it's
  currently nested in the extraction-compare file).
- `Sources/WikiFS/Reader/WikiReaderView.swift` (rendered preview)
- All store versioning methods (page + source) and the refs/blobs schema.

---

# Implementation plan (#817)

The sections above (§1–§11) are the **research/investigation** output. This
section is the **handoff plan** with explicit acceptance criteria, written
against the plan-review corrections (R1–R9), which supersede any conflicting
text in §1–§11 or the original directive.

## Plan-review decisions (R1–R9, authoritative)

- **R1 — Restore semantics:** the existing `store.revertPage`
  (`GRDBWikiStore.swift:4642`) **repoints the `page-content` ref** to the old
  version and routes through `mutate()` to emit a `ResourceChangeEvent`. It does
  **NOT** append a new `page_versions` row. That shipped behavior is **correct
  and preserved** — do NOT change it to append (the "append on revert" model is
  the *source* side, `revertProcessedMarkdown`; pages use ref-repoint).
- **R2 — `pageVersionBody` is a READ:** implement with `dbWriter.read`
  (mirror `processedMarkdownVersion(id:)`), NOT `mutate()`. Reads emit no
  `ResourceChangeEvent`. No `StoreEmissionExhaustivenessTests` guard exists
  (verified — only referenced in a comment), so nothing to update.
- **R3 — Every new path gets named tests** (see test-to-AC map below).
- **R4 — Pages only.** Sources already have `ExtractionCompareSheet`. Do NOT
  wire source Compare/View/Restore into the new surface. Noted in the PR body.
- **R5 — The VersionBrowserView is NEW ~200 LOC**, not thin reuse. Its own
  version-list sidebar over `PageVersionSummary`, Base/Compare selection,
  Restore action.
- **R6 — `ProvenancePanel` is shared (Page + Source).** Restore/Compare are
  page-specific. Entry to the Versions window is injected as an optional
  closure from the parent detail view (PageDetailView passes it; SourceDetailView
  doesn't) so Restore only ever appears for page versions.
- **R7 — Naming/AppStorage:** do NOT rename `InspectorTab.history` (its rawValue
  is persisted in `@AppStorage`). Use a **dedicated `WindowGroup`** for the
  Versions surface (mirrors "Compare Extractions"); the inspector stays as-is
  plus one optional entry button.
- **R8 — Historical render:** pass the **LIVE** store to `WikiReaderView`
  (`WikiReaderView(markdown: body, store: liveStore)`) so wiki/ghost links
  resolve against current state. The historical version is just the markdown
  string.
- **R9 — Plan shape:** this section (ACs + test map) is the handoff plan; §1–§11
  are cited as research.

## Acceptance criteria + test-to-AC map

| AC | Requirement | Test(s) |
|----|-------------|---------|
| **AC.1** | `pageVersionBody(versionID:)` on `GRDBWikiStore` + `WikiStore` protocol: returns the full blob-decoded body for any `page_versions` row by id; `nil` when not found; uses `dbWriter.read` (no mutate, no emit). | `PageVersionTests.pageVersionBodyReadsFullBodyOfHead`, `.pageVersionBodyReturnsNilForUnknownID`, `.pageVersionBodyReadsArbitraryOldVersion` |
| **AC.2** | `WikiStoreModel.pageVersionBody(for:)` wrapper returns `String?` (swallows errors per the model pattern). | `PageVersionTests.pageVersionBodyModelWrapperReturnsBody` (model-level) |
| **AC.3** | Restore preserves existing semantics: `WikiStoreModel.revertPage(for:to:)` wraps `store.revertPage` AS-IS — repoints ref, **no new version row** (history length unchanged), body restored, emits `ResourceChangeEvent`. | `PageVersionTests.modelRevertPageRepointsRefAndEmits`, `.modelRevertPageDoesNotAppendVersionRow` |
| **AC.4** | A dedicated `WindowGroup(for: PageVersionCompareContext.self)` opens a resizable, non-modal window (mirrors `ExtractionCompareContext`). Entry from `PageDetailView`. | `PageVersionCompareContext` Hashable/Codable round-trip; window resolves the correct wiki session (structural, mirrors ExtractionCompareWindow). |
| **AC.5** | Version list sidebar: page versions newest-first (date + agent badge + current marker), reusing `ProvenancePanel` row styling. Selecting a row loads its body via `pageVersionBody`. | `PageVersionSelectionTests` (pure selection model: default base/compare, current-marker, single-vs-two-pick). |
| **AC.6** | Rendered pane: `WikiReaderView(markdown: selectedBody, store: liveStore)` shows the historical version read-only (time-travel). Live store passed (R8). | Wiring covered by AC.1 (body read) + AC.5 (selection); structural. |
| **AC.7** | Diff pane: `SplitDiffView(left: baseBody, right: compareBody)` reuses the existing diff renderer with **zero changes**; base/compare selected via menus. | `PageVersionSelectionTests.diffFeedsPageVersionBodyIntoSplitDiff` (pageVersionBody → SplitDiff rows). |
| **AC.8** | Restore action: "Restore this version" button + confirmation alert → `WikiStoreModel.revertPage`; list + current marker refresh. | AC.3 covers the model; button wiring structural. |
| **AC.9** | `ProvenancePanel` gains an optional "Compare Versions…" entry (injected closure); appears for pages only, opens the window. | Closure-injection structural (page passes non-nil, source passes nil → button hidden). |
| **AC.10** | User-facing label is "Versions" / "Compare Versions"; `InspectorTab.history` enum case unchanged (R7). | Structural (no AppStorage key change). |
| **AC.11** | `swift build` + full `swift test` green; all store access via `@MainActor WikiStoreModel` + method-atomic `GRDBWikiStore`; no transaction held across I/O. | `swift test` run. |

## Files

**New:**
- `Sources/WikiFS/Pages/PageVersionCompareSheet.swift` — the `PageVersionCompareContext`,
  `PageVersionCompareWindow`, `PageVersionCompareSheet` (the ~200-LOC window;
  mirrors `ExtractionCompareSheet`'s shape, fed by `pageVersionBody`).
- `Tests/WikiFSTests/PageVersionSelectionTests.swift` — pure selection/diff-wiring logic.

**Edits:**
- `Sources/WikiFSCore/Store/WikiStore.swift` — add `pageVersionBody(versionID:)` to the protocol.
- `Sources/WikiFSCore/Store/GRDBWikiStore.swift` — implement `pageVersionBody(versionID:)` (read JOIN).
- `Sources/WikiFSCore/Store/WikiStoreModel.swift` — add `pageVersionBody(for:)` + `revertPage(for:to:)` wrappers.
- `Sources/WikiFS/Detail/ProvenancePanel.swift` — optional `onCompareVersions` closure → entry button.
- `Sources/WikiFS/Detail/DetailInspectorView.swift` — thread the closure through.
- `Sources/WikiFS/Pages/PageDetailView.swift` — wire the entry button → `openWindow(value:)`.
- `Sources/WikiFS/Window/WikiFSApp.swift` — register the `WindowGroup`.
- `Tests/WikiFSTests/PageVersionTests.swift` — extend with AC.1–AC.3 tests.

**Reuse as-is (zero changes):** `MarkdownDiff`/`SplitDiff`/`Diff3`, `SplitDiffView`,
`WikiReaderView`, all existing store versioning methods, the refs/blobs schema.
