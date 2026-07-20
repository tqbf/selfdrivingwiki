# Page Provenance — Scope + Plan

> Status: **investigation + design only.** No repo file is modified; this lives
> under `tmp/` (gitignored). All citations are `file:line` against the working
> tree at the time of writing (store schema v38, `GRDBWikiStore`).
>
> Related: issue #261, PR #310 (design — *not on disk*), PR #486, issues #131 /
> #397 (shipped page-author provenance), `plans/phase-3a-providers-and-provenance.md`
> (shipped source provenance).

---

## 1. What the operator asked for

Each wiki page should carry **provenance metadata** linking it to the ingestion
job(s)/run(s) and chat(s) that **created or edited** it — IDs + timestamps — so a
page's creation/edit history is queryable and surfaceable in the UI.

## 2. Prior-art summary (don't redesign from zero)

There is already substantial provenance machinery in the codebase. The page
feature is a **gap-fill**, not a greenfield.

### 2.1 Issue #261 — *source providers*, not page provenance
#261 (`gh issue view 261`) is titled "New source providers: git@SHA, Tavily,
Slack, archives (graph-model Phase 7)". It is about new `SourceProvider`
leaves, and its "Gate" mentions "frozen, **provenance-carrying** source". It is
**not** about page provenance. Useful only as context for the connections vs.
provenance split (#310).

### 2.2 PR #310 — the snapshot invariant (design doc; NOT merged/on-disk)
#310 adds `plans/connections.md` (452 lines). It establishes the architectural
rule this plan inherits verbatim:

> **Connections are mutable configuration; provenance is immutable history that
> snapshots connection identity at ingest — no foreign key, so deleting a
> connection never touches provenance.**

Its schema sketch puts nullable `connection_id` / `connection_label` on the
`activities` table (snapshotted at ingest). `plans/connections.md` is **not on
disk** (`ls plans/connections.md` → No such file) — the PR is OPEN/unmerged.
So #310 is *direction*, not implemented substrate. This plan is forward-
compatible with it: page activities already live in the same `activities`
table #310 proposes to extend.

### 2.3 PR #486 — per-wiki `connections` table (OPEN)
#486 moves connections into each wiki's SQLite DB as a new `connections` table
(schema v38), with store methods all routed through `mutate()` + emitting
`ResourceChangeEvent`. This is the **connections substrate**. Page provenance
is orthogonal (it records *who wrote the page*, not *where bytes came from*),
but both share the `activities` table and the snapshot-invariant philosophy.

### 2.4 What IS shipped (on-disk) — the existing provenance substrate
- **Source provenance (Phase 3a, shipped 2026-07-05)** — `plans/phase-3a-providers-and-provenance.md`:
  a `SourceProvider` protocol + `SourceProvenance` descriptor threaded into
  `addSource`, seeding real named `agents` + `activities` (carrying
  `plan`/`external_ref`) and binding `external_identity` on `source_versions`.
  Read-side: `sourceOrigin(sourceID:)` joins
  `refs → source_versions → activities → agents`.
- **Page author provenance (#131 / #397, shipped)** — `plans/wikictl-author-provenance.md`:
  `pages.created_by` / `pages.last_edited_by` TEXT columns (#131, migration
  v32→v33), stamped via a `WIKI_AUTHOR` env var injected at spawn time
  (`agent:<kind>` or `chat:<chatID>`) and threaded through
  `wikictl page upsert --author` → `PageUpsert.upsert(author:)`.

### 2.5 The PROV-DM substrate (graph-model Phase 0/1)
Three tables form a W3C-PROV-style graph (DDL at `GRDBWikiStore.swift:2330-2368`):

```
agents      (id, kind, name, version, external_ref)
activities  (id, kind, agent_id→agents, plan, external_ref, started_at, ended_at)
page_versions (id, page_id→pages, parent_id, merge_parent_id,
               blob_hash→blobs, title, activity_id→activities, saved_at)
source_versions (...) — same shape, for sources
refs (kind, owner_id, version_id, generation, updated_at)  -- active-version pointer
```

`page_versions.activity_id` is a **FK into `activities`** — so the graph already
links every versioned page save to an activity + agent. **Pages already have a
provenance chain; it is just under-populated and unread.**

## 3. Current page schema + write paths (verified, `file:line`)

**Production store = `GRDBWikiStore`** (the app, `wikictl`, `wikid` daemon, and
File Provider all instantiate it — `WikiFSEngine/WikiSession.swift:201`,
`wikictl/main.swift:83`, `wikid/WikiDaemon.swift:134`, `StoreBackend.swift:24`).
`SQLiteWikiStore.swift` is **deleted** from disk; the loaded-context references
to it are stale. Schema is at **v38** (`GRDBWikiStore.swift:61`). The
`sqlite-concurrency` SKILL invariants still hold, but the *mechanism* changed:
GRDB `DatabasePool` serializes via its own dispatch queue (no
`NSRecursiveLock`); `mutate(event:_:)` is a savepoint-wrapped write that emits
post-commit (`GRDBWikiStore.swift:356-386`).

### 3.1 The `pages` table (`GRDBWikiStore.swift:2135-2145`)
```sql
CREATE TABLE pages (
    id TEXT PRIMARY KEY, title TEXT NOT NULL, slug TEXT NOT NULL,
    body_markdown TEXT NOT NULL DEFAULT '',
    created_at REAL NOT NULL, updated_at REAL NOT NULL,
    version INTEGER NOT NULL DEFAULT 1,
    created_by TEXT,          -- #131: agent/model name or "chat:<id>" / "agent:<kind>"
    last_edited_by TEXT       -- #131: same
);
```
**This is the only page-level provenance today** — two nullable TEXT columns
holding a *string* (e.g. `"chat:01J…"`). They carry the chat/agent identity but
**not** the run/job timestamp, source IDs, or executor phase, and they are
last-write-wins (no history).

### 3.2 The single write seam: `PageUpsert.upsert` (`Sources/WikiFSCore/Core/PageUpsert.swift:48-123`)
Both the **in-app editor** (`WikiStoreModel`) and **`wikictl page upsert`**
(the path ingestion executors + chats use) call the *same* `PageUpsert.upsert`.
Its private `writePage` (lines 89-123) branches:

| Case | Method called | Stamps activity/page_versions? | `created_by`/`last_edited_by`? |
|---|---|---|---|
| **Create** (new title) | `createPage(title:createdBy:)` (:120) | ✅ seeds root `page_versions` + an `activities` row (kind `'import'`) | ✅ `created_by`=author |
| **Update, CAS on** (`expectedHeadVersionID` given) | `appendPageVersion(...lastEditedBy:)` (:102,:112) | ✅ appends `page_versions` + `activities` (kind `'edit'`) | ✅ `last_edited_by`=author |
| **Update, CAS off** (`expectedHeadVersionID == nil`) | `updatePage(id:title:body:lastEditedBy:)` (:106,:116) | ❌ **stamps nothing** — flat UPDATE only | ✅ `last_edited_by`=author |

The critical gap: **the CAS-off path — which is `wikictl`'s default (it does
not pass `--expect-head`) — records no version/activity at all.** Only the flat
string survives.

### 3.3 The two store mutators
- `createPage(title:createdBy:)` (`GRDBWikiStore.swift:2762-2813`): INSERTs
  `pages`, then seeds a blob + an `activities` row (kind `'import'`,
  **agent = `legacyImportAgentID`**) + a root `page_versions` row + a
  `page-content` ref. Routed through `mutate(event:)` → emits `.page/.created`.
- `appendPageVersion(...)` (`:4057-4131`): CAS check → optional amend
  (autosave coalescing) → blob → `activities` (kind `'edit'`,
  **agent = `legacyImportAgentID`**) → `page_versions` → UPDATE `pages` mirror
  → `page-content` ref. Routed through `mutate(event:)` → emits `.page/.updated`.
- `updatePage(...)` (`:2822-2841`): **flat UPDATE only**, no version/activity.
  Routed through `mutate(event:)` → emits `.page/.updated`. (So the *event*
  fires, but no history row is written.)

### 3.4 The agent asymmetry (the core defect)
Page activities are stamped with `legacyImportAgentID` (`:2519-2531`) — a
**single shared agent** named `"legacy-import"`, created once and reused for
every page create/edit. So even on the CAS path, the activity's `agent_id`
points at an anonymous shared row, **not** the real `chat:<id>` /
`agent:<kind>` identity already living in `last_edited_by`.

By contrast, sources use `ensureAgent(name:kind:version:externalRef:on:)`
(`:5905-5923`) which **dedups a real named agent** on `(name, kind)` — so two
website ingests share one `"website"` agent but distinct activities. Pages
should use the same seam.

### 3.5 Read side (the missing mirror)
`sourceOrigin(sourceID:)` (`:3268-3302`) is the read-side template: it joins
`refs → source_versions → activities → agents` and decodes a `SourceOrigin`
(`agentName`, `activityKind`, `plan`, `externalRef`, `externalIdentity`,
`fetchedAt`). **There is no `pageOrigin(pageID:)` equivalent.**
`pageVersionHistory(pageID:)` (`:4152+`) returns the version chain but does
not join activities/agents.

### 3.6 Frontmatter projection
`PageMarkdownFormat.fileContent(for:)` (`Sources/WikiFSCore/Markdown/PageMarkdownFormat.swift`)
generates the `---` frontmatter served by the File Provider, conditionally
emitting `created_by:` / `last_edited_by:` when present. This is the
file-visible provenance today.

### 3.7 Identifiers available at the write seams
- **chat ID** — already captured as `"chat:<chatID>"` in `last_edited_by`
  (`AgentLauncher.startInteractiveQuery` injects `WIKI_AUTHOR=chat:<chatID>`,
  per `plans/wikictl-author-provenance.md:36-37`). The raw chatID is a ULID in
  the `chats` table (`GRDBWikiStore.swift:2382`).
- **run/job identity** — ingestion runs are identified by **chatULID + run
  timestamp** (the run dir `<Caches>/Self Driving Wiki-agent/<chatULID>/runs/<timestamp>/`,
  `Sources/WikiFSEngine/AgentLauncher.swift:294-299`). There is no first-class
  `run_id`/`job_id` column anywhere today; the run timestamp is the natural
  key, and `activities.started_at` already records it.
- **source IDs** — ULIDs in `sources`; a page cites sources via `source_links`
  (`from_page_id → to_source_id`, `:2219-2232`). So "which sources fed this
  page" is *already queryable* via `source_links` — provenance need not
  duplicate it.
- **executor phase** — the `WIKI_AUTHOR=agent:<kind>` string (`agent:ingest` /
  `agent:lint` / `agent:query`) already encodes it.

## 4. The gap (one paragraph)

Pages record *who last touched them* as a single denormalized string
(`created_by`/`last_edited_by`, #131/#397) and, on the CAS path only, append a
`page_versions` row — but that row's `activity_id` points at a **shared
anonymous "legacy-import" agent**, the **CAS-off path records no history at
all**, and there is **no read-side accessor** to surface any of it. So a page's
"which job/run/chat created or edited me, and when" is only partially captured,
unqueryable as history, and invisible in the UI beyond two frontmatter lines.
The fix is to (a) make page activities point at **real named agents** (reuse
`ensureAgent`), (b) stamp a `page_versions` + activity row on **every** save
(not just CAS), carrying run/chat identity + timestamp, and (c) add a
`pageOrigin(pageID:)` read accessor + UI surface — reusing the exact PROV
substrate sources already use.

## 5. Recommended design

**One sentence:** extend the existing `activities`/`agents`/`page_versions`
PROV graph to pages (it already half-exists), stamp it on **every** write via
the single `PageUpsert` seam, and surface it with a `pageOrigin(pageID:)`
accessor + an inspector row — no new top-level table, minimal schema change.

### 5.1 WHAT to store per page
- **Agent** (reuse `agents`): one row per distinct author identity, deduped on
  `(name, kind)`. `name` = the existing author string
  (`"chat:<chatID>"` / `"agent:<kind>"` / `"user"` / a model id);
  `kind` = `"chat"` / `"agent"` / `"human"` / `"model"`. This is the structured
  upgrade of the flat `created_by` string — same identity, now first-class.
- **Activity** (reuse `activities`): one row per create/edit, carrying
  `kind` (`'import'` on create, `'edit'` on update), `started_at`/`ended_at`
  (== the save timestamp), and optionally `plan` (executor phase / run label)
  + `external_ref` (run dir or chatID). `agent_id` → the real agent above.
- **Version** (reuse `page_versions`): one append-only row per save, FK
  `activity_id` → the activity. The body lives in `blobs` (CAS) — already the
  design.
- **Keep** `created_by`/`last_edited_by` as denormalized fast-path columns
  (unchanged) — they remain the cheap "last actor" mirror; the PROV graph is
  the authoritative history. No data loss, no migration of existing rows
  required (they keep their strings; the graph is populated going forward).
- **sourceLinks are already queryable** via `source_links`; do NOT duplicate
  sourceIDs into provenance. (If a future "this edit was sourced from X"
  link is wanted, that's a `source_links` enhancement, separate scope.)

**Rationale for reusing the graph over a new `page_provenance` table:**
the `page_versions.activity_id → activities → agents` chain already exists and
is the exact PROV-DM model sources use. A parallel table would duplicate the
agent/activity lifecycle, fork the GC/query paths, and contradict #310's
"provenance is the activities graph" framing. The only *new* persistence is
making the existing columns non-NULL-populated with real data.

### 5.2 WHERE — schema change (one migration step, v38 → v39)
**No new table.** `page_versions.activity_id` is already `REFERENCES
activities(id)` and nullable (`GRDBWikiStore.swift:2434`); no column add is
needed. The only DDL delta is the version bump, optionally paired with a data
backfill.

**⚠ Ladder ordering is load-bearing (verified `GRDBWikiStore.swift:1132-1148`).**
The stepwise `migrate(from:in:)` ladder ends with a **catch-all fallback** at
`:1144`:

```swift
if version < Self.currentSchemaVersion {                 // :1144
    try Self.dropFTS5TablesAndTriggers(in: db)           // :1145
    try db.execute(sql: "PRAGMA user_version = \(Self.currentSchemaVersion);")  // :1146
    version = Self.currentSchemaVersion
}
```

The moment `currentSchemaVersion` (`:61`) is bumped 38 → 39, that fallback's
guard becomes true for a v38 DB and it **short-circuits**: it re-runs the FTS5
drop (harmless — `DROP … IF EXISTS`) and stamps `user_version = 39`, executing
**none** of any new provenance backfill. So a new explicit step MUST be
inserted **before** `:1144`, mirroring the v37→v38 step that sits immediately
above it (`:1132-1148`):

```swift
// Step 38 → 39 (page provenance): [backfill, if any — see below].
// MUST precede the catch-all fallback at :1144.
if version < 39 {
    // try Self.migrateV38ToV39(in: db)   // data backfill only — see "Backfill" note
    try db.execute(sql: "PRAGMA user_version = 39;")
    version = 39
}
```

```sql
-- v38 → v39 backfill (OPTIONAL — only if historical attribution is wanted now):
--   (a) seed a real named agent for every distinct non-null created_by/last_edited_by value
--       (dedup on (name, kind) exactly like ensureAgent, :5905-5923), and
--   (b) for pages whose root page_versions.activity_id points at the legacy-import agent
--       (:2519-2531), repoint its activity.agent_id to the real agent derived from created_by.
-- Rows with NULL created_by stay on legacy-import (truly unknown) — degraded gracefully.
```

**Recommendation: forward-only first.** Ship the version bump as a no-op
`PRAGMA user_version = 39` (the explicit `if version < 39` step above, with the
backfill call commented out). The **write-path** change (§5.3) alone guarantees
correctness for all new saves; pre-existing rows degrade to "unknown", exactly
as today. Defer the backfill (and a `wiki_metadata` guard flag, `:1122-1129`)
to Phase C unless the operator wants historical attribution immediately — it is
irreversible and benefits from a guarded rollout.

Add to `createFreshSchema` (no-op for a fresh DB — it already builds v38 = the
target shape) and `migrate(from:)` per the existing ladder convention
(`:1081-1085` shows the v32→v33 step pattern). `currentSchemaVersion` bumps
38 → 39 (`:61`).

> **LOW fix (housekeeping):** while editing this region, the stale doc comment
> at `GRDBWikiStore.swift:412` — `"Both paths end at user_version =
> currentSchemaVersion (37)"` — should be corrected to `(39)` (it already
> drifted from 37→38; don't let it drift again).

### 5.3 HOW stamped — the write seams
**Single principle: every page mutation routes its activity through
`ensureAgent`, and the non-CAS update path must also append a version.**

#### Pre-req: `authorKind(_:)` is NEW code (not reuse)
§5.3 below calls `authorKind(createdBy)`. **That helper does not exist today**
(`rg 'authorKind' Sources` → no hits). It must be **authored** as a small
private helper on `GRDBWikiStore`, e.g.:

```swift
/// Map a provenance author string (#397) to an `agents.kind` value.
/// `chat:<id>` → "chat"; `agent:<kind>` → "agent"; the literal "user" → "human";
/// anything else (a model id like "claude-sonnet-4-5…") → "model".
private func authorKind(_ author: String?) -> String {
    guard let author, !author.isEmpty else { return "software" }   // unknown
    if author.hasPrefix("chat:")  { return "chat" }
    if author.hasPrefix("agent:") { return "agent" }
    if author == "user"           { return "human" }
    return "model"
}
```
The `kind` feeds `ensureAgent(name:kind:on:)` (`:5905-5923`), which dedups on
`(name, kind)` — so `"chat:01J…"` and a stray page titled `chat:01J…` cannot
collapse (distinct `name`s). `nil`/empty authors fall back to the existing
`legacyImportAgentID` path (degraded, same as today).

#### The refactor — extract `appendPageVersionLocked(on db:)` (fixes the HIGH hazard)
Both `updatePage` (`:2823`) and `appendPageVersion` (`:4062`) wrap their bodies
in `mutate(event:)` → emit `.page/.updated`. The `mutate` doc (`:349-355`)
warns `dbWriter.write` is **NOT reentrant** — public methods that compose must
**pass the `Database` handle to an internal helper, never re-enter `mutate`.**
So `updatePage` MUST NOT call the public `appendPageVersion` (that would
double-emit AND re-enter). The fix:

1. **Extract** the version-append logic (steps 2-6 of `appendPageVersion`
   today: blob → `ensureAgent` → `activities` INSERT → `page_versions` INSERT
   → `pages` mirror UPDATE → `page-content` ref) into a private
   `appendPageVersionLocked(pageID:title:body:head:expectedHeadVersionID:
   lastEditedBy:author:now:nowTS: on db:)`. **No `mutate` wrapper, no emit**
   — it takes the open `Database` and performs pure SQL, returning the new
   version id.
2. **`appendPageVersion(...)`** (`:4057`) keeps its `mutate(event:)` wrapper,
   does the CAS head-resolve + amend check inside, then calls
   `appendPageVersionLocked(... on: db)`. Emits `.page/.updated` once.
3. **`updatePage(id:title:body:lastEditedBy:)`** (`:2822`) keeps its own
   `mutate(event:)` wrapper, resolves the head + amendment inside, then calls
   `appendPageVersionLocked(... expectedHeadVersionID: nil, on: db)` — the
   **CAS-off path** = "no CAS check, just append". Emits `.page/.updated`
   **once** (its own wrapper; `appendPageVersionLocked` does not emit).

This is the documented Approach-A composition pattern (`:349-355`): one emit per
public method, the shared work factored into a `db:`-taking helper. The
`ensureAgent` swap (item below) happens **inside** `appendPageVersionLocked`,
so both public paths benefit from one edit.

> *Performance note:* appending a blob + version per save is the existing
> CAS-path cost; the amend-coalescing in `tryAmendPageVersion` (`:4082`)
> already collapses same-actor rapid saves, so the cost is bounded. Gate the
> append on "body hash ≠ head blob hash" (compare SHA to head) to skip
> no-op `wikictl` re-writes.

#### `createPage` + `appendPageVersion` — the `ensureAgent` swap
- **`createPage(title:createdBy:)`** (`:2762`): replace
  `legacyImportAgentID(on:)` (`:2519`) with `ensureAgent(name: createdBy ??
  "unknown", kind: authorKind(createdBy), on:)` for its root `activities` row.
  Optionally bind `plan`/`external_ref` (Phase 2 threading). Keep emitting
  `.page/.created`.
- The shared `appendPageVersionLocked` (above) does the same swap for the edit
  path, so `appendPageVersion` and `updatePage` are covered in one place.

#### ⚠ Create-then-update → TWO version rows on a brand-new page (MEDIUM)
`PageUpsert.writePage` (`PageUpsert.swift:120-122`) on the **create** branch
calls `createPage(...)` **then** `updatePage(...)`. Today that yields **one**
`page_versions` row (create seeds the root; `updatePage` was a flat UPDATE that
wrote none). After this refactor, `updatePage` ALSO appends a version → every
brand-new page gets **TWO** `page_versions` rows (empty root + first real
edit) and **TWO** `activities` rows (`'import'` + `'edit'`).

This is **benign** (the chain is still correct; `pageOrigin` returns the most
recent; `pageEditHistory` shows both), but it must be accounted for in AC.2:

- **AC.2 expected counts** (the create+edit case): `pageEditHistory` returns
  **exactly 2** entries for a fresh page edited once — entry[0] = `kind
  'import'`, empty body; entry[1] = `kind 'edit'`, the real body. The test
  asserts `count == 2` (not `>= 2`) and that the *second* entry's agent +
  body match the chat edit, so it cannot pass trivially off the empty-root
  artifact.
- **Alternative (cleaner, deferred):** give `createPage` an optional `body:`
  parameter so `writePage`'s create branch writes the body in one shot and
  skips the second `updatePage`. This is a larger change to the protocol +
  the root-version seeding; **leave for a follow-up** unless the double-row
  is objectionable. Document the decision either way.

#### Threading richer identity (optional Phase 2)
Today only the `author` string reaches the store. To record the **run dir** /
**executor phase** as structured `activities.plan`, extend the `WIKI_AUTHOR`
injection (`AgentLauncher`) to also set a `WIKI_RUN_REF` env var (the run dir
or `<chatULID>/<timestamp>`, per `AgentLauncher.swift:294-299`), and thread it
as a new optional `runRef: String?` through `PageUpsert.upsert` →
`createPage`/`appendPageVersionLocked` → `activities.external_ref`. Additive; if
omitted, provenance still carries chat/agent identity + timestamp (the core
ask).

### 5.4 HOW read — `pageOrigin`/`pageEditHistory` are new `WikiStore` protocol requirements
`sourceOrigin(sourceID:)` (`WikiStore.swift:240`), `pageVersionHistory(pageID:)`
(`:399`), `appendPageVersion(...)` (`:387`), and `createPage`/`updatePage`
(`:136-138`) are all **protocol requirements with no default implementation** —
`GRDBWikiStore` is the sole concrete conformer (`rg ': WikiStore' Sources` →
only `GRDBWikiStore`; `WikiStoreModel` wraps a store, it does not conform).
Tests use `GRDBWikiStore` in-memory via `TestStoreFactory.inMemory()`, not a
mock conformance.

Add **both** new requirements to the `WikiStore` protocol, exactly as
`sourceOrigin` was added (Phase 3a — bare protocol func, no default, concrete
impl in `GRDBWikiStore`):

```swift
// WikiStore.swift — alongside sourceOrigin (:240) and pageVersionHistory (:399)
func pageOrigin(pageID: PageID) throws -> PageOrigin?
func pageEditHistory(pageID: PageID) throws -> [PageOrigin]
```

- **`pageOrigin(pageID:)`** — joins `refs → page_versions → activities →
  agents` (copy `sourceOrigin`'s shape at `:3268-3302`; swap
  `source_versions`→`page_versions`, `external_identity`/`fetched_at`→
  `saved_at`). Returns a `PageOrigin` struct (`agentName`, `agentKind`,
  `activityKind`, `plan`, `externalRef`, `savedAt`). Uses `dbWriter.read { }`
  (read-only, off-main-safe via `WikiReadPool`). NULLs degrade gracefully.
- **`pageEditHistory(pageID:)`** — walks the whole `page_versions` chain for
  the page joined to `activities`→`agents` (extends `pageVersionHistory`
  `:4152` with the join), newest-first or oldest-first (pick one; document).

**Conformance impact:** because these are new protocol requirements with no
default, the build will fail at every conformer until implemented. Since
`GRDBWikiStore` is the only conformer, that's a single site. If a mock/test
double conforming to `WikiStore` is ever introduced, it must stub both (return
`nil` / `[]`) — note this in the protocol doc comment. **Do not** add a
default-impl protocol extension here: `sourceOrigin` deliberately has none
(the protocol comment at `:240` documents that it's "On the protocol (not only
the concrete read helper) so callers … can route through it"), and matching
that keeps the two read surfaces consistent.

### 5.5 HOW surfaced — UI
- **`PageDetailView`** (`Sources/WikiFS/Pages/PageDetailView.swift:9`): add a
  collapsible "Provenance" / inspector section (a `DisclosureGroup` or an
  `.inspector`-style panel) showing: Created by `<agentName>`
  (`<agentKind>`) on `<createdAt>`; Last edited by `<…>` on `<updatedAt>`;
  and an expandable "Edit history" list (timestamp + actor + activity kind)
  from `pageEditHistory`. For `chat:<id>` agents, render the chatID as a
  `[[chat:…]]`-style link (consistent with the existing `chat:<id>` provenance
  value shape from #397).
- **Frontmatter** (`PageMarkdownFormat`): already emits `created_by`/
  `last_edited_by`; optionally extend with a `provenance:` block or leave as-is
  (the two existing lines already satisfy "file-visible provenance").
- **`wikictl page info`**: add a subcommand (mirror the shipped `source info`
  from Phase 3a) printing `pageOrigin` + edit history — useful for agents/debug.

## 6. Constraints respected

### 6.1 SQLite concurrency (`docs/skills/sqlite-concurrency/SKILL.md`)
- The store is **method-atomic**; in `GRDBWikiStore` that's GRDB's serial
  `DatabasePool` queue, not an `NSRecursiveLock`. New/changed methods keep the
  `mutate(event:_:)` wrapper (`:356`) — the savepoint-nesting, post-commit-emit
  shape. **Do not introduce raw `BEGIN`/`COMMIT`.**
- **Statement lifetime:** GRDB materializes rows (`Row.fetchAll`) — no manual
  `sqlite3_stmt` reset needed (the SKILL's `defer { stmt.reset() }` rule is a
  `SQLiteWikiStore` concern; GRDB handles it). But never let a raw handle cross
  a boundary.
- **No inference/network inside a transaction** — the write commits, then any
  post-commit side effects (embeddings, search) run (see `renameSource` pattern
  at `:3308-3332`). The provenance writes are pure SQL inside the existing
  `mutate` body — fine.
- **Reads off-main:** `pageOrigin`/`pageEditHistory` use `dbWriter.read` →
  safe through `WikiReadPool` (each pooled store is `GRDBWikiStore(readOnlyURL:)`,
  no migrations). Keep the main-store fallback branch.

### 6.2 Change signaling (#129 slice 2a) — and the gap the loaded context overstates
> The invariant *as written* in the project's AGENTS.md / loaded-context note
> claims "`StoreEmissionExhaustivenessTests` enforces the 'every mutator must
> emit' invariant." **That test does not exist.** It is a phantom — the only
> references to "exhaustiveness" are **stale comments**
> (`ChangeTokenContributorTests.swift:18`, `GRDBWikiStore.swift:2614`). The
> invariant is today **unforced except by per-method spies someone hand-wrote.**

**Verified:** the emission test surface is three files —
- `Tests/WikiFSTests/StoreEmissionTests.swift` — **per-method `@Test` spies**
  (`createPageEmitsPageCreated` `:63`, `updatePageEmitsPageUpdated` `:72`,
  `deletePageEmitsPageDeleted` `:83`, …). Each fires one call and asserts
  `events.last?.kind/.change/.id`. There is **no `Mirror`/`reflect`**, no
  enumeration of public mutators, no EMIT/READ/NO-EMIT partition table. It
  catches a *specific* regression in a *specific* method, not the class.
- `Tests/WikiFSTests/StoreEmissionReentrancyTests.swift` and
  `GRDBEmissionReentrancyTests.swift` — assert **single-emit + no deadlock**
  for composed mutations (e.g. `withTransactionMutationEmitsOnceNoDeadlock`).
  These are the realistic enforcement for the *reentrance/double-emit* hazard.

So this plan must **not** rely on an exhaustiveness guard as a safety net. The
plan's mitigation is concrete instead:

1. **No emission-contract change.** `createPage`/`updatePage`/`appendPageVersion`/
   `deletePage` already route through `mutate(event:)` and emit
   (`.page/.created|updated|deleted`). This plan **modifies their bodies, not
   their wrappers** — the per-method spies keep passing.
2. **The real hazard is double-emit** from the §5.3 refactor (`updatePage`
   sharing logic with `appendPageVersion`). That is closed *structurally* —
   `appendPageVersionLocked` takes the `Database` and does NOT wrap `mutate`
   (`:349-355` reentrance rule) — and asserted by a **new named test**
   (AC.6, see §8).
3. **If a NEW public mutator is added** (e.g. a `repointPageProvenance`
   backfill), it MUST call `mutate(...)` + `localEvent(...)` or carry a
   `// NO-EMIT:` comment with a reason. Because there is no exhaustiveness
   test, this is **review-enforced**, not CI-enforced — add it to the PR
   checklist.
4. The provenance read accessors (`pageOrigin`, `pageEditHistory`) are
   READ-only → no emit.

**Tests to touch (all real):**
- **`StoreEmissionTests.swift`** — extend `updatePageEmitsPageUpdated` (`:72`)
  to assert **exactly one** event after the refactor (`events.count` == the
  recorder's pre-update count + 1; not just `events.last`), and confirm
  `createPageEmitsPageCreated` (`:63`) still single-emits. (See AC.6.)
- **`StoreEmissionReentrancyTests.swift`** — add a case asserting `updatePage`
  emits exactly once after it starts composing via `appendPageVersionLocked`
  (it now resembles `appendPageVersion`'s composition shape). This is the
  realistic double-emit guard. (See AC.7.)

> **Risk to flag:** because no test enumerates `WikiStore`'s public mutators,
> a *future* contributor adding a non-emitting mutator will NOT trip CI — the
> File Provider would silently go stale. Option (a) below closes that gap
> permanently; option (b) is the pragmatic minimum for *this* plan.
>
> **(a) Build the missing exhaustiveness test (recommended follow-up, out of
> scope here but tracked):** a reflection-based `WikiStoreEmissionExhaustiveness
> Tests` that enumerates `WikiStore`'s public mutating `func`s via `Mirror`,
> asserts each is classified EMIT / READ / NO-EMIT in a table, and that every
> EMIT member's body contains a `mutate(` call. Own AC + fixtures. This is the
> test the loaded context *thinks* already exists. (Also: delete the stale
> `StoreEmissionExhaustivenessTests` comment at `ChangeTokenContributorTests
> .swift:18` and the `contributor-exhaustiveness` wording at
> `GRDBWikiStore.swift:2614` — or repoint them at the new real test.)

### 6.3 GRDB, not SQLiteWikiStore
All file:line citations and edits target `GRDBWikiStore.swift`. The
`SQLiteWikiStore` references in the loaded context / SKILL are historical; that
file is gone. The schema-version constant lives only at
`GRDBWikiStore.swift:61`.

## 7. Risks

| Risk | Mitigation |
|---|---|
| **(CRITICAL gap)** No exhaustiveness test guards "every mutator emits" — a future non-emitting mutator silently stale the File Provider. Loaded context overstates this as enforced. | Plan does NOT rely on it. The §5.3 refactor closes *this* plan's hazard structurally (`appendPageVersionLocked` doesn't emit; one emit per public wrapper). Track building the missing `WikiStoreEmissionExhaustivenessTests` (§6.2 option a) as a follow-up; meanwhile review-enforce. |
| **(HIGH)** `updatePage` sharing logic with `appendPageVersion` → double-emit + re-entrant `mutate` deadlock. | Resolved structurally in §5.3: extract `appendPageVersionLocked(on db:)` (no `mutate` wrapper); both public methods call it *inside their own* `mutate` body. `updatePage` MUST NOT call the public `appendPageVersion`. Asserted by AC.6 (`updatePageEmitsPageUpdated` extended to exactly-one) + AC.7 (reentrancy test). |
| **(MEDIUM)** Create-then-update (`PageUpsert.writePage:120-122`) yields TWO `page_versions`/`activities` rows on every brand-new page (empty root + first edit). | Documented in §5.3; AC.2 asserts `count == 2` (not `>= 2`) and pins entry[1]'s agent/body so it can't pass off the artifact. Optional follow-up: `createPage(body:)` to write in one shot. |
| `updatePage` now appends a version on every `wikictl` edit → version-table bloat / slower saves | Gate append on "body hash ≠ head blob hash"; rely on `tryAmendPageVersion` coalescing (`:4082`). Measure with `PageVersionTests`. |
| **(MEDIUM)** v38→v39 step silently skipped by the catch-all fallback if inserted after `:1144`. | §5.2 spells it out: insert the explicit `if version < 39` step **before** `:1144`; the fallback's guard is keyed to `currentSchemaVersion` and short-circuits past it once bumped. |
| **(MEDIUM)** New protocol requirements `pageOrigin`/`pageEditHistory` break every `WikiStore` conformer until implemented. | §5.4: `GRDBWikiStore` is the sole conformer (single site); no default-impl extension (matches `sourceOrigin`). Document in the protocol comment; any future mock must stub `nil`/`[]`. |
| Backfill (5.2) repoints historical `activity.agent_id` — irreversible if wrong | Forward-only first (no-op v39 bump); defer backfill to Phase C behind a `wiki_metadata` flag (`:1122-1129`); keep `created_by` strings as source of truth. |
| `ensureAgent` dedup on `(name,kind)` could collide if two chats share a name-shaped string | Names are already ULID-suffixed (`chat:<ULID>`, `agent:<kind>`) — collision-free by construction. |
| Forward-compat with #310 (`connection_id`/`connection_label` on `activities`) | Additive — those columns don't exist yet; when #310 lands it ALTERs `activities`, independent of this. Page activities coexist. |
| `PageDetailView` is a hot view — a new inspector section could add re-render cost | Use the `swiftui-performance-audit` skill; keep the provenance read in a `@State` loaded on appear / via the read pool, not inline in the view body. |

## 8. Acceptance criteria

1. After an **ingestion executor** creates a page via `wikictl page upsert`,
   `pageOrigin(pageID:)` returns a non-nil `PageOrigin` whose `agentName` ==
   `"agent:<kind>"` (or `"chat:<id>"`), `activityKind` == `"import"`,
   `savedAt` ≈ now.
2. After a **chat** edits a page, `pageOrigin` reflects the chat agent +
   `activityKind == "edit"`. `pageEditHistory` returns **exactly 2** entries
   for a freshly-created-then-edited page (the empty-root `'import'` +
   the `'edit'`), and the test **pins entry[1]** (the edit) to the chat agent
   + the edited body — so it cannot pass trivially off the create-double-row
   artifact (§5.3). *(If `createPage(body:)` is adopted to avoid the
   double-row, adjust to `count == 1` for create-with-body.)*
3. The **CAS-off** path (`updatePage` with no `expectedHeadVersionID`) now
   appends a `page_versions` + `activities` row (verified by row count before/
   after) — closing the "records nothing" hole. Asserted by a row-count check
   in `PageVersionTests`.
4. Page activities' `agent_id` resolves via `ensureAgent` to a **real named
   agent** (not the shared `legacy-import`) when `created_by`/`last_edited_by`
   is non-null; NULL authors degrade to `legacy-import`/`"unknown"` (no crash,
   no data loss).
5. `PageDetailView` shows created-by / last-edited-by / edit history; a
   `chat:<id>` value renders as a chat link.
6. **(double-emit guard)** New test
   `test_updatePage_after_versioning_refactor_emits_single_page_updated` in
   `StoreEmissionTests.swift`: call `updatePage` once on an existing page,
   assert `Recorder.count == before + 1` and the event == `(.page, id,
   .updated)`. Extend the existing `updatePageEmitsPageUpdated` (`:72`) to
   assert **exactly one** event (not just `events.last`), and confirm
   `createPageEmitsPageCreated` (`:63`) still single-emits. *This test would
   FAIL today if `updatePage` naively delegated to public `appendPageVersion`
   (double-emit) — that's the regression it catches.*
7. **(reentrance guard)** `StoreEmissionReentrancyTests` gains a case:
   `updatePage` (now composing via `appendPageVersionLocked`) emits exactly
   once with no deadlock — mirrors the existing
   `withTransactionMutationEmitsOnceNoDeadlock`. This is the realistic
   enforcement for the composition hazard (the phantom "exhaustiveness" test
   does not exist — see §6.2).
8. Migration v38→v39: the explicit `if version < 39` step is inserted
   **before** the catch-all fallback at `GRDBWikiStore.swift:1144`; a v38 DB
   runs it (not the fallback); re-opening a v39 DB is a no-op; a fresh DB
   gets the v39 shape via `createFreshSchema`. The stale `(37)` doc comment
   at `:412` is corrected.

## 9. Build / test commands

> Do **NOT** use bare `swift build` — it fails in fresh worktrees because
> `GeneratedPrompts.swift` / `GeneratedVersion.swift` are gitignored derived
> artifacts. Use the `make` targets that regenerate them first.

```bash
make version prompts    # regenerate git/build derived sources (CI runs this)
make build              # == make version prompts && swift build
make check              # build + lint/quick checks
make test               # full suite (~1.5 min, in-memory SQLite fixtures since #658)

# Targeted:
swift test --filter StoreEmissionTests          # AC.6: updatePage single-emit
swift test --filter StoreEmissionReentrancyTests # AC.7: composition/no-deadlock
swift test --filter PageVersionTests             # AC.3: CAS-off appends a version
swift test --filter SourceProviderTests          # the pattern this mirrors
swift test --filter StoreConcurrencyTests
```

## 10. Suggested phasing

- **Phase A (core, no backfill):** author `authorKind(_:)`; extract
  `appendPageVersionLocked(on db:)`; swap `legacyImportAgentID` → `ensureAgent`
  in `createPage` + the locked helper; route `updatePage` (CAS-off) through the
  helper; add `pageOrigin`/`pageEditHistory` protocol reqs + `GRDBWikiStore`
  impls; bump to v39 (no-op structural, explicit step before `:1144`); fix the
  stale `(37)` comment at `:412`. Tests: AC.3, AC.6, AC.7, AC.8.
- **Phase B (UI):** `PageDetailView` provenance section; `wikictl page info`.
- **Phase C (optional):** thread `WIKI_RUN_REF` → `activities.external_ref`;
  historical backfill behind a `wiki_metadata` flag (guarded, irreversible).
- **Phase D (hygiene + forward-compat):** build the missing reflection-based
  `WikiStoreEmissionExhaustivenessTests` (§6.2 option a) and delete the stale
  phantom refs at `ChangeTokenContributorTests.swift:18` /
  `GRDBWikiStore.swift:2614`; when #310 lands, ensure page activities snapshot
  `connection_id`/`connection_label` if a connection sourced the page.

---

*Plan path: `tmp/sdw-plans/page-provenance.md` (gitignored scratch).*
