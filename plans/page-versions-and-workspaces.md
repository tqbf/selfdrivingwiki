# Page versions & workspaces — multi-writer without a global lock

**Status:** proposed (2026-07-09). Successor to the multi-writer brainstorm;
builds directly on `graph-model-and-versioning.md` (the objects/refs
substrate this plan extends to pages) and completes the arc
`extraction-vs-ingestion-lock.md` started (that doc unfused extraction from
the agent lock; this one retires the agent lock itself). Executes
[#258](https://github.com/tqbf/selfdrivingwiki/issues/258) (page versioning)
as its Phase 0.

**The organizing idea:** there are two "global locks" in this system and they
have opposite characters. The SQLite WAL write lock is global but held for
*milliseconds* — it is not the problem and every design below funnels through
it happily. The application-level agent edit lock (`isAgentRunning`,
`WikiStoreModel.swift:203`) is held for the *minutes* an ingestion runs, and
exists for exactly one reason: an ingestion is a long-running logical
transaction with no isolation mechanism, so the app protects consistency by
locking everyone out. This plan gives long-running writers an isolation
mechanism — durable, named **workspaces** over the append-only version
substrate the graph-model plan already built — so the only exclusive section
left is a short merge commit. MVCC and git branches are not two options here;
on a storage model that is already immutable blobs + append-only versions +
mutable refs, **a branch is MVCC with the speculative state made durable and
addressable**. We build that once and get both.

---

## 1. Prior art (why this shape, recorded so it isn't relitigated)

Every element below has a named ancestor with documented failure modes.
What we are building is precisely: *Postgres snapshot-isolation semantics with
git's merge instead of Postgres's abort-and-retry, an Oracle-Workspace-Manager
workspace lifecycle, CouchDB's conflict-as-durable-state, and an LLM as the
conflict handler.* Only the last part is novel.

| Design element | Ancestor |
|---|---|
| Per-page CAS on a ref | Optimistic concurrency control (Kung & Robinson 1981); git atomic ref update; HTTP ETag/`If-Match` |
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
  `AgentLauncher.swift` serializes all `claude -p` runs; the extraction slot
  (extraction-vs-ingestion plan) is already separate.
- The objects substrate from graph-model Phases 1–2 is live: content-addressed
  `blobs`, append-only `source_versions` / `source_markdown_versions`, PROV
  `agents`/`activities`, and the single mutable `refs` table
  (`kind, owner_id, version_id, generation, updated_at`,
  `SQLiteWikiStore.swift:585`) with two kinds (`source-content`,
  `source-derived`) and the default-active rule (no ref row → `MAX(id)`).
  Lazy GC exists (`vacuumBlobs`, `vacuum-all`).
- The changeToken is assembled from registered `ChangeTokenContributor`s
  (`SQLiteWikiStore.swift:1933`); the current 11-field literal is enforced
  byte-for-byte by ~20 hardcoded assertions across three test suites. One
  existing fold is `COALESCE(SUM(generation),0)` over **all** of `refs`
  (`SQLiteWikiStore.swift:2038`) — load-bearing fact: speculative ref writes
  must not land in that table or the File Provider token moves on
  uncommitted work.
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
| D1 | **Pages join the object model**: append-only `page_versions` + a `page-content` ref kind; a page save = append version + CAS repoint | The prerequisite for everything; executes #258. CAS in one sentence: "repoint P from A to B where B.parent = A; if the ref moved, conflict" |
| D2 | **`pages.body_markdown` stays, as the materialized main head** (denorm mirror, same flagged discipline as `sources.byte_size` in graph-model §9) | FTS, embeddings, FP projection, UI, and search keep reading the `pages` row unmodified — MVCC lands with **zero read-path migration**. Every main commit updates row + version + ref atomically in one `withTransaction` |
| D3 | **Isolation level: snapshot-ish, read-latest + recorded read set, write-set validation at commit, first-committer-wins.** Write skew consciously accepted | Wiki prose has no cross-page invariants, so SI anomalies are harmless by construction; the read set lands in PROV as `used` relations (audit trail, future "cites since-changed content" lint). SSI-style read validation is the named, rejected alternative |
| D4 | **Humans commit to main; agents get workspaces** | A human save is milliseconds — direct CAS, with CAS failure surfacing as a "page changed underneath you" affordance. Humans never think about branches to fix a typo. Mirrors the extraction-vs-ingestion asymmetry principle |
| D5 | **Workspaces are durable rows** (`workspaces` table: ULID, status lifecycle `open → merging → merged \| conflicted \| abandoned`, PROV activity) | Durable speculation = crash recovery, observability (watch the agent work), and **reviewable ingestions** (a workspace is a diff against main inspectable before it lands — PR review for the wiki) |
| D6 | **`workspace_refs` is a sibling table, not a `workspace` column on `refs`** | Keeps main's `refs` semantics and its `SUM(generation)` changeToken fold byte-identical (no test-literal churn); speculative refs get their own cascade (delete workspace → refs vanish) and never feed the token. Honors graph-model §4.3's polymorphism tripwire: the third ref kind arrives *without* widening the polymorphic table — `refs` instead gains a `CHECK(kind IN (…))` |
| D7 | **Overlay reads**: in workspace W, resolve W's ref if present, else main. `wikictl --workspace <id>` / `WIKI_WORKSPACE` env selects the namespace; the agent toolchain works unmodified | Union-mount semantics; no snapshot-at-start (that would require a refs journal — rejected, D3 records reads instead) |
| D8 | **Merge ladder**: fast-forward → three-way textual merge (diff3 against recorded base) → **park conflicted** → agent/human resolution as a later ordinary write | The queue stays dumb and fast (Datomic-transactor discipline); LLM resolution happens *outside* the commit path (CouchDB conflict-as-state) |
| D9 | **Merged versions get two-parent lineage**: `page_versions.merge_parent_id` | A merge is a real PROV activity whose output `wasDerivedFrom` both parents; two parents suffice (no octopus merges) |
| D10 | **Derived data is regenerated at merge, never merged**: `replaceLinks`, FTS, embeddings re-run for merged pages; the log is append-only (no conflicts); the ingest-completion log entry is written by the *merge*, not the run | Deterministic functions of bodies; merging them would be merging a cache |
| D11 | **Sources stay on main, even during workspace ingestion** | Source chains are append-only + content-addressed — concurrent ingestions cannot conflict on them. A source from an abandoned workspace is just an un-cited source (vacuumable). Keeps the overlay page-only and small |
| D12 | **`wiki_index` merges structurally, not textually**: it is semantically a link set — merge = three-way *line-set* union (added/removed lines vs base), fallback to parking only on same-line edits | Escrow-transaction reasoning applied to the one guaranteed hot spot. Without this, every merge conflicts, every time |
| D13 | **Slug collisions are a first-class merge case**: two workspaces creating the same title → merge unifies into one page (first-merged ULID survives; the second workspace's body is three-way-merged in and its ULID references rewritten at merge) | `pages_slug_unique` makes this an error, not a silent dupe — good; the merge must handle it, not crash on it. The silent-divergence alternative (two "Elixir" pages) is worse than a conflict |
| D14 | **Autosave coalesces into the head version** (git-commit-`--amend` style): a save whose parent is the current head, by the same actor/activity, within a debounce window, *replaces* the head version's blob pointer instead of appending | Without this, the in-app editor's debounced autosave mints a version row every few seconds and the chain is noise. Agents get one version per `wikictl` write (each write is deliberate) |
| D15 | **The edit lock retires; the spawn slot becomes a throttle** | Once agents write to workspaces, in-app edits *cannot* clobber agent writes — the lock's stated reason (`WikiStoreModel.swift:203`) is gone. The spawn slot stops being a correctness serializer and becomes "at most N concurrent claude processes", the same shape as the extraction slot |

## 4. Schema

Additive; follows the stepwise ladder discipline (fresh-path parity enforced
by `freshFastPathMatchesStepwiseLadder`).

### 4.1 `page_versions` (v29)

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
```

Bodies go through `blobs` — at *save* granularity, not keystroke granularity,
which is what graph-model §4.6 warned about; D14's coalescing rule is what
makes this honest. Page bodies rarely dedup; the append-only chain, not the
dedup, is what's being bought.

The `refs` table gains the `page-content` kind (a `CHECK` constraint listing
the three kinds, per D6) and the default-active rule carries over verbatim:
no ref row → head is `MAX(id)`. Migration seeds one root version per existing
page (blob of current body) and writes **no** refs — main tracks latest by
default, exactly like sources did in v20.

### 4.2 `workspaces` + `workspace_refs` (v30)

```sql
CREATE TABLE workspaces (
    id           TEXT PRIMARY KEY,       -- ULID
    name         TEXT,                   -- human label ("ingest: foo.pdf")
    status       TEXT NOT NULL DEFAULT 'open',
                 -- 'open' | 'merging' | 'merged' | 'conflicted' | 'abandoned'
    activity_id  TEXT REFERENCES activities(id),  -- the ingestion activity
    created_at   REAL NOT NULL,
    updated_at   REAL NOT NULL
);

CREATE TABLE workspace_refs (
    workspace_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
    kind         TEXT NOT NULL CHECK (kind = 'page-content'),
    owner_id     TEXT NOT NULL,          -- pages.id (may not exist on main yet: page created in-workspace)
    base_version_id TEXT,                -- main head observed at first write (CAS base; NULL = page created here)
    version_id   TEXT NOT NULL,          -- the workspace's current head for this page
    updated_at   REAL NOT NULL,
    PRIMARY KEY (workspace_id, kind, owner_id)
);
```

- `base_version_id` recorded at the workspace's **first write** to that page
  is the three-way-merge base and the CAS expectation — the write set and its
  bases in one table. The *read* set (pages read but not written) is recorded
  as PROV `used` rows on the ingestion activity (D3) — provenance, not
  validation input.
- No FK from `owner_id` to `pages` — a workspace may create a page that
  doesn't exist on main until merge. The merge transaction creates the
  `pages` row (or unifies on slug collision, D13).
- Workspace-created pages hold real `page_versions` rows (append-only tables
  are namespace-free; only *refs* are namespaced). Abandoning a workspace
  deletes its refs; orphaned versions/blobs fall to the existing lazy-GC
  pattern (`vacuum-pages` joins `vacuum-blobs`/`vacuum-all`).
- `wiki_index` workspace state: one nullable `index_body` snapshot column on
  `workspaces` (plus `index_base_version`) rather than a ref — it is a
  singleton, not a versioned owner. Merge applies the D12 line-set rule.

### 4.3 The commit protocols

**Human save to main** (Phase 0, replaces blind `updatePage`):

```
withTransaction:
  head = resolve page-content ref (or MAX(id))
  guard head == the version the editor loaded   -- CAS; else PageConflictError
  INSERT blob (OR IGNORE); INSERT page_versions (parent = head)   -- or amend head (D14)
  UPDATE pages SET body_markdown, title, updated_at, version+1    -- the D2 mirror
  UPSERT refs('page-content', page, new, generation+1)
  replaceLinks / FTS / embeddings as today
```

`PageConflictError` surfaces in the UI as the "page changed underneath you"
affordance (dirty-editor protection already has the vocabulary). Because the
guard is SQL inside the transaction, the same protocol is correct from
`wikictl` cross-process — no in-process lock involved (§2).

**Workspace write** (agent via `wikictl --workspace W`): append version;
UPSERT `workspace_refs` (recording `base_version_id` on first touch). No
`pages`-row change, no token movement, no FP visibility. Milliseconds.

**Merge** (serialized queue; one short transaction per attempt):

```
mark workspace 'merging'
withTransaction:
  for each workspace_refs row:
    main_head = resolve main ref
    if owner missing on main:  slug-collision check → create page or unify (D13)
    elif main_head == base:    fast-forward           -- repoint + mirror update
    else:                      diff3(base, main_head, ws_head)
                               clean → merge version (merge_parent_id set) + mirror
                               conflict → abort transaction, park 'conflicted'
  wiki_index: line-set three-way (D12); same-line conflict → park
  regenerate links/FTS/embeddings for touched pages (D10)
  append ingest-completion log entry; merge activity into PROV
mark 'merged'
```

Parking writes the conflict *description* (page, base/ours/theirs version ids)
onto the workspace and returns — durable, diffable, resumable. Resolution
(merge agent or human) writes new versions **into the workspace** and
re-enqueues; the resolver never runs inside the commit path (§1's hard
constraint). After any merge lands, other open workspaces are unaffected
until *their* merge attempt, which revalidates against the new main
(refresh/rebase — Oracle WM's `RefreshWorkspace` — is the same diff3 run
voluntarily before merging).

## 5. changeToken & File Provider

The invariant: **the token reflects main only.** Workspace activity is
invisible to the File Provider until merged.

- The existing folds already mostly deliver this given D2/D6: the `pages`
  count+`SUM(version)` fold moves on every main commit (mirror row always
  updated); `refs.SUM(generation)` moves on repoints; `workspace_refs` is
  deliberately outside the fold.
- One new contributor: `page_versions` **is not folded by count** (workspace
  writes append rows without changing main) — instead nothing new is needed;
  the mirror + refs folds cover every main-visible mutation (append-without-
  repoint on main cannot occur for pages: every main commit repoints).
  Recorded so a future "just add a count fold" doesn't reintroduce
  speculative-write visibility.
- Token literals in tests: Phase 0 changes no fold; verify byte-identity in
  the same commit.

## 6. What this retires, and what it deliberately doesn't

**Retired:** `isAgentRunning` as an edit lock (D15) — the editor stays
editable during ingestion; the read-only banner becomes a per-page conflict
affordance. "Ingestion locks several pages at once" dissolves entirely: nothing
is locked during ingestion; the multi-page atomic step shrinks to the merge
transaction, and SQLite's write lock *is* that mutex, already built.

**Kept:** the spawn slot (as an N-throttle — resource management, not
correctness); the extraction slot (unchanged); WAL + `busy_timeout`
cross-process discipline; the method-atomic store + `withTransaction`
(Phase 0 of graph-model is precisely the substrate this plan stands on); the
synchronous main-actor write model for human edits.

**Non-goals, named:** SSI/read-set validation (D3); a refs journal /
as-of-snapshot reads (D7); CRDTs/OT (keystroke-scale machinery for an
agent-scale problem — except the set-union idea, kept for `wiki_index`);
op-log/replay ingestion (Bayou — filed as refinement if diff3 quality
disappoints); actual git as substrate (FTS, vec, FP live in SQLite; Fossil
proves the semantics port); multi-level/nested workspaces; chat tables
(v25/v28) — single-writer surfaces, out of scope.

## 7. Phases

Each gate is demoable; each phase ships alone and is independently valuable.

| Phase | Contents | Gate |
|-------|----------|------|
| **W0 — Page versions & CAS** (v29; executes #258) | `page_versions` + blob-backed bodies, `page-content` ref kind + `CHECK` on `refs.kind`, root-version seeding migration, CAS save protocol + `PageConflictError` + editor conflict affordance, autosave amend rule (D14), `wikictl page history` / `revert` (pointer copy), `vacuum-pages` | Two writers race one page: loser gets a conflict, no silent clobber; page history browsable; revert = one-row repoint; token literals byte-identical |
| **W1 — Workspaces, overlay, fast-forward merge** (v30) | `workspaces` + `workspace_refs`, overlay resolution in the store, `wikictl --workspace` (create/status/abandon verbs), ingestion runs in a workspace behind a capability flag, merge = fast-forward-only (any divergence → workspace parks `conflicted`, retryable), edit lock retired behind the same flag | **Edit a page while an ingestion runs** — both land; a deliberately-conflicting ingestion parks without corrupting main; abandoned workspace GCs clean |
| **W2 — Real merge** | diff3 against `base_version_id`, `merge_parent_id` lineage + merge PROV activity, derived-data regeneration at merge, slug-collision unification (D13), `wiki_index` line-set merge (D12), refresh/rebase verb | Two overlapping ingestions (shared touched page + both touching the index) both merge cleanly; merged page shows two-parent history |
| **W3 — Conflict resolution & review** | Parked-conflict data model surfaced: pending-ingestions panel (workspace diff vs main, per-page base/ours/theirs), merge-agent resolution path (writes into the workspace, re-enqueues), human resolve/abandon UI, conflict-state `wikictl` verbs | A conflicted workspace is reviewable as a diff; the merge agent resolves a real conflict and the merge completes; a second workspace merges *while* the first sits parked (no head-of-line block) |
| **W4 — Concurrency unleashed** | Spawn slot → configurable N-throttle; multiple simultaneous ingestions end-to-end; merge-queue fairness (rebase-don't-abort); workspace TTL/reaper for crashed runs; read-set PROV recording + "cites since-changed content" lint (stretch) | Two ingestions run concurrently from the UI, queries and edits proceed throughout, both land (one via merge), and the whole run is auditable in PROV |

Dependency notes: W0 stands alone (page history + conflict detection is
worth shipping even if workspaces never follow). W1 needs W0. W2–W4 are
strictly ordered. The extraction-slot work (extraction-vs-ingestion plan) is
orthogonal and can land any time.

## 8. Open questions

1. **Merge-agent identity & prompt surface** — a PROV `agents` row, clearly;
   but does it run as a `claude -p` spawn through the same throttle, and what
   does its context packet contain (base/ours/theirs + both activities'
   plans)? Decide in W3.
2. **Title-only edits vs body edits in CAS** — does a rename race a body edit
   (title lives on `page_versions` per §4.1)? Proposal: title is part of the
   version, so yes, CAS covers it; renames are cheap to re-apply. Confirm in W0.
3. **Merge-hint metadata** (Bayou-style): should an ingestion's activity
   carry a hint ("my index edits are additive; my page edits are
   section-appends") the merge agent reads before general diff3? Cheap to add
   to `activities.plan`; decide when W3 shows real conflict shapes.
4. **Event bus / Darwin notifications for workspace state** — the FP token
   ignores workspaces by design (§5), but the *app UI* wants live workspace
   status; probably the existing event bus, decide in W1.
5. **Section-aware diff3** — line-based diff3 first (W2); markdown
   section-aware merge (heading-scoped) only if real conflicts show it pays.
   Dolt's lesson says it will; earn it with evidence.
