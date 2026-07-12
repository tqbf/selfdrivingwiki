# Multi-Writer Hardening Design

## Summary

This design hardens the wiki app's storage layer against the failure modes
that multiple concurrent writers — a human editing pages, an AI agent
ingesting content, and future parallel background jobs — can trigger. It
proceeds in two tracks. The **live track** (Phases 1–4) fixes the
concurrency model already running in production: it extends the
compare-and-swap discipline that today only protects human saves out to
agent writes, so an agent can no longer silently clobber an edit made after
it last read a page. It splits the single global concurrency limiter into
per-lane queues so a long-running ingest can't starve interactive chat
turns (or vice versa). It establishes an invariant that every page carries
an explicit pointer to its current head version, so speculative or
exploratory writes can never leak into what the app resolves as "the"
content of a page. And it teaches the autosave path to collapse rapid
same-actor edits into a single version instead of growing the history
forever, while fixing an existing bug where the cleanup ("vacuum") job
could delete page history that was still in use.

The **workspace track** (Phases 5–7) completes an isolation layer — largely
built but not yet wired up — that lets a large operation such as a
multi-page ingest stage all of its writes in a private area and merge them
into the main database atomically, only once the whole operation finishes
cleanly. This closes the remaining gaps: pages created inside such a
staging area no longer leave orphaned rows behind if the operation is
abandoned, and two staging areas that both try to create a page with the
same title now produce a conflict instead of silently duplicating it.
Merging a staging area now also regenerates search embeddings and
reconciles the wiki's structural index instead of leaving them stale.
Finally, the actual write path is connected end to end so ingestion can opt
into full isolation behind a feature flag (off by default), while ordinary
human edits continue to land directly on the main database throughout,
unaffected by an ingest running in isolation.

## Definition of Done

From the post-merge review of the W0–W4 multi-writer implementation
(findings L1–L3 live, W1–W4 latent):

1. **Agent writes are CAS-protected end-to-end.** An agent cannot silently
   overwrite a page edit committed after the agent read that page. (L1)
2. **Concurrent generations cannot lose updates on shared hot state.** At
   most one ingest-class run executes at a time until workspace isolation is
   wired; chat turns still run during an ingest. (L2)
3. **Main's head resolution is immune to speculative writes.** Every `pages`
   row has an explicit `page-content` ref; workspace version appends never
   change what main reads or what CAS compares against. (W1)
4. **Page history stays bounded and reclaimable.** Rapid autosaves coalesce
   into the head version; unreachable page versions and their blobs are
   GC-able via vacuum — and `vacuum-blobs --apply` no longer deletes live
   page-version blobs. (L3 + the vacuum data-loss bug)
5. **Workspace-created pages are invisible on main until merge.** Abandoning
   a workspace leaves no residue on main; two workspaces creating the same
   title produce a merge conflict, not silent same-title duplicates. (W2)
6. **A merged page is fully consistent after merge.** Links, FTS, and
   embeddings reflect the merged body; `wiki_index` merges structurally
   (line-set three-way), parking only on same-line conflicts. (W3 + D12)
7. **Ingestion can run isolated in a workspace** behind a capability flag:
   the agent writes into the workspace, main is untouched until an automatic
   merge on completion, and stale workspaces are reaped on app launch. (W4)

## Acceptance Criteria

### multi-writer-hardening.AC1: Agent writes are CAS-protected
- **multi-writer-hardening.AC1.1 Success:** `page upsert --expect-head <current head>` succeeds and appends a version whose parent is that head
- **multi-writer-hardening.AC1.2 Failure:** `page upsert --expect-head <stale id>` exits with the distinct CAS code, reports the current head, and leaves the page byte-identical
- **multi-writer-hardening.AC1.3 Success:** `page get` (text and `--json`) includes the page's `head_version_id`
- **multi-writer-hardening.AC1.4 Edge:** blind `page upsert` (no flag) preserves today's behavior exactly
- **multi-writer-hardening.AC1.5 Success:** ingest/edit prompt templates contain the read → expect → retry-once discipline (template assertion)

