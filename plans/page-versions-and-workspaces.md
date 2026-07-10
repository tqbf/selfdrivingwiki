# Page versions & workspaces — multi-writer without a global lock

**Status:** proposed (2026-07-09); **revised 2026-07-09** after adversarial
review (`page-versions-and-workspaces-review.md` — all three blocking
findings accepted and resolved, see §8). Builds directly on
`graph-model-and-versioning.md` (the objects/blobs/PROV substrate this plan
extends to pages). Related but *not* a continuation:
`extraction-vs-ingestion-lock.md` is a narrow UI-state split that leaves
`isAgentRunning` intact; this plan is the layer that retires that lock.
Executes [#258](https://github.com/tqbf/selfdrivingwiki/issues/258) (page
versioning) as its Phase W0.

**The organizing idea:** there are two "global locks" in this system and they
have opposite characters. The SQLite WAL write lock is global but held for
*milliseconds* — it is not the problem and every design below funnels through
it happily. The application-level agent edit lock (`isAgentRunning`,
`WikiStoreModel.swift:203`) is held for the *minutes* an ingestion runs, and
exists for exactly one reason: an ingestion is a long-running logical
transaction with no isolation mechanism, so the app protects consistency by
locking everyone out. This plan removes that lock in two stages:

1. **Now:** per-page CAS (W0) makes the last-writer-wins race — the lock's one
   stated reason — structurally impossible, and per-page *advisory* locks (W1)
   shrink the frozen-editor UX from "whole wiki" to "the pages the agent is
   actually rewriting."
2. **When concurrency is real:** durable, named **workspaces** over the
   append-only version substrate give long-running writers true isolation, so
   the only exclusive section left is a short merge commit. MVCC and git
   branches are not two options here; on a storage model that is already
   immutable blobs + append-only versions + mutable pointers, **a branch is
   MVCC with the speculative state made durable and addressable.**

The workspace/merge phases (W2–W5) are fully designed below — including the
fixes the adversarial review forced — but **evidence-gated** (§9): they are
built when concurrent ingestions or reviewable-ingestion review are actually
wanted, not preemptively.

---

## 1. Prior art (why this shape, recorded so it isn't relitigated)

Every element below has a named ancestor with documented failure modes.
What we are building is precisely: *Postgres snapshot-isolation semantics with
git's merge instead of Postgres's abort-and-retry, an Oracle-Workspace-Manager
workspace lifecycle, CouchDB's conflict-as-durable-state, and an LLM as the
conflict handler.* Only the last part is novel.

