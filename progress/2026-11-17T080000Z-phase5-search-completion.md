---
timestamp: 2026-11-17T080000Z
title: Phase 5 search completion — daemon-only fused search, upgrade, and zero-waiver closes
branch: feature/daemon-only-p1-async-store
status: complete
---

# Phase 5 search completion — daemon-only fused search, upgrade, and zero-waiver closes

## Progress

Phase 5 of plans/daemon-only-access.md is implemented on this branch (not yet
merged). The app's search paths now consume daemon replies only, the
`upgradeSearchIndex` embedding backfill runs in the daemon, and the
sole-writer milestone's four client-side access rows are all `none` with the
`allowLocalStore` override deleted.

**Daemon-side fused search (5.1).** The store family's three hybrid searches
(`searchSimilar`, `searchSimilarChats`, `searchSimilarSources`) resolve the
Tantivy BM25 leg DAEMON-side: `DaemonStoreCommandExecutor.dispatchFusedSearch`
queries the wiki's `DaemonSearchRuntime` and maps best-first hits to typed
summaries through the store's own catalog (the same shape
`DaemonDomainCommands.searchLeg` has always used for the CLI families). A
client-supplied leg still wins (CLI-fixture callers), and a runtime failure
degrades to a nil leg — semantic-only, the documented degradation. The
semantic leg itself was already daemon-side: the daemon's store embeds the
query through the process-global `EmbeddingService`, loaded via the
WikiFSMLX bootstrap (`wikid.xpc` is a model-host bundle). The app's client
side lost `resolveTantivyLeg`, `logShadowComparison`, the
`searchSimilarResolvingTantivy` wrapper, and the read-pool search branch.

**Deterministic embedder fixture.** `DaemonFusedSearchTests` and
`SearchUpgradeProgressEventTests` run the in-process fixture daemon with
`EmbeddingService.installTestEmbedder` (the existing `#if DEBUG` hook) and a
fixed-vector keyword embedder — no MLX model anywhere in the standard suites.
The optional real-MLX smoke run (bundled wikid.xpc, not a gate) stays
documented in the plan.

**upgradeSearchIndex as a daemon operation (5.2).** A new `.events`-family
store op `upgradeSearchIndex` (beside `sinkHandshake` — daemon-scoped, not a
`WikiStore` requirement) starts `DaemonSearchUpgradeRunner`: single-flight per
wiki, detached embed loop, cancelled on wiki eviction. Progress flows as
`wikid.search-upgrade-event.v1` envelopes on the event firehose — a NEW
envelope kind following the 2c pattern (the wire marker value is the
discriminator; delivery-only, no watermark, the terminal
`complete`/`failed` state resolves the client). The reply is a typed outcome
(`started` + scanned total / `notNeeded` / `embedderUnavailable`). The app
model's `SearchUpgradeState` is a direct event projection
(`applySearchUpgradeProgress`), wired by `RemoteStoreSessionComposition`
through `RemoteWikiStore.onSearchUpgradeEvent`; the model's trigger seam is
the injected `startSearchUpgradeBackfill` closure (WikiFSCore cannot see the
daemon contract or WikiCtlCore). The app's local MiniLM embed loops
(`embedAndStore`, `embedChunksOffMain`) are deleted.

**Chat sidebar search (5.3).** The model's `scheduleChatSearch` consumes the
daemon's fused `searchSimilarChats` — the same daemon-side execution the CLI
`chat.search` op (`DaemonDomainOperation.Chat.search`) performs, minus one
new XPC surface: the chat domain family stays the CLI transport, the store
family is the app transport, and both execute the identical store seam in the
daemon. (Deviation note: the plan names the `chat.search` op as the app's
route; wiring it would have required a new XPC selector duplicating typed
store-family replies. Flagged for human review.)

**WikiReadService removal (5.4).** Deleted with its file. Consumers moved:
scheduleSearch/source/chat (daemon-fused replies), the UI metadata hydration
in four detail views (store-mediated wire reads; `MetadataHydrationReadPath`
removed), the reader's transclusion embeds (new async
`TransclusionEmbedder.renderEmbedBody(store:)` over the protocol), and
`QueueClosedWikiNameLoader` (a daemon-mediated reader over the shared store
transport, injected into `QueueActivityTracker`). `StorePlugin` no longer
provisions a read service; `StoreServiceKeys.readService` is gone;
`PerWikiRuntimePlugin` no longer requires it.