### multi-writer-hardening.AC2: Lane-aware generation gate
- **multi-writer-hardening.AC2.1 Success:** an interactive turn acquires immediately while an ingest holds the ingest lane
- **multi-writer-hardening.AC2.2 Success:** a second ingest queues until the first releases; FIFO order within the lane holds
- **multi-writer-hardening.AC2.3 Failure:** a waiter cancelled while queued never receives or leaks a slot (both lanes)
- **multi-writer-hardening.AC2.4 Edge:** lane limits are constructor-configurable; `[.ingest: 1, .interactive: 3]` is the app default

### multi-writer-hardening.AC3: Head-ref invariant
- **multi-writer-hardening.AC3.1 Success:** after v33, every `pages` row has a `page-content` ref whose target equals the previously resolved head
- **multi-writer-hardening.AC3.2 Success:** `createPage` produces a root version + ref atomically
- **multi-writer-hardening.AC3.3 Success:** a workspace write to an existing page changes neither `pageHeadVersionID` nor a concurrent human CAS outcome
- **multi-writer-hardening.AC3.4 Edge:** the `MAX(id)` fallback path logs an assertion when reached (and is unreachable for migrated data)
- **multi-writer-hardening.AC3.5 Success:** v33 is idempotent (re-running on a migrated DB is a no-op); fresh-path parity holds

### multi-writer-hardening.AC4: Amend + GC
- **multi-writer-hardening.AC4.1 Success:** two same-actor saves within the coalescing window produce one version row (second amends)
- **multi-writer-hardening.AC4.2 Failure:** a head referenced by any `workspace_refs` row, or with children, is never amended (save appends)
- **multi-writer-hardening.AC4.3 Success:** `vacuum-page-versions` deletes only versions unreachable from ref targets and unreferenced by workspaces; dry-run reports without deleting
- **multi-writer-hardening.AC4.4 Failure:** `vacuum-blobs --apply` retains every blob referenced by `page_versions` (and post-v34 `workspace_refs`)
- **multi-writer-hardening.AC4.5 Edge:** an amend after the coalescing window expires appends instead

### multi-writer-hardening.AC5: Created-page staging
- **multi-writer-hardening.AC5.1 Success:** a workspace-created page moves neither the changeToken nor the `pages` count before merge
- **multi-writer-hardening.AC5.2 Success:** merge mints the `pages` row + root version; the page appears with the staged body and title
- **multi-writer-hardening.AC5.3 Failure:** merging a created page whose title/slug now exists on main parks the workspace with a conflict (no duplicate page)
- **multi-writer-hardening.AC5.4 Success:** abandoning a workspace with created pages leaves zero rows on main; vacuum reclaims the staged blobs
- **multi-writer-hardening.AC5.5 Edge:** the workspace_refs row-shape invariant holds (existing page: `version_id` set; created page: `blob_hash`+`title` set)

### multi-writer-hardening.AC6: Merge completeness
- **multi-writer-hardening.AC6.1 Success:** after a merge (fast-forward and diff3), each merged page's chunks/embeddings reflect the merged body
- **multi-writer-hardening.AC6.2 Success:** disjoint `wiki_index` line edits from two workspaces both survive sequential merges
- **multi-writer-hardening.AC6.3 Failure:** same-line index edits park the second workspace as conflicted
- **multi-writer-hardening.AC6.4 Success:** a successful merge appends the ingest-completion log entry

### multi-writer-hardening.AC7: Ingest isolation behind flag
- **multi-writer-hardening.AC7.1 Success:** with `workspacesEnabled`, an ingest leaves main pages and the changeToken untouched until auto-merge
- **multi-writer-hardening.AC7.2 Success:** a human page edit during an isolated ingest commits immediately to main
- **multi-writer-hardening.AC7.3 Failure:** an ingest whose merge conflicts parks the workspace and surfaces it via the conflict verbs (main uncorrupted)
- **multi-writer-hardening.AC7.4 Success:** with the flag off, ingest behavior is byte-identical to today
- **multi-writer-hardening.AC7.5 Edge:** stale `open` workspaces older than the TTL are reaped at app launch

## Glossary

