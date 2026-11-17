---
timestamp: 2026-11-16T232000Z
title: Daemon-only P1 async store flip converges green
branch: feature/daemon-only-p1-async-store
status: active
---

# Daemon-only P1 async store flip converges green

## Progress

The P1 phase of `plans/daemon-only-access.md` reached its green gates on
`feature/daemon-only-p1-async-store` (22 checkpoints pushed; the final
convergence work is the next commit).

- **The flip.** `WikiStore` requirements are `async throws`;
  `GRDBWikiStore` witnesses them with unchanged synchronous signatures.
  `WikiStoreModel` gained the P1.3 redesign: `bootstrapFromStore()` as the
  awaited readiness barrier (SessionsPlugin awaits it before the session
  reaches the UI), serialized generation-checked selection transitions,
  and a coalesced event-reload queue.
- **Write acknowledgment invariant.** The pre-flip bus callback refreshed
  list projections synchronously before a write method returned; the
  flipped async bus could not. The model's write methods now end with
  `refreshProjectionsAfterOwnWrite()` (four list projections plus history
  prune), restoring "a write method returns with projections current".
  The bus path stays coalesced for external events. `loadDraftsAsync`
  carries a `draftContentStamp` freshness guard, and the clean-draft
  reload re-checks `isDraftDirty` after its read, so an in-flight reload
  can never clobber a keystroke.
- **Requested-selection tracking.** `loadedSelection` only updates when
  the async load lands, so mid-flight it is nil. History recording, the
  `handleSelectionChange` echo guard, and title/id-based selection now
  consult `requestedSelection`, which updates synchronously at all four
  `selection` write sites. This restores pre-flip back/forward history
  and eliminates double-recorded rapid transitions.
- **Quiesce seam.** `quiesceSelectionTransitions()` awaits the newest
  selection-transition task, the pending-save task, and the coalesced
  reload queue. Hosted tests (and the golden-master exporter callers)
  that need settled state await it; the fire-and-forget UI contract is
  unchanged.
- **UI sweep.** Every sync call site that the flip invalidated now either
  reads a loaded snapshot (`SourceDetailView` keeps per-file projections
  in `@State`, refreshed by its load task) or Task-hops (`Task { await
  ... }`) in buttons, menus, and onChange handlers. `DeletionConfirmationCoordinator`
  loads impacts asynchronously; `evaluate()` stayed main-actor.
- **Test suite repair.** About 350 flipped call-shape diagnostics across
  106 test files; signature-manifest fixtures re-pinned to the async
  shapes; the identifier-boundary positive fixture now exercises the
  async protocol surface.

Fixed during convergence: `QueueStore.loadRecent` orders same-tick
completions deterministically (`finished_at DESC, queue, id`), and the
golden-master exporter dumps queue rows in a script-derived order so
concurrent-job completion timing cannot change the artifact.

## Verification

- `make build` green; `make lint` 0 violations in 758 files.
- `make test` green: 4,675 tests in 485 suites, 0 issues (223 s,
  `--parallel`), repeated across the final convergence runs.
- Golden master matches the committed baseline artifact; the exporter is
  deterministic across fresh runs.
- Remaining P1 work: the delayed-store semantics suite (P1.4) per
  `tmp/p1-delayed-store-design.md`, then the implementation review pass
  with a non-authoring model family before the PR.
