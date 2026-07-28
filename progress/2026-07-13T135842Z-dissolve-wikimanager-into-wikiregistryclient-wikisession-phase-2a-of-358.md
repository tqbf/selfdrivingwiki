---
timestamp: 2026-07-13T135842Z
title: "2026-07-13 — Dissolve `WikiManager` into `WikiRegistryClient` + `WikiSession` (Phase 2a of #358)"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-07-13 — Dissolve `WikiManager` into `WikiRegistryClient` + `WikiSession` (Phase 2a of #358)

## Progress


**The type split is implemented.** The plan lives at
`plans/dissolve-wikimanager.md`. `WikiManager` (app-scoped monolith bundling
registry + active store + side effects) is dissolved into two focused types:

- **`WikiRegistryClient`** (`Sources/WikiFSCore/WikiRegistryClient.swift`) —
  app-scoped, `@MainActor @Observable`. Owns the wiki list (`wikis`), the
  active wiki id (`activeWikiID`), and the create/select/delete/rename/
  export/import operations. Never opens a store itself (no `activeStore`,
  no `openActive`). FP domain closures (`registerDomain`/`removeDomain`/
  `renameDomain`) + a `flushActiveStore` closure are injected from the app
  layer. `WikiManagerError` → `WikiRegistryError` (moved into the same file).
- **`WikiSession`** (`Sources/WikiFSEngine/WikiSession.swift`) — per-active-wiki,
  `@MainActor @Observable`. Holds the store (`WikiStoreModel`), per-session
  `AgentLauncher` pair, per-session `GenerationGate`, shared
  `ExtractionCoordinator` ref, and the vacuum/GC + search-upgrade state.
  `init` does what `WikiManager.openActive` did (open store, attach bus,
  create model, create read pool, create launchers, seed Home page). Each
  session has its own gate → structural per-wiki isolation (a long ingest in
  one wiki cannot block a query in another).

**What moved where:**
- `wikis`/`activeWikiID` → `WikiRegistryClient`
- `activeStore` → `WikiSession.store`
- `pendingBlobVacuum`/`pendingVacuumAll` → `WikiSession`
- `upgradeActiveStoreSearchIndex` → `WikiSession.upgradeSearchIndex()`
- `openActive` → `WikiSession.init` (called from the app's `.onChange(of:
  registry.activeWikiID)`)
- v0 migration, FP domain closures, `registerAllDomains` → `WikiRegistryClient`
- `WikiManagerError` → `WikiRegistryError`

**Files changed (21 total):**
- 2 new: `WikiRegistryClient.swift`, `WikiSession.swift`
- 2 deleted: `WikiManager.swift`, `WikiManagerError.swift`
- 17 modified: `WikiFSApp`, `RootView`, `ContentView`, `SidebarView`,
  `WikiSwitcher`, `WikiDetailView`, `PageDetailView`, `ChatView`, `LintView`,
  `SourcesContainerView`, `SourcesListView`, `PagesContainerView`,
  `PagesListView`, `ExtractionCompareSheet`, `VacuumCommands`,
  `WikiChangeBridge`, `WikiStoreModel`
- Tests: `WikiManagerTests` → `WikiRegistryClientTests` (17 tests) +
  `WikiSessionTests` (7 tests) + `WikiChangeBridgeTests` (2 tests). All 26 pass.

**What does NOT change:** the daemon (`wikid`), the File Provider extension,
`wikictl` store writes, Darwin notification routing, the SQLite concurrency
invariants, agent config, the single `WindowGroup` (multi-window is Phase 2b).

## Verification

Historical verification remains in the progress record above.