- **CAS (compare-and-swap)**: An optimistic concurrency technique where a writer states the version it expects to be replacing; the write only succeeds if that expectation still matches the current state, otherwise it fails with a distinct error rather than silently overwriting someone else's change.
- **Head version / `head_version_id`**: The current, live version of a page — what a fresh read returns and what a CAS write checks its expectation against.
- **`page-content` ref**: A database row that points a page at the version considered its current head. The design requires every page to have exactly one, so there is never ambiguity about what the "real" content of a page is.
- **Blob**: The immutable, content-addressed storage of a page's raw text (referenced by hash); versions point at blobs rather than storing page text inline.
- **Version chain (`parent_id` / `merge_parent_id`)**: The linked history of a page's versions, each pointing back to its predecessor; a version produced by a merge points to two parents instead of one.
- **Workspace / `workspace_refs`**: A private, isolated staging area where a large operation (e.g., an ingest) can write pages and index changes without those writes being visible on the main database until an explicit merge.
- **Merge (`workspaceMerge`)**: The operation that folds a workspace's staged changes into the main database, atomically and only when it can do so without conflict.
- **Fast-forward merge**: A merge where nothing on main changed since the workspace's starting point, so the workspace's changes can be applied directly without reconciling divergent edits.
- **Three-way merge / diff3**: A merge strategy that compares a common ancestor against two versions that diverged from it, combining non-overlapping changes automatically and flagging a conflict only where both sides changed the same content.
- **Conflict / "parked"**: The state a workspace enters when a merge can't be resolved automatically; it is set aside for manual resolution rather than being forced through and corrupting main.
- **Generation gate / lane**: The in-process limiter that caps how many concurrent "runs" (ingests, chat turns, etc.) execute at once; a lane is a named queue (e.g., `ingest`, `interactive`) with its own concurrency limit, so congestion in one kind of work doesn't block the other.
- **FIFO (first-in-first-out)**: The ordering guarantee that waiters for a queue slot are served in the order they arrived.
- **`changeToken`**: A single value summarizing the wiki's overall write-generation, used by clients (notably the File Provider) to detect that something changed and a refresh is needed.
- **Vacuum (`vacuum-blobs` / `vacuum-page-versions`)**: Maintenance commands that delete storage no longer reachable from any live reference (old page versions or blobs) — analogous to garbage collection.
- **`orphanBlobPredicate`**: The logic vacuum uses to decide whether a blob is still referenced by anything and must therefore be kept.
- **Schema ladder (v29…v34)**: The app's sequence of numbered, ordered database migration steps, each guarded so it can run safely and idempotently against a database at any prior version.
- **`wiki_index`**: The wiki's curated navigational index — a singleton table, not a page — staged per-workspace and merged line-set-wise when a workspace lands.
- **FTS (full-text search)**: The search index over page text, which must stay consistent with a page's current body after edits or merges.
- **Embeddings / chunks**: Vector representations of pieces ("chunks") of page text used for semantic search, regenerated whenever a page's content changes.
- **NO-EMIT**: A convention marking store mutations that intentionally do not advance the `changeToken` — used for workspace writes, which must stay invisible until merge.
- **`@MainActor`**: A Swift concurrency annotation confining a type's methods to the main thread, used here to guarantee the generation gate's internal state is only ever touched one operation at a time.
- **Capability flag (`workspacesEnabled`)**: A feature flag gating whether a code path — here, workspace-isolated ingestion — is active; defaults off so it can be rolled out gradually.
- **Coalescing window**: A short time window after an edit during which further edits from the same actor are merged ("amended") into the same version rather than creating a new one, keeping autosave from producing a version per debounce tick.
- **TTL (time-to-live) / reap**: A staleness threshold after which abandoned workspaces are automatically cleaned up rather than lingering indefinitely.
- **`wikictl`**: The command-line tool used to drive the wiki store (page reads/writes, workspace admin, vacuum, etc.); also invoked internally by the AI agent.
- **`AgentOperationRunner` / `OperationRequest`**: The internal components that launch and classify agent-driven runs (ingest, query, chat turn) so the gate/lane and CAS logic know how each should be treated.

## Architecture

Two tracks. The **live track** (Phases 1–4) hardens the concurrency model
that is actually running today — CAS-only optimistic writes on main with a
4-slot generation gate. The **workspace track** (Phases 5–7) finishes the
dormant isolation substrate so ingestion can move inside it.

### Live track

