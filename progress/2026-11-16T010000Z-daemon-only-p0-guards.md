---
timestamp: 2026-11-16T010000Z
title: Daemon-only access Phase 0 — guards, open-seam harness, baselines
branch: feature/daemon-only-p0-guards
status: draft
---

# Daemon-only access Phase 0 — guards, open-seam harness, baselines

## Progress

Phase 0 of `plans/daemon-only-access.md` (approved plan revision 2) is
implemented:

- **Source-level freedom guards.** `AppStoreFreedomContractTests` (app target
  plus the four app-reachable engine composition files),
  `FileProviderStoreFreedomContractTests`, and `WikiCtlStoreFreedomContractTests`
  parse guarded sources and assert every forbidden storage-construction token
  (`GRDBWikiStore(`, `GRDBWikiStore(readOnlyURL:`, `WikiReadService(`,
  `QueueStore(`, `TantivyIndexer(`, `StoreBackend.current.makeStore`) is
  covered by an exact-count waiver naming its clearing phase (P3/P4/P5/P6).
  The CLI guard has ZERO waivers from day one. The shared engine
  (`StoreFreedomGuardSupport`) matches most-specific-first with overlap
  subtraction; new violations, stale waivers, and count drift all fail.
- **Runtime open-seam harness.** `WikiOpenSeamRecorder` (WikiFSCore) counts
  opens at four client-reachable seams. Injection points added:
  `StorePlugin.StoreOpenFactories` (store + read-only factories) threaded
  through `AppPluginCatalogFactories.storeOpenFactories`;
  `WikiReadService.init(makeReadOnlyStore:)` for its private pool;
  `QueueRuntimeFactory.makeQueueStore` and an `AppQueueExtractionProvider`
  queue-store factory; `SearchRuntimeCompositionFactory.makeIndexer` (via the
  existing `makeTantivyRuntime` injection). Attribution is by injection —
  daemon/CLI compositions keep plain factories, so a recorded open is by
  construction a client open. `ClientLocalOpenBoundaryTests` boots the
  production process composition AND real per-wiki sessions through
  `AppProcessProfileOwner.bootWikiSession`, drives navigation, source import,
  search, index upgrade, and a queue assembly, and proves: positive control
  (every seam records when the local path is on — a disconnected seam cannot
  fake a zero), per-wiki label isolation, and a failing seam surfacing out of
  session boot. Later phases tighten the expected counts per the plan's
  permitted-access table; Phase 7 flips to zero.
- **Golden-master baseline.** `GoldenMasterStoreState` records one fixed
  fixture script (pages + CAS conflict + composed upsert, sources with
  duplicate-content typed error, markdown chain, protected unlink deletion,
  bookmarks, workspaces, strategy CAS + reset tombstone, chats, wiki index,
  log, queue rows, vacuums) and exports a normalized dump: state, script
  notes pinning typed errors, and the FULL `ResourceChangeEvent` sequence
  (ULIDs → `u<n>`, timestamps → `t*`). The committed artifact lives at
  `Tests/WikiFSTests/Fixtures/GoldenMasterStoreState/baseline.txt`;
  `GoldenMasterStoreStateTests` diffs every run against it and also proves
  byte-level determinism across fresh runs. Intentional behavior changes
  regenerate via `GOLDEN_MASTER_REGENERATE=1`.
- **Benchmark baseline.** `SessionOpenLatencyBudgetTests` (opt-in,
  `SESSION_OPEN_BENCHMARK=1`) records cold session open through the real
  `bootWikiSession` path, page open, sidebar search, and queue round trips.
  P0 local-store numbers recorded in `plans/daemon-only-access.md`; the P7
  budget gate is ≤ 1.25×.
- **Design record.** `plans/daemon-only-access.md` written: transport table,
  degradation model, permitted-access table, open-seam harness and guard
  inventory, placeholder op manifest / error mapping / event contract /
  chunking sections (filled at P2–P3), baseline artifacts, waiver history.
  `PLAN.md` indexes it.

Non-obvious decisions:

- The search writer seam is a DEAD PATH at app session boot today (sessions
  consume the daemon search facade), so the harness's positive control drives
  the search runtime factory directly to prove the seam stays connected.
- `appendPageVersion`'s amend-coalescing path amends the head IN PLACE for
  same-actor writes inside the window, so a stale-head write by the SAME
  actor does not conflict; the golden-master fixture uses a different author
  to exercise a real `PageConflictError`.
- Timestamps in the golden-master dump normalize to a constant (`t*`):
  per-value counters are not cross-run stable when two operations land in the
  same clock millisecond. Row order within each section carries the sequence.
- The recorder file's doc comments avoid the guarded token literals so the
  pre-existing `scripts/check-cordis-boundaries` allow lists stay untouched.

## Verification

- `swift build` and `swift build --build-tests` green.
- `./scripts/check-cordis-boundaries` green (allow lists unchanged).
- New suites green: `ClientLocalOpenBoundaryTests` (3 tests),
  `AppStoreFreedomContractTests`, `FileProviderStoreFreedomContractTests`,
  `WikiCtlStoreFreedomContractTests` (4 guard tests),
  `GoldenMasterStoreStateTests` (baseline comparison + determinism; the
  regenerate mode's intentional issue only fires under
  `GOLDEN_MASTER_REGENERATE=1`), `SessionOpenLatencyBudgetTests` (skipped
  without the env var; benchmark numbers recorded in the plan doc).
- Full `swift test` run green (5684 pass lines, zero recorded issues; the
  only remaining known issue is the pre-existing `make build` Metal-toolchain
  cryptex failure on this machine, unrelated to this branch — `swift build`
  compiles the full package including the mlx target).