| Design element | Ancestor |
|---|---|
| Per-page CAS on a head pointer | Optimistic concurrency control (Kung & Robinson 1981); git atomic ref update; HTTP ETag/`If-Match` |
| Read freely, validate write set at short commit; first-committer-wins | Snapshot isolation — Postgres `REPEATABLE READ` |
| Accepted write-skew anomaly | The canonical SI anomaly; SSI (Ports & Grittner, Postgres `SERIALIZABLE`) is the *rejected* alternative — its read-set tracking cost buys nothing for wiki prose with no cross-page invariants |
| Durable workspaces for long-lived writers; refresh-before-merge; conflicts materialized as data | 1980s CAD "long transactions" (check-out/check-in); **Oracle Workspace Manager** (`MergeWorkspace`/`RefreshWorkspace`, conflict tables) |
| Branch + type-aware three-way merge over structured data | **Dolt** (cell-wise merge), git diff3; **Fossil** is the existence proof that git semantics on SQLite is not a research project |
| Serialized, dumb, fast commit point | Datomic transactor; FoundationDB resolver; merge queues (bors) |
| Conflict as first-class persistent state, resolution is an ordinary later write | **CouchDB** revision trees |
| Hot-page escape hatch (commutative ops, set-union merge) | Escrow transactions (O'Neil 1986) |
| Op-log/replay alternative (not taken) | Bayou (1995) merge procedures — filed as a future refinement if textual merge quality disappoints |

**The one hard constraint prior art adds:** the merge queue must never wait on
the merge *agent*. Fast-forward and clean textual merges happen inline in the
commit transaction; anything needing an LLM is **parked** as a conflicted
workspace and re-enters the queue when resolved. Otherwise one gnarly conflict
head-of-line-blocks every ingestion behind a minutes-long LLM call — the
global lock rebuilt one layer up.

## 2. Current state (grounded, v28 tree)

- `pages` is `(id, title, slug, body_markdown, created_at, updated_at,
  version)` with `pages_slug_unique` (`SQLiteWikiStore.swift:221`). The body
  is **mutated in place** by `updatePage(id:title:body:)`
  (`SQLiteWikiStore.swift:2223`); the `version` counter increments but is
  never checked — there is no CAS, no history, no conflict detection. The
  doc-comment on the edit lock names the consequence: it exists so "in-app
  edits can't clobber the agent's `wikictl` writes (last-writer-wins race)"
  (`WikiStoreModel.swift:203`).
- The edit lock is `isAgentRunning`, set via `beginAgentRun`/`endAgentRun`
  (single mutation point, `WikiStoreModel.swift:1269`). While true: the
  editor goes read-only with a banner, autosave pauses, Edit/Save disable
  (`PageDetailView.swift:40–89`), and reload paths guard
  (`WikiStoreModel.swift:997`, `:1197`). The spawn slot in
  `AgentLauncher.swift` serializes all `claude -p` runs; a separate
  extraction slot is planned (`extraction-vs-ingestion-lock.md`), not yet
  implemented.
- The objects substrate from graph-model Phases 1–2 is live: content-addressed
  `blobs`, append-only `source_versions` / `source_markdown_versions`, PROV
  `agents`/`activities`, and the mutable `refs` table
  (`SQLiteWikiStore.swift:585`). **Load-bearing constraint the first draft of
  this plan missed:** `refs.owner_id` carries
  `REFERENCES sources(id) ON DELETE CASCADE` (`:587`) and
  `PRAGMA foreign_keys=ON` is set at open (`:177`) — `refs` is structurally
  *source-owned*; a page id cannot be an owner. Likewise
  `page_versions.page_id` (§4.1) will FK to `pages(id)`, so no version row
  can exist for a page with no `pages` row. Both facts shape §4.
- **The no-inference-in-transaction rule** is documented and load-bearing:
  "MLX inference must never run under an open write transaction — it would
  stall `wikictl`" (`SQLiteWikiStore.swift:3822`); `renameSource` runs
  embedding + FTS side effects *after* commit. Any merge protocol must mirror
  this shape.
- The changeToken is assembled from registered `ChangeTokenContributor`s
  (`SQLiteWikiStore.swift:1933`); the current 11-field literal is enforced
  byte-for-byte by 21 hardcoded assertions (5 `LogIndexTests`,
  14 `SQLiteWikiStoreTests`, 2 `SystemPromptTests`). One fold is
  `COALESCE(SUM(generation),0)` over **all** of `refs` (`:2038`) —
  speculative writes must not land in folded tables or the File Provider
  token moves on uncommitted work.
- `wiki_index` is a **singleton table**, not a page (`SQLiteWikiStore.swift:348`)
  — the curated index the agent rewrites on every ingest. It is the guaranteed
  merge hot spot, but being a separate table it can carry its own merge rule
  without touching the page machinery.
- Links are ULID-canonical at rest (Phase 5, shipped); `page_links` /
  `source_links` / FTS / embeddings are all deterministic functions of page
  bodies — re-derivable, never merged.
- Schema ladder head is **v28** (`SQLiteWikiStore.swift:519`); v24 is a
  reserved, never-stamped slot (precedent for holes). Next step: **v29**.
- Cross-process: `wikictl` (PageCommand etc. in `WikiCtlCore`) is a genuine
  second writer over WAL + `busy_timeout`; the File Provider extension is a
  reader. Any CAS discipline must therefore live in SQL
  (`UPDATE … WHERE`-guarded), not in an in-process lock.

## 3. Decisions

| # | Decision | Rationale |
|---|----------|-----------|
| D1 | **Pages join the object model**: append-only `page_versions`; a page save = append version + CAS commit. Title lives on the version row, so CAS covers renames too | The prerequisite for everything; executes #258. CAS in one sentence: "commit B whose parent is A, guarded on the head still being A; if it moved, conflict" |
| D2 | **`pages.body_markdown` stays, as the materialized main head** (denorm mirror, same flagged discipline as `sources.byte_size` in graph-model §9) | FTS, embeddings, FP projection, UI, and search keep reading the `pages` row unmodified — MVCC lands with **zero read-path migration**. Every main commit updates row + version + head pointer atomically in one `withTransaction` |
| D3 | **Isolation level: snapshot-ish, read-latest + recorded read set, write-set validation at commit, first-committer-wins.** Write skew consciously accepted | Wiki prose has no cross-page invariants, so SI anomalies are harmless by construction; the read set lands in PROV as `used` relations (audit trail, future "cites since-changed content" lint). SSI-style read validation is the named, rejected alternative |
| D4 | **Humans commit to main; agents get workspaces** (once W2+ exist) | A human save is milliseconds — direct CAS, with CAS failure surfacing as a "page changed underneath you" affordance. Humans never think about branches to fix a typo. |
| D5 | **Workspaces are durable rows** (`workspaces` table: ULID, status lifecycle `open → merging → merged \| conflicted \| abandoned`, PROV activity) | Durable speculation = crash recovery, observability (watch the agent work), and **reviewable ingestions** (a workspace is a diff against main inspectable before it lands — PR review for the wiki) |
| D6 | **Main's head pointer is `pages.head_version_id`, CAS'd via the existing `pages.version` counter — the `refs` table is untouched** *(revised: review B1)* | `refs.owner_id` is FK-locked to `sources(id)` (§2); adding a page kind means a table rebuild that loses the source-delete cascade. Instead the head pointer rides the same `UPDATE` that maintains the D2 mirror: no new table, no refs rebuild, no new token contributor. **Flagged deviation** from graph-model A2's "all pointers in refs" — justified because `refs` is structurally source-owned, with the §9-deviation precedent. Also kills a latent bug: the inherited "head = `MAX(id)`" default-active rule breaks the moment workspaces append version rows for existing pages; an explicit head pointer makes main's head unambiguous regardless of speculative appends |
| D7 | **Overlay reads**: in workspace W, resolve W's entry if present, else main. `wikictl --workspace <id>` / `WIKI_WORKSPACE` env selects the namespace; the agent toolchain works unmodified | Union-mount semantics; no snapshot-at-start (that would require a head-pointer journal — rejected, D3 records reads instead). **Named consequence:** main-reads are a moving target — an agent's *reasoning* can be stale by merge time, a semantic conflict diff3 structurally cannot see. Accepted; provenance records what was read |
| D8 | **Merge ladder**: fast-forward → three-way textual merge (diff3 against recorded base) → **park conflicted** → agent/human resolution as a later ordinary write | The queue stays dumb and fast (Datomic-transactor discipline); LLM resolution happens *outside* the commit path (CouchDB conflict-as-state) |
| D9 | **Merged versions get two-parent lineage**: `page_versions.merge_parent_id` | A merge is a real PROV activity whose output `wasDerivedFrom` both parents; two parents suffice (no octopus merges) |
| D10 | **Derived data is regenerated at merge, never merged** — with **inference precomputed *before* the merge transaction** *(revised: review B3)*: embeddings for anticipated merged bodies are computed pre-transaction and only the vectors are persisted inside it; links/FTS regenerate inside (pure SQL); the log is append-only; the ingest-completion log entry is written by the *merge*, not the run | Deterministic functions of bodies; merging them would be merging a cache. The no-inference-in-transaction rule (§2) is documented and load-bearing — the merge mirrors `renameSource`'s post-commit/pre-compute shape |
| D11 | **Sources stay on main, even during workspace ingestion** | Source chains are append-only + content-addressed — concurrent ingestions cannot conflict on them. A source from an abandoned workspace is just an un-cited source (vacuumable). Keeps the overlay page-only and small |
| D12 | **`wiki_index` merges structurally, not textually**: it is semantically a link set — merge = three-way *line-set* union (added/removed lines vs base), parking only on same-line edits | Escrow-transaction reasoning applied to the one guaranteed hot spot. This *reduces* index conflicts to same-line collisions (e.g. two topic-overlapping ingestions editing one entry); it does not eliminate them |
| D13 | **Slug collisions are a first-class merge case, resolved entirely at merge** *(revised: reviews B2+H3)*: workspace-created pages never touch `pages` pre-merge (D16), so two workspaces creating the same title cannot collide at write time. At merge, if the slug exists on main: the main page's ULID survives; the workspace body is rewritten `[[page:<loser>|…]]` → `[[page:<winner>|…]]` — **minting a new blob, before diff3 runs** (otherwise every link line is a phantom conflict) — then three-way-merged against the main page (empty base if main's page predates the workspace) | `pages_slug_unique` makes silent duplicates impossible — good; the merge must handle collision as a reviewable case, not crash on it mid-ingestion |
| D14 | **Autosave coalesces into the head version** (git-commit-`--amend` style): a save whose parent is the current head, by the same actor/activity, within a debounce window, *replaces* the head version's blob pointer instead of appending. **Guard** *(added: review H1)*: never amend a version that any `workspace_refs.base_version_id` or `workspace_refs.version_id` references, or that has children — amend only true, unreferenced heads | Without coalescing, debounced autosave mints a version row every few seconds and the chain is noise (this is what answers graph-model §4.6's "blobs per keystroke" objection). Without the guard, amending rewrites a live workspace's merge base underneath an in-flight merge |
| D15 | **The edit lock retires; the spawn slot becomes a throttle** | Per-page CAS (W0) removes the lock's stated reason (`WikiStoreModel.swift:203`); per-page advisory locks (W1, D16a) replace its UX role. The spawn slot stops being a correctness serializer and becomes "at most N concurrent claude processes" |
| D16 | **Workspace-created pages stay entirely in workspace-land until merge** *(added: review B2)*: `workspace_refs` carries nullable `title` + `blob_hash`; for a page with no `pages` row, `version_id` is NULL and the head is the blob. The merge mints the `pages` row and a single root version from the final blob | `page_versions.page_id` FKs to `pages(id)` — a version row cannot precede its page. Creating the `pages` row early would move the token, expose the draft to the FP, and fire `pages_slug_unique` mid-ingestion (defeating D13). Intermediate agent drafts of a *new* page are not history worth keeping (D14's spirit) |
| D16a | **Per-page advisory locks (W1)**: during an agent run, pages the run has written become read-only in the editor (per-page banner); everything else stays editable. State is in-app only (`WikiStoreModel`, fed by the existing wikictl-write change events), cleared at `endAgentRun` — no DB state, no lease reaping (crash ⇒ run ends ⇒ cleared) | Captures most of the frozen-editor pain at a fraction of the workspace machinery. The lock is *UX*; W0's CAS is the correctness backstop — a human already mid-edit when the agent touches the page simply gets the conflict affordance on save |
| D17 | **Merge is all-or-nothing per workspace** *(decided: review H2)*: one conflicting page parks the entire workspace; clean pages do not land incrementally | An ingestion is semantically one change-set: landing 43 pages whose bodies link to 7 unmerged ones creates dangling `[[page:ULID]]` references on main — worse than merge latency. **Named consequence:** a large ingestion's merge latency is gated by its worst page. Partial-land is a W4+ refinement *if* evidence shows this hurts |

## 4. Schema

Additive; follows the stepwise ladder discipline (fresh-path parity enforced
by `freshFastPathMatchesStepwiseLadder`).

### 4.1 `page_versions` + `pages.head_version_id` (v29 — Phase W0)

```sql
CREATE TABLE page_versions (
    id               TEXT PRIMARY KEY,   -- ULID; chain order = ULID order
    page_id          TEXT NOT NULL REFERENCES pages(id) ON DELETE CASCADE,
    parent_id        TEXT,               -- wasDerivedFrom; NULL = root
    merge_parent_id  TEXT,               -- second parent; non-NULL = merge commit (D9)
    blob_hash        TEXT NOT NULL REFERENCES blobs(hash),
    title            TEXT NOT NULL,      -- title at this version (rename history)
    activity_id      TEXT REFERENCES activities(id),  -- wasGeneratedBy
    saved_at         REAL NOT NULL
);
CREATE INDEX page_versions_page ON page_versions(page_id, id);

ALTER TABLE pages ADD COLUMN head_version_id TEXT;  -- D6; NOT NULL after seeding
```

- Bodies go through `blobs` at *save* granularity (D14's coalescing + amend
  guard is what makes this honest against graph-model §4.6's warning).
  Page bodies rarely dedup; the append-only chain, not dedup, is what's
  being bought.
- **Head resolution is `pages.head_version_id`, always** — never `MAX(id)`
  (D6 records why the sources default-active rule must not be inherited).
- `refs` is untouched: no rebuild, no lost cascade, no new kind, no token
  fold movement (§5).
- Migration (v29, one `withTransaction`): create table; add column; per page
  `INSERT OR IGNORE` blob of current body → insert root version
  (`parent_id NULL`, `title` = current, `saved_at = updated_at`) → set
  `head_version_id`. `pages.version` counters are untouched, so the token is
  byte-identical across the migration (verified against the 21 literal
  assertions in the same commit).

### 4.2 `workspaces` + `workspace_refs` (v30 — Phase W2, evidence-gated)

```sql
CREATE TABLE workspaces (
    id                 TEXT PRIMARY KEY,     -- ULID
    name               TEXT,                 -- human label ("ingest: foo.pdf")
    status             TEXT NOT NULL DEFAULT 'open',
                       -- 'open' | 'merging' | 'merged' | 'conflicted' | 'abandoned'
    activity_id        TEXT REFERENCES activities(id),  -- the ingestion activity
    index_body         TEXT,                 -- wiki_index draft (singleton, not a versioned owner)
    index_base_version INTEGER,              -- wiki_index.version observed at first index write
    created_at         REAL NOT NULL,
    updated_at         REAL NOT NULL
);

CREATE TABLE workspace_refs (
    workspace_id    TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
    owner_id        TEXT NOT NULL,        -- pages.id, OR a pre-allocated ULID for a page created in-workspace
    base_version_id TEXT,                 -- main head at first write (merge base + CAS expectation); NULL = created here
    version_id      TEXT,                 -- workspace head (page_versions.id) — NULL for created pages (D16)
    blob_hash       TEXT REFERENCES blobs(hash),  -- head body for created pages (D16); NULL otherwise
    title           TEXT,                 -- title for created pages (D16); NULL otherwise
    updated_at      REAL NOT NULL,
    PRIMARY KEY (workspace_id, owner_id)
);
```

- **Existing pages**: workspace writes append real `page_versions` rows (the
  FK is satisfied) and repoint `version_id`; `base_version_id` recorded at
  first touch is the diff3 base and CAS expectation. These speculative rows
  never affect main's head (D6 — explicit pointer, not `MAX(id)`).
- **Created pages** (D16): no `pages` row, no `page_versions` rows —
  `version_id` NULL, head is `blob_hash`, `title` carried alongside. The
  merge mints the `pages` row + root version (or unifies on slug collision,
  D13).
- The *read* set (pages read but not written) is PROV `used` rows on the
  ingestion activity (D3) — provenance, not validation input.
- `wiki_index` staging is two columns on `workspaces` — it is a singleton,
  not a versioned owner; merge applies the D12 line-set rule against
  `index_base_version`.
- Neither table feeds any changeToken fold (§5); `workspace_refs` cascades
  on workspace delete.

**Abandonment & GC** *(specified: review M3)*: `abandon` deletes the
workspace row (cascading its refs). Reclamation, lazy, alongside
`vacuum-blobs` in `vacuum-all`:

- *Orphan speculative versions*: `page_versions` rows that are (a) not an
  ancestor of any `pages.head_version_id` (walk `parent_id`/`merge_parent_id`
  from every head), and (b) not referenced by any `workspace_refs.version_id`
  or `.base_version_id` — delete (`vacuum-page-versions`).
- *Blobs*: `vacuumBlobs` gains two reference sources —
  `page_versions.blob_hash` and `workspace_refs.blob_hash`.
- *Sources added by an abandoned run* (D11): remain as ordinary un-cited
  sources; the existing orphan-sources query surfaces them for optional
  cleanup. No automatic delete — they may be legitimately re-cited later.

### 4.3 The commit protocols

**Human save to main** (W0, replaces blind `updatePage`):

```
withTransaction:
  guard pages.version == the version counter the editor loaded   -- CAS; else PageConflictError
  INSERT blob (OR IGNORE); INSERT page_versions (parent = head_version_id)
      -- or amend the head version's blob pointer per D14 (guard included)
  UPDATE pages SET body_markdown, title, updated_at,
                   version = version + 1, head_version_id = new
  replaceLinks / FTS as today
(embeddings: post-commit, best-effort — unchanged from today's shape)
```

`PageConflictError` surfaces in the UI as the "page changed underneath you"
affordance (dirty-editor protection already has the vocabulary). Because the
guard is SQL inside the transaction, the same protocol is correct from
`wikictl` cross-process — no in-process lock involved (§2). `wikictl page
write` gains an optional `--expect-version N` (agents that read-then-write
can CAS; bare writes keep today's semantics against the *advisory-locked*
pages model of W1).

**Workspace write** (W2+, agent via `wikictl --workspace W`): append version
(existing page) or update `blob_hash`/`title` (created page); UPSERT
`workspace_refs`, recording `base_version_id` on first touch. No `pages`-row
change, no token movement, no FP visibility. Milliseconds.

**Merge** (W2+; serialized queue; one short transaction per attempt):

```
mark workspace 'merging'
PRE-TRANSACTION (no write lock held):
  compute anticipated merged bodies:
    slug-collision rewrite first (D13: loser→winner ULIDs, new blobs),
    then per-page diff3(base, main_head, ws_head)
  if any page conflicts → park 'conflicted' (no transaction opened)
  run embedding inference for the anticipated bodies (D10 / B3)
withTransaction:
  re-validate every base: main head still == base observed pre-transaction
      -- a human commit raced the pre-compute → abort, re-run pre-compute (cheap loop)
  for each workspace_refs row: insert merge/root version rows
      (merge_parent_id set for true merges), update pages mirror + head,
      create pages rows for D16 pages (slug re-check under the lock)
  wiki_index: line-set three-way against index_base_version (D12);
      same-line conflict → abort transaction, park 'conflicted'
  regenerate links + FTS for touched pages (pure SQL); persist precomputed vectors
  append ingest-completion log entry; merge activity into PROV
mark 'merged'
```

All-or-nothing per D17. Parking writes the conflict *description* (page,
base/ours/theirs version ids) onto the workspace and returns — durable,
diffable, resumable. Resolution (merge agent or human) writes new versions
**into the workspace** and re-enqueues; the resolver never runs inside the
commit path (§1's hard constraint). Other open workspaces are unaffected
until *their* merge attempt, which revalidates against the new main
(refresh/rebase — Oracle WM's `RefreshWorkspace` — is the same pre-compute
run voluntarily before merging).

**Merge executor** *(specified: review M2)*: the app owns the merge queue (a
serialized task adjacent to `WikiStoreModel`, same discipline as the spawn
slot). `wikictl workspace merge` *requests* a merge: if the app is running it
enqueues (Darwin notification, existing bridge); headless, `wikictl` may
execute the merge directly — safe because the protocol is pure store calls
under `withTransaction`, and cross-process exclusion is WAL's job. Revisit at
W5 if queue-fairness needs richer coordination.

## 5. changeToken & File Provider

The invariant: **the token reflects main only.** Workspace activity is
invisible to the File Provider until merged.

- W0 adds **no fold and no fold movement**: page commits move the existing
  `pages` count+`SUM(version)` fold exactly as blind `updatePage` does today
  (the counter increments on every save either way); `head_version_id` and
  `page_versions` are outside every fold; `refs` is untouched (D6). The v29
  migration leaves counters untouched → token byte-identical. The 21
  hardcoded literal assertions are *verified*, not rewritten, in the W0
  commit.
- W2's tables (`workspaces`, `workspace_refs`) are deliberately outside all
  folds. Merge commits move the `pages` fold (mirror row + counter), which is
  exactly when the FP must refresh.
- Recorded so a future "just add a `page_versions` count fold" doesn't
  reintroduce speculative-write visibility: **`page_versions` must never be
  folded by count** — workspaces append to it without changing main.

## 6. What this retires, and what it deliberately doesn't

**Retired:** `isAgentRunning` as a *global* edit lock — W1 replaces it with
per-page advisory read-only (D16a) + CAS as the correctness backstop; W2+
replace even that with true isolation. "Ingestion locks several pages at
once" dissolves entirely at W2: nothing is locked during ingestion; the
multi-page atomic step shrinks to the merge transaction, and SQLite's write
lock *is* that mutex, already built.

**Kept:** the spawn slot (as an N-throttle from W5 — resource management,
not correctness); WAL + `busy_timeout` cross-process discipline; the
method-atomic store + `withTransaction` (graph-model Phase 0 is precisely
the substrate this plan stands on); the synchronous main-actor write model
for human edits; the post-commit embedding discipline (§2).

**Non-goals, named:** SSI/read-set validation (D3); a head-pointer journal /
as-of-snapshot reads (D7); CRDTs/OT (keystroke-scale machinery for an
agent-scale problem — except the set-union idea, kept for `wiki_index`);
op-log/replay ingestion (Bayou — filed as refinement if diff3 quality
disappoints); actual git as substrate (FTS, vec, FP live in SQLite; Fossil
proves the semantics port); multi-level/nested workspaces; partial-land
merges (D17 — revisit with evidence); chat tables (v25/v28) — single-writer
surfaces, out of scope.

## 7. Per-page advisory locks (W1, the cheap UX win)

The narrow, real pain today: *the whole editor freezes for the minutes an
ingestion runs.* W1 fixes that without any workspace machinery:

- `WikiStoreModel` gains `agentTouchedPageIDs: Set<PageID>`, populated from
  the existing wikictl-write change events during a run (the agent "locks"
  a page by writing it), cleared in `endAgentRun` (crash ⇒ cleared — no
  leases, no reaping, no DB state).
- `PageDetailView`'s read-only gating switches from `store.isAgentRunning`
  to `agentTouchedPageIDs.contains(page.id)`; the banner becomes per-page
  ("The agent is updating this page…"). Autosave pauses only for touched
  pages.
- The race this cannot prevent — human already mid-edit when the agent first
  touches the page — is exactly what W0's CAS catches: the human's save gets
  the conflict affordance instead of silently clobbering (or being
  clobbered). Advisory lock = UX; CAS = correctness. `wiki_index` needs no
  lock (agent-maintained, not a page, humans never edit it).
- One agent run at a time is *kept* in W1 (today's spawn-slot serialization)
  — agent-vs-agent contention does not exist yet, which is what makes
  advisory locks sufficient. They are throwaway-cheap when W2 arrives.

## 8. Review reconciliation (2026-07-09)

Disposition of `page-versions-and-workspaces-review.md`, recorded so it
isn't relitigated:

| Finding | Disposition |
|---|---|
| **B1** `refs.owner_id` FK-locked to sources | **Accepted; fixed differently than proposed.** Not typed `page_refs` tables — the head pointer moves onto the `pages` row (D6), which also fixes the latent `MAX(id)`-head bug and keeps the token story trivial. `refs` untouched |
| **B2** workspace-created pages can't exist without a `pages` row | **Accepted.** D16: created pages live as `blob_hash`+`title` on `workspace_refs` until merge; §4.2 schema revised; D13 rewritten to match |
| **B3** inference inside the merge transaction | **Accepted.** D10 + §4.3: pre-compute embeddings pre-transaction, re-validate bases under the lock, persist vectors inside — mirroring `renameSource` |
| **H1** amend rewrites a live merge base | **Accepted.** D14 gains the no-references guard |
| **H2** all-or-nothing parking | **Accepted as a decision, not a defect.** D17: all-or-nothing kept (dangling-link argument), consequence named, partial-land evidence-gated |
| **H3** slug-unification ordering | **Accepted.** D13: ULID rewrite mints new blobs *before* diff3 |
| **M1** token fragility | **Dissolved by the B1 fix** (no refs movement, no migration rebuild); literal verification stays a named W0 task |
| **M2** merge executor unspecified | **Specified** (§4.3: app-owned queue, wikictl request-or-headless-execute) |
| **M3** GC underspecified | **Specified** (§4.2: reachable-set rules for versions, blobs, orphan sources) |
| **⚪ overlay staleness / D12 residual conflicts / §4.6 honesty** | Sentences added at D7, D12, D14 |
| **Accuracy: extraction-doc lineage overstated** | Fixed in the status block and §2 |
| **Scope judgment** | **Partially accepted.** The reviewer's sequencing is adopted (W1 advisory locks pulled forward; workspaces evidence-gated). The requirement itself — concurrent ingestions — stands as the destination: it was the originating goal, and the reviewer's per-page-lock alternative only suffices *because* it presumes single-agent serialization (locks between concurrent agents = unknown write sets + deadlock + lease reaping, the same reasons the brainstorm rejected pessimistic locking). Workspaces remain the design for that future; they are no longer the next step |

## 9. Phases

W0 and W1 are the committed near-term work. **W2–W5 are evidence-gated**:
build them when (a) concurrent ingestions are actually wanted, or
(b) reviewable-before-land ingestion is actually wanted, or (c) CAS-conflict
telemetry from W0/W1 shows real contention. Until a gate condition is true,
this section is a finished design on the shelf, not a queue.

| Phase | Contents | Gate |
|-------|----------|------|
| **W0 — Page versions & CAS** (v29; executes #258) | `page_versions` + blob-backed bodies, `pages.head_version_id` (D6), root-version seeding migration, CAS save protocol + `PageConflictError` + editor conflict affordance, autosave amend rule + guard (D14), `wikictl page history` / `revert` (head repoint + mirror), `--expect-version` on `wikictl page write`, token-literal verification | Two writers race one page: loser gets a conflict, no silent clobber; page history browsable; revert = one-row repoint + mirror; token byte-identical across migration |
| **W1 — Per-page advisory locks; global lock retired** (no schema) | `agentTouchedPageIDs` on the model (fed by existing change events), per-page read-only banner + per-page autosave pause, `isAgentRunning` demoted to run-status display (kept for query-debug UI), reload guards re-scoped | **Edit page B while an ingestion rewrites page A** — B saves normally; A shows a per-page banner; a human already editing A gets the CAS affordance on save, not a clobber |
| **W2 — Workspaces & fast-forward merge** (v30) *(gated)* | `workspaces` + `workspace_refs` (incl. D16 created-page staging), overlay resolution in the store, `wikictl --workspace` (create/status/abandon/merge verbs), ingestion behind a capability flag, merge = fast-forward-only (any divergence parks `conflicted`, retryable), GC (`vacuum-page-versions`, blob sources) | An ingestion runs in a workspace invisibly to the FP (token unchanged until merge); FF merge lands it atomically; a deliberately-conflicting ingestion parks without corrupting main; abandoned workspace GCs clean |
| **W3 — Real merge** *(gated)* | Pre-transaction diff3 + embedding precompute + base re-validation (§4.3), `merge_parent_id` lineage + merge PROV activity, slug-collision unification with pre-diff3 ULID rewrite (D13), `wiki_index` line-set merge (D12), refresh/rebase verb | Two overlapping ingestions (shared touched page + both touching the index) both merge cleanly; merged page shows two-parent history |
| **W4 — Conflict resolution & review** *(gated)* | Parked-conflict data model surfaced: pending-ingestions panel (workspace diff vs main, per-page base/ours/theirs), merge-agent resolution path (writes into the workspace, re-enqueues), human resolve/abandon UI, conflict-state `wikictl` verbs; partial-land revisited iff D17 latency bites | A conflicted workspace is reviewable as a diff; the merge agent resolves a real conflict and the merge completes; a second workspace merges *while* the first sits parked (no head-of-line block) |
| **W5 — Concurrency unleashed** *(gated)* | Spawn slot → configurable N-throttle; multiple simultaneous ingestions end-to-end; merge-queue fairness (rebase-don't-abort); workspace TTL/reaper for crashed runs; read-set PROV recording + "cites since-changed content" lint (stretch) | Two ingestions run concurrently from the UI, queries and edits proceed throughout, both land (one via merge), and the whole run is auditable in PROV |

Dependency notes: W0 stands alone and is a legitimate stopping point. W1
needs W0 (CAS is the backstop that makes advisory-only locks safe). W2 needs
W0; W3–W5 are strictly ordered after W2. The extraction-slot work
(`extraction-vs-ingestion-lock.md`) is orthogonal and can land any time.

## 10. Open questions

1. **Merge-agent identity & prompt surface** (W4) — a PROV `agents` row,
   clearly; but does it run as a `claude -p` spawn through the same throttle,
   and what does its context packet contain (base/ours/theirs + both
   activities' plans)?
2. **Merge-hint metadata** (Bayou-style, W4): should an ingestion's activity
   carry a hint ("my index edits are additive; my page edits are
   section-appends") the merge agent reads before general diff3? Cheap to add
   to `activities.plan`; decide when W4 shows real conflict shapes.
3. **Workspace state on the event bus** (W2) — the FP token ignores
   workspaces by design (§5), but the app UI wants live workspace status;
   probably the existing event bus.
4. **Section-aware diff3** (W3) — line-based diff3 first; markdown
   section-aware merge (heading-scoped) only if real conflicts show it pays.
   Dolt's lesson says it will; earn it with evidence.
5. **Agent CAS policy** (W1) — when a `wikictl page write --expect-version`
   fails mid-run because a human won the race, does the agent re-read and
   retry (likely), or surface to the run log and continue? Decide during W1
   implementation; today's blind-write behavior is the fallback.