**Agent CAS (Phase 1).** Today only human saves CAS
(`WikiStoreModel.swift:1143` threads `loadedPageHeadVersionID`); agent
writes via `wikictl page upsert` pass no expectation
(`PageCommand.swift:178` → the `nil` default in `PageUpsert.swift:53`).
The fix extends the existing CAS seam outward: `page get` exposes the head
version id, `page upsert` gains `--expect-head <versionID>`, and a CAS
mismatch exits with a distinct code carrying the current head so the agent
can re-read and reapply. The ingest/edit prompt templates
(`AgentOperationRunner.swift`) instruct the read → thread → retry-once
discipline. Blind upsert remains valid for scripts; the app-launched agent
flows always thread the expectation.

**Gate lanes (Phase 2).** `GenerationGate` (`GenerationGate.swift:25`) is a
single FIFO with `maxConcurrent: 4` (`WikiFSApp.swift:91`). It becomes
lane-aware: each acquisition declares a lane derived from
`OperationRequest` (`OperationRequest.swift:14` — ingest/query/lint are
one-shot; chat turns are interactive). Lane limits: `ingest: 1`,
`interactive: 3` (both configurable), preserving the recent win (chat never
queues behind ingest) while closing the ingest-vs-ingest lost-update window
until Phase 7 provides real isolation.

Contract (the gate stays `@MainActor`, FIFO-per-lane, cancellation-safe —
same waiter shape as today):

```swift
enum GenerationLane: Hashable { case ingest, interactive }

final class GenerationGate {
    init(laneLimits: [GenerationLane: Int])   // default [.ingest: 1, .interactive: 3]
    func acquire(_ lane: GenerationLane) async -> Bool   // false = cancelled while waiting
    func release(_ lane: GenerationLane)
    var waiterCount: Int { get }               // test seam, unchanged
}
```

The gate remains injectable via `AgentLauncher.init(generationGate:)` — the
future #358 per-window split composes on top (per-window gates, optional
global parent) without further gate surgery.

