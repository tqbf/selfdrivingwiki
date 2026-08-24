---
timestamp: 2026-08-23T223000Z
title: Cordis kernel, loader, and store domain phases
branch: feature/cordis-full-architecture
status: complete
---

# Cordis kernel, loader, and store domain phases

## Progress

Branch `feature/cordis-full-architecture`. Commits:

- `feat(cordis): add typed event bus with mode-carrying keys` — Phase 1.
- `feat(cordis): add plugin catalog, config schemas, and boot loader` — Phases 2–3.
- `feat(cordis): add store domain plugin` — Phase 4.1.

What changed:

- `Sources/Cordis` gains a typed event bus: `EventKey<Payload, Mode>` with
  compile-time dispatch modes (`EmitMode`, `SerialMode`, `ParallelMode`,
  `BailMode`, `WaterfallMode`), reversible listeners
  (`ActivationContext.on`, `ComponentHandle.on`, `CordisContext.on`)
  disposed LIFO with their owning component, mid-flight effect registration
  (`ComponentHandle.effect`), and waterfall short-circuit semantics.
  Verified by `CordisEventsTests`.
- `Sources/Cordis` also gains `PluginID`, `PluginConfig` +
  `ConfigValidation` (structured `ConfigIssue`s), `PluginDefinition`, and
  the link-time `PluginCatalog`.
- New `CordisLoader` target (Yams): `Entry`/`EntryID`, `PatchFile` +
  natural-shape YAML codec, `PatchResolver` layering (bundle → profile →
  home → `--patch`, whole-row replacement by id), `EntryTree` hot-swap on a
  live context, `CordisBoot` + `BootedProfile.dumpConfig()`. Verified by
  `CordisLoaderTests` (covers AC.2, AC.3, and config-swap groundwork for
  AC.5).
- Store domain (Phase 4.1): `wiki.store` plugin in `WikiFSEngine` supplies
  `ctx.store` (`any WikiStore`, GRDB via `StoreBackend`) and
  `ctx.readPool`, and bridges `WikiEventBus` emissions onto the typed
  `StoreEventKeys.resourceChange` Cordis event with reversible cleanup.

## Verification

- `swift test --filter CordisTests` — 52 tests passed (includes event
  suites and source policy).
- `swift test --filter CordisLoaderTests` — 9 tests passed.
- `swift test --filter StorePluginBootTests` — passed.
- `make build` — passed (signed app bundle).
- `make test` — 3,549 tests in 345 suites passed at the Phase 4.1 commit.

Remaining Phase 4 domains (sessions, llm, tools, prompt, agent loop,
extraction, search, renderers, transport, integrations), Phase 5
(bundles/profiles; delete `WikiSession` and the `*RuntimeAssembly.swift`
files), and Phase 6 parity gates are still open. Design record:
`plans/cordis-full-architecture.md`.