**App Tantivy assembly removal (5.5).** `SearchCompositionOwner` and
`PerWikiSearchFactory` are deleted; `PerWikiRuntimePlugin` supplies only the
launcher factory; `AppServices` lost `readService`/`searchFactory`/
`searchProviders`; `WikiDaemon.makeSearchRuntime` builds identity + content
source directly from the admitted store (same `search-index/<wikiID>` layout).
The app catalog no longer mounts `TantivySearchPlugin`
(`bundles/wikifs-app/cordis.patch.yml` entry removed); the CLI/fixture tiers
keep their intentional local runtime. The freedom guards extend to
`SearchRuntimeCompositionFactory.swift` (CLI-owned waiver) and pin the
deletion.

**allowLocalStore deletion.** `StoreModeConfiguration` pins
`resolvedMode = .remote` unconditionally; the capture function, env override,
and compile-time constant are gone (referencing them is a compile error).
WikiFSApp has no local branch; `RemoteStoreSessionComposition.enabled` is a
constant. `StoreModeConfigurationTests` pins the constant plus the runtime
daemon-down stability half. Test tiers keep explicit `.local` compositions
via catalog parameters.

**Boundary tightening.** `ClientLocalOpenBoundaryTests` now asserts ZERO
client-side store, read-pool, queue, provider-invocation, and Tantivy-writer
opens across a real session-level run (navigation, import, all three
searches, upgrade trigger, registry reads) with the daemon UP, and again
after the daemon goes DOWN mid-session (typed failures via a gate that stops
replying; the transport timeout backstop answers). The positive control
drives each seam's recording closure directly — a disconnected seam cannot
fake a zero. The app container never gains the wiki database file.

## Verification

Gates, all green on this machine:

- `swift build` (via `make build` prerequisite chain) — clean.
- New suites: `DaemonFusedSearchTests` 4/4 (fused ordering with a
  both-legs-wins RRF proof + pure-cosine contrast, rebuild-before-query
  freshness, embedder-failure degradation to BM25-only, chat/source fusion);
  `SearchUpgradeProgressEventTests` 5/5 (event stream shape, phase order,
  single-flight re-trigger, typed no-ops, model sheet projection).
- `ClientLocalOpenBoundaryTests` 3/3 with the P5 column (zero opens up and
  down).
- Existing search suites: `TantivyBM25LegCutoverTests`,
  `SourceEmbeddingSearchTests`, `SemanticSearchSwiftCosineTests`,
  `DaemonSearchTests`, `DaemonSearchClientTests` — green (store-level leg
  seam unchanged; the deleted piece was only the client-side resolver).
- Updated contracts: `StoreModeConfigurationTests`,
  `AppStoreFreedomContractTests` (P5 waiver column + deletion pins),
  `RemoteStoreSurfaceExhaustivenessTests` (8 infrastructure/events ops),
  `DaemonStoreOpsCompletenessTests` (ledger classifies
  `upgradeSearchIndex`), `DaemonProfileBootTests` (plugin contract pin),
  `MetadataHydrationTests`, `QueueClosedWikiNameResolutionTests`,
  `StorePluginBootTests`, `SessionOpenLatencyBudgetTests`,
  Cordis boundary/doc-contract tests.
- `make lint` — 0 violations.
- Full `make test` — "✓ tests pass", 4714 tests in 492 suites, 0 issues. The
  first full run surfaced one cross-suite flake: `EmbeddingService`'s test
  embedder seam is a process global, and parallel suites' install/reset
  collided (one suite's search saw another suite's reset). Fixed with
  `EmbedderSeamGate` (an actor-based cross-suite claim gate in
  `Tests/WikiFSTests/Support/`) adopted by all three embedder-using suites;
  the re-run was fully green.

Known scope notes for review: the P4 store-plugin comment said the read pool
stays "through P4" — that comment is gone with the pool; the wire
`bm25Leg` request fields remain (legacy/CLI-fixture callers and the store
protocol's injection seam); detached daemon upgrade runs are cancelled at
wiki eviction and deliver a terminal `failed` event, so a client sheet always
resolves.