**Head-ref invariant (Phase 3).** `migrateV29ToV30`
(`SQLiteWikiStore.swift:1888`) seeded root versions but no refs, so every
migrated-never-saved page resolves its head via the `MAX(id)` fallback
(`pageHeadVersionIDLocked`, `:2631`) — which `workspaceWritePage` (`:2808`)
poisons by appending speculative rows to the same chain. The fix
establishes the invariant **every `pages` row has a `page-content` ref**:
a data-only ladder step (v33) backfills refs for refless pages (pointing at
the current `MAX(id)` version, i.e. today's resolved head), `createPage`
seeds a root version + ref, and the `MAX(id)` fallback is demoted to a
logged assertion path. After this, speculative appends cannot affect main
reads, human CAS, or merge-base recording.

**Amend + GC (Phase 4).** Autosave (500 ms debounce,
`WikiStoreModel.swift:1105`) currently appends a version + activity + blob
per tick. The D14 amend rule lands in `appendPageVersion`
(`SQLiteWikiStore.swift:2530`): a save *amends* the head version in place
(replace blob pointer + title, same version id) iff the head was produced
by the same actor within a coalescing window, has no children, and no
`workspace_refs.base_version_id`/`version_id` references it; otherwise it
appends. Reclamation: `vacuumPageVersions(dryRun:)` deletes versions
unreachable by the `parent_id`/`merge_parent_id` walk from any
`page-content` ref target and unreferenced by any `workspace_refs` row;
`orphanBlobPredicate` (`:4897`) gains `page_versions.blob_hash` (and, after
Phase 5, `workspace_refs.blob_hash`) as reference sources. **The predicate
fix is urgent**: today `vacuum-blobs --apply` deletes live page-version
blobs — page history data loss from a shipped admin verb.

### Workspace track

**Created-page staging (Phase 5).** `workspaceWritePage` step 0 (`:2822`)
creates a placeholder `pages` row for workspace-created pages — moving the
changeToken, projecting a phantom empty page, leaving a husk on abandon
(`abandonWorkspace`, `:3291`, deletes only refs), and — because
`uniqueSlug` (`:5552`) suffixes rather than collides — letting two
workspaces silently create same-titled duplicate pages. The fix is the
design's D16: `workspace_refs` gains nullable `blob_hash` + `title`
columns (v34); for a page with no main row, `version_id` stays NULL and the
head is the blob. `workspaceMerge` (`:2950`) mints the `pages` row + root
version at merge, and treats an existing main page with the same
title/slug as a conflict (unify path), not a duplicate.

Schema delta (v34):

```sql
ALTER TABLE workspace_refs ADD COLUMN blob_hash TEXT REFERENCES blobs(hash);
ALTER TABLE workspace_refs ADD COLUMN title     TEXT;
-- Invariant (enforced by the two write paths, asserted in tests):
--   existing page:  version_id NOT NULL, blob_hash NULL, title NULL
--   created page:   version_id NULL,     blob_hash NOT NULL, title NOT NULL
```

**Merge completeness (Phase 6).** Two gaps in `workspaceMerge`: merged
pages are never re-embedded (`storePageChunks` callers are only
`PageUpsert.swift:80` and the bulk indexer), and the `wiki_index` merge
(design D12) was never implemented — `workspaces.index_body`/
`index_base_version` exist unused (`:653`). Post-merge, embeddings for
merged pages regenerate *after* commit (best-effort, mirroring
`PageUpsert`'s shape — the no-inference-in-transaction rule holds).
`wiki_index` merges as a line-set three-way (added/removed lines vs the
base captured in `index_base_version`); a same-line conflict parks the
workspace like any page conflict. The merge also appends the
ingest-completion log entry (deferred from the original design's D10).

**Producer wiring (Phase 7).** Workspaces currently have no producer —
`WorkspaceCommand.swift:19–28` has only admin verbs; there is no
`--workspace` on `page upsert`. This phase adds the write/read verbs
(`page upsert --workspace W` → `workspaceWritePage`; `page get --workspace
W` → overlay read; index update in workspace mode writes
`workspaces.index_body`), wires `AgentOperationRunner.runMultiIngest` to
create a workspace, thread the flag to the agent's `wikictl` invocations,
and auto-merge on completion — all behind a `workspacesEnabled` capability
flag (default off). `reapStaleWorkspaces` (today `wikictl`-only,
`WorkspaceCommand.swift:159`) is also invoked on app launch.

`wikictl` CLI contract after Phases 1 + 7:

```
page get <sel> [--workspace W] [--json]      # output includes head_version_id
page upsert ... [--expect-head <versionID>]  # CAS; mismatch → exit 3, current head on stderr/JSON
page upsert ... [--workspace W]              # write into workspace (no main mutation)
index update ... [--workspace W]             # stage into workspaces.index_body
workspace create|status|abandon|merge|refresh|conflicts|resolve|retry|reap   # unchanged
```

## Existing Patterns

This design extends patterns already in the codebase; it introduces no new
architectural style:

- **CAS protocol**: `appendPageVersion` (`SQLiteWikiStore.swift:2530`) is
  the template — guard inside `withTransaction`, distinct error type
  (`PageConflictError`), expectation threaded from the caller. Phase 1
  extends the same seam through `PageUpsert` to `wikictl`; Phase 4's amend
  is a branch inside the same method.
- **Stepwise schema ladder**: v33/v34 follow the guarded, idempotent ladder
  with fresh-path parity (`FreshSchemaParityTests`), matching the v29→v32
  steps. v33 is data-only (like the v23 link sweep); v34 is additive
  `ALTER TABLE` (like v27).
- **Emission discipline**: every new/changed mutator routes through
  `mutate()` or is annotated NO-EMIT (`StoreEmissionExhaustivenessTests`).
  Workspace writes stay token-invisible (NO-EMIT, established by
  `createWorkspace`/`workspaceWritePage`).
- **Post-commit inference**: embeddings after the write transaction,
  best-effort (`renameSource`'s documented shape, `PageUpsert.swift:80`).
  Phase 6's merge re-embedding follows it.
- **Lazy vacuum**: `vacuumPageVersions` mirrors `vacuumBlobs`
  (`:4916`) / `vacuumActivities` (`:4962`) — dry-run default, one
  transaction, report of reclaimed rows/bytes, surfaced under
  `wikictl admin`.
- **Gate mechanics**: Phase 2 preserves `GenerationGate`'s
  cancellation-safe waiter protocol and `@MainActor` confinement; lanes
  partition the existing FIFO rather than replacing it.

One deliberate divergence: Phase 3 demotes the sources-inherited
"default-active = `MAX(id)`" rule for pages. For sources it remains
correct (nothing appends speculatively to their chains); for pages it is
retired because workspaces do.

## Implementation Phases

<!-- START_PHASE_1 -->
### Phase 1: Agent CAS writes
**Goal:** Agent writes cannot silently clobber newer edits (DoD 1).

**Components:**
- `Sources/WikiCtlCore/PageCommand.swift` — `--expect-head` on upsert
  (distinct exit code + current head on mismatch); `head_version_id` in
  `page get` output (text + `--json`)
- `Sources/WikiFSCore/PageUpsert.swift` — no signature change (the
  `expectedHeadVersionID` parameter exists); conflict propagation to the
  CLI layer
- `Sources/WikiFS/AgentOperationRunner.swift` — ingest/edit prompt
  templates gain the read-head → thread-expectation → on-conflict
  re-read-and-reapply-once discipline

**Dependencies:** None.

**Done when:** Tests verify `multi-writer-hardening.AC1.*` — a stale
`--expect-head` upsert fails with the distinct code and does not modify the
page; a fresh one succeeds; blind upsert behavior is unchanged.
<!-- END_PHASE_1 -->

<!-- START_PHASE_2 -->
### Phase 2: Lane-aware generation gate
**Goal:** Ingest-class runs serialize among themselves; chat turns keep
running during an ingest (DoD 2).

**Components:**
- `Sources/WikiFS/GenerationGate.swift` — lanes per the Architecture
  contract (FIFO per lane, cancellation-safe waiters preserved)
- `Sources/WikiFS/AgentLauncher.swift` — acquisitions declare a lane
  derived from the run kind (`OperationRequest`: ingest/lint → `.ingest`;
  chat/query turns → `.interactive`)
- `Sources/WikiFS/WikiFSApp.swift:91` — construction switches to lane
  limits (`[.ingest: 1, .interactive: 3]`)

**Dependencies:** None.

**Done when:** Tests verify `multi-writer-hardening.AC2.*` — a second
ingest queues while the first runs; an interactive turn acquires
immediately during an ingest; cancellation while queued never leaks a slot.
<!-- END_PHASE_2 -->

<!-- START_PHASE_3 -->
### Phase 3: Head-ref invariant (v33 backfill)
**Goal:** Every page has an explicit `page-content` ref; speculative
appends cannot affect main (DoD 3).

**Components:**
- `Sources/WikiFSCore/SQLiteWikiStore.swift` — v33 data-only ladder step
  backfilling refs for refless pages (target = current resolved head);
  `createPage` seeds root version + ref; `pageHeadVersionIDLocked`
  (`:2631`) `MAX(id)` fallback demoted to a logged assertion path;
  `workspaceWritePage` asserts the main ref exists on first touch of an
  existing page

**Dependencies:** None (must land before Phase 7 wires producers).

**Done when:** Tests verify `multi-writer-hardening.AC3.*` — post-migration
every page has a ref; a workspace append leaves `pageHeadVersionID`, human
CAS, and recorded merge bases unchanged.
<!-- END_PHASE_3 -->

<!-- START_PHASE_4 -->
### Phase 4: Autosave amend + version/blob GC
**Goal:** Bounded history; safe reclamation; fix the vacuum data-loss bug
(DoD 4).

**Components:**
- `Sources/WikiFSCore/SQLiteWikiStore.swift` — amend branch in
  `appendPageVersion` (guards per Architecture); `vacuumPageVersions
  (dryRun:)` with the reachability rule; `orphanBlobPredicate` (`:4897`)
  gains `page_versions.blob_hash` (+ `workspace_refs.blob_hash` once v34
  exists)
- `Sources/WikiCtlCore/AdminCommand.swift` — `vacuum-page-versions` verb;
  inclusion in `vacuum-all`

**Dependencies:** Phase 3 (reachability walks ref targets).

**Done when:** Tests verify `multi-writer-hardening.AC4.*` — rapid
same-actor saves coalesce; a guarded head (workspace base / has children)
appends instead of amending; vacuum removes only unreachable versions;
`vacuum-blobs` retains every referenced page blob.
<!-- END_PHASE_4 -->

<!-- START_PHASE_5 -->
### Phase 5: Workspace created-page staging (v34)
**Goal:** Created pages invisible on main until merge; no abandon residue;
title collisions conflict instead of duplicating (DoD 5).

**Components:**
- `Sources/WikiFSCore/SQLiteWikiStore.swift` — v34 columns on
  `workspace_refs` (`blob_hash`, `title`); `workspaceWritePage` (`:2808`)
  drops the placeholder-`pages`-row creation (blob-headed staging for
  created pages); `workspaceMerge` (`:2950`) mints the `pages` row + root
  version at merge and conflicts on an existing same-slug/title main page;
  `abandonWorkspace` verified residue-free
- `Sources/WikiCtlCore/WorkspaceCommand.swift` — `status`/`conflicts`
  output covers staged created pages

**Dependencies:** Phase 3.

**Done when:** Tests verify `multi-writer-hardening.AC5.*` — a created page
moves neither the changeToken nor the pages count until merge; abandon
leaves zero main rows; two workspaces creating one title → second merge
parks with a conflict.
<!-- END_PHASE_5 -->

<!-- START_PHASE_6 -->
### Phase 6: Merge completeness — embeddings, wiki_index, log
**Goal:** Post-merge state fully consistent (DoD 6).

**Components:**
- `Sources/WikiFSCore/SQLiteWikiStore.swift` — `workspaceMerge` returns the
  merged page set; `wiki_index` line-set three-way merge against
  `index_base_version` (same-line conflict parks); ingest-completion log
  entry appended by the merge
- `Sources/WikiFSCore/WikiStoreModel.swift` — post-commit re-embedding of
  merged pages (best-effort, `PageUpsert` shape)

**Dependencies:** Phase 5 (merge path shape).

**Done when:** Tests verify `multi-writer-hardening.AC6.*` — merged page
chunks reflect the merged body; disjoint index edits from two workspaces
both land; same-line index edits park.
<!-- END_PHASE_6 -->

<!-- START_PHASE_7 -->
### Phase 7: Workspace producer wiring + ingest isolation flag
**Goal:** Ingestion runs isolated in a workspace behind a flag (DoD 7).

**Components:**
- `Sources/WikiCtlCore/PageCommand.swift` + `ArgumentParser.swift` —
  `--workspace` on `page upsert` / `page get` (overlay read); index update
  staging into `workspaces.index_body`
- `Sources/WikiFS/AgentOperationRunner.swift` — `runMultiIngest` creates a
  workspace when `workspacesEnabled`, threads `--workspace` into the
  agent's `wikictl` calls, auto-merges on completion (parks on conflict,
  surfaced via the existing conflict verbs)
- `Sources/WikiFSCore/WikiStoreModel.swift` — `workspacesEnabled`
  capability flag (default off); `reapStaleWorkspaces` on app launch

**Dependencies:** Phases 3, 5, 6.

**Done when:** Tests verify `multi-writer-hardening.AC7.*` — with the flag
on, an ingest leaves main and the changeToken untouched until merge; a
human edit during ingest lands immediately; the run auto-merges (or parks)
at completion; stale `open` workspaces are reaped at launch.
<!-- END_PHASE_7 -->

## Additional Considerations

**Hotfix candidate ahead of phase order:** the `orphanBlobPredicate` fix
(Phase 4) is a one-line change preventing data loss from a shipped admin
verb (`vacuum-blobs --apply` currently deletes all page-version blobs). It
can and should be cherry-picked first if any vacuum is run before Phase 4
lands.

**changeToken:** the v33 backfill writes one ref per refless page, moving
the `refs.SUM(generation)` fold once at migration — an intended,
FP-refresh-forcing move (data migrations already do this, e.g. v23). Test
literals that pin token values update in the same commit. Workspace tables
remain outside every fold; `page_versions` must never gain a count fold
(speculative appends would leak into the token).

**Agent retry semantics (Phase 1):** the prompt-level contract is
retry-once-then-surface — on a second consecutive CAS failure for the same
page the agent reports the conflict in its output rather than looping.
This bounds pathological churn against a rapidly-editing human.

**#358 compatibility (multi-window):** lanes (Phase 2) are orthogonal to
the per-window gate split; the gate stays injectable and `@MainActor`. When
#358 lands, each window constructs its own lane-configured gate; a global
resource cap can be added as an optional parent gate without changing this
design. One window per wiki should be enforced (`WindowGroup(for:)` value
identity provides it) so two windows never run blind pipelines on one
database.

**Out of scope:** the merge agent (LLM conflict resolution — design W4
phase in `plans/page-versions-and-workspaces.md` §9), section-aware diff3,
partial-land merges, per-wiki agent configuration, and the #358 window
refactor itself.
