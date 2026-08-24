# Cordis Phase 5b Status

## Completed

Stage 1 added `scripts/check-cordis-boundaries` and `make check-cordis`.

The default check verifies the current violation baseline. The `--strict` option rejects all `RuntimeAssembly` references and all `WikiSession` construction sites.

`CordisBoundaryScriptTests` runs the default check from Swift Testing.

## Stage 2 status

Stage 2 is not complete. No assembly or `WikiSession` file was deleted.

Steps 1–8 are complete. The production catalogs now own executable-side factory injection.

Step 9 is complete. `AppServices` resolves typed services from a `BootedProfile` and keeps the Cordis context behind the facade.

Step 12 is partly complete. The CLI Tantivy path now boots `CLIPluginCatalog`, resolves the Tantivy provider, and shuts down the profile.

Steps 10–11 are not complete. `SessionManager` and `WikiSession` still use the legacy app composition path.

The daemon part of step 12 is not complete. `WikiDaemon` still owns the provider and extraction assemblies.

The current catalogs expose provider registries, not the final queue, extraction, transport, renderer, and agent operation facades. The app and daemon startup code still needs those facades and process owners before profile boot can replace the legacy lifetimes safely.

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

## Verification at this checkpoint

`make build` and `make test` passed after Stage 1. The full suite ran 3,563 tests in 357 suites.
