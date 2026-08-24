# Cordis Phase 5b Status

## Completed

Stage 1 added `scripts/check-cordis-boundaries` and `make check-cordis`.

The default check verifies the current violation baseline. The `--strict` option rejects all `RuntimeAssembly` references and all `WikiSession` construction sites.

`CordisBoundaryScriptTests` runs the default check from Swift Testing.

## Stage 2 status

Stage 2 remains in progress. No assembly or `WikiSession` file was deleted.

The app now starts an observable `AppProcessProfileOwner` alongside the legacy synchronous composition. The owner boots all five app process entries asynchronously, exposes idle/loading/ready/failed readiness plus the booted profile and typed process services, owns its startup task, and joins app termination shutdown. Fixture tests cover readiness, resolved services, failure, and idempotent disposal.

`ProfileWikiSession` is the complete observable per-wiki facade for the next loader cutover. It boots an app child profile from the process profile, uses the child profile's store and read pool, uses inherited process extraction, queue, and provider services, and covers the full `WikiSession` surface: descriptor updates, store model, launcher, generation gate, search lifetime, vacuum state, and deferred wiki-link state. It temporarily delegates behavior to `WikiSession`, as this increment permits, so the boundary baseline now lists that approved compatibility construction site. Strict mode still rejects it. `SessionManager` and views are not rewired in this increment.

Steps 1–9 are complete. The production catalogs own executable-side factory injection and typed service resolution.

The process-lifetime gap is complete. Process profiles now own provider, extraction, queue, transport, and renderer runtime services.

Per-wiki profiles now boot in a child Cordis context. The child resolves process services from its parent context.

The app and daemon profile tests boot this two-level graph. The tests also verify that child shutdown does not stop process services.

The async session-readiness gap is complete. `SessionManager.readySession(for:descriptor:)` exposes idle, loading, ready, and failed states.

The async accessor supports an injected child-profile loader. Its default path keeps the legacy synchronous session construction for this slice.

Steps 10–11 remain incomplete because the app views still call the synchronous accessor. The next slice will install the child-profile loader and update those callers.

The daemon part of step 12 remains incomplete. `WikiDaemon` still owns the provider and extraction assemblies.

The CLI Tantivy path boots `CLIPluginCatalog`, resolves the Tantivy provider, and stops the profile.

## Remaining assemblies and callers

- `Sources/WikiFSEngine/AgentProviderRuntimeAssembly.swift`
  - `Sources/WikiFS/Window/WikiFSApp.swift` creates it.
  - `Sources/wikid/WikiDaemon.swift` creates it.
- `Sources/WikiFSEngine/ExtractionRuntimeAssembly.swift`
  - `Sources/WikiFS/Window/WikiFSApp.swift` creates it.
  - `Sources/wikid/WikiDaemon.swift` creates it.
  - `Sources/WikiFSEngine/ExtractionPlugins.swift` uses its factory type aliases.
- `Sources/WikiFSEngine/QueueRuntimeAssembly.swift`
  - `Sources/WikiFS/Window/WikiFSApp.swift` creates it.
- `Sources/WikiFSEngine/SearchRuntimeAssembly.swift`
  - `Sources/WikiFSEngine/SearchCompositionOwner.swift` owns it.
  - `Sources/WikiFSEngine/SearchRuntimeRegistry.swift` accepts it.
  - `Sources/WikiFSEngine/SearchServiceKeys.swift` returns it from a factory.
  - `Sources/WikiFSEngine/SearchPlugins.swift` creates it.
  - `Sources/WikiCtlCore/CLITantivyLegResolver.swift` creates it.
- `Sources/WikiFSEngine/DaemonTransportRuntimeAssembly.swift`
  - `Sources/WikiFS/Window/WikiFSApp.swift` creates it.
- `Sources/WikiFS/Renderer/RendererRuntimeAssembly.swift`
  - `Sources/WikiFS/Window/WikiFSApp.swift` creates it.

## Privileged core

`Sources/WikiFSEngine/WikiSession.swift` still constructs these domain services directly:

- the store backend and `WikiStoreModel`
- the event bus and read pool
- the Tantivy content source and search composition owner
- the generation gate and agent launcher

`Sources/WikiFSEngine/SessionManager.swift` is the only `WikiSession` construction site. App views and models still use `WikiSession` as their service facade.

## Entry points

`Sources/WikiFS/Window/WikiFSApp.swift` still starts provider, extraction, queue, transport, renderer, and session composition directly.

`Sources/wikid/main.swift` creates `WikiDaemon`. `Sources/wikid/WikiDaemon.swift` starts extraction and provider assemblies.

`Sources/wikictl/main.swift` resolves `--dump-config` through `ProfileBundle`. Normal commands do not boot a profile. `Sources/WikiCtlCore/CLITantivyLegResolver.swift` still creates the search assembly.

## Required next steps

1. Move assembly-owned factory type aliases into service-key or plugin-factory types.
2. Add production catalog builders for the app, daemon, and CLI targets.
3. Inject app-only factories into the app catalog.
4. Inject daemon-only factories into the daemon catalog.
5. Add fixture-safe app and daemon profiles for boot tests.
6. Add `AppProfileBootTests` and `DaemonProfileBootTests`.
7. Test store event delivery and disposal with the production catalogs.
8. Add the two-profile identity test for one changed configuration row.
9. Add an `AppServices` facade that resolves services from `BootedProfile.context`.
10. Change `SessionManager` to request the per-wiki facade from a child Cordis context.
11. Change app views to use the facade instead of `WikiSession`.
12. Change `WikiDaemon` and CLI search to resolve services from booted profiles.
13. Delete `WikiSession.swift` and all six runtime assembly files.
14. Remove assembly entries from `CordisPolicyTests`.
15. Make the boundary script strict by default and remove its baseline.
16. Run `make build`, `make test`, and `scripts/check-cordis-boundaries --strict`.

## Final-slice investigation

The final-slice branch is `feature/cordis-5b-delete-privileged-core` at `8c7bf5fc`.
The worktree was clean before the investigation.

The current `AppServices` type is not a replacement for `WikiSession`.
It resolves the raw store, read pool, extraction backend registry, and search provider registry.
`WikiSession` also owns the observable store model, descriptor state, launcher, generation gate, and search lifetime.
It also owns vacuum state and deferred wiki-link state for the app views.

`WikiFSApp.init` creates all process owners synchronously.
`CordisBoot.boot` is asynchronous.
The app therefore needs an asynchronous process-profile readiness owner before it can resolve process services safely.

All six runtime assembly types still have production callers and assembly-specific tests.
The catalog defaults also reference `SearchRuntimeAssembly.runtimeFactory`.
Deleting these files first would leave the tree incomplete.

No production conversion or deletion was made during this investigation.
The next safe sequence is:

1. Add a retained asynchronous process-profile owner for the app.
2. Add a per-wiki observable facade that owns the current `WikiSession` application state.
3. Build that facade only from child-profile services and process-profile services.
4. Change `SessionManager` and app views to use the facade.
5. Change the daemon and CLI owners to use profiles.
6. Move standalone factory implementations out of all runtime assembly files.
7. Replace assembly-specific tests with plugin and profile tests.
8. Delete `WikiSession.swift` and all runtime assembly files.
9. Make the boundary script strict by default.
10. Run all required gates after each commit.

## Verification at this checkpoint

`make build` and `make test` passed after Stage 1. The full suite ran 3,563 tests in 357 suites.
The final-slice investigation changed documentation only. Gate results for this documentation checkpoint follow in the commit history.
