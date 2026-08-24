# Cordis Final Extension

Status: implemented and amended by
`plans/cordis-composition-authority-cleanup.md`.

## Purpose

This extension removes the last production service construction paths outside Cordis profiles. The daemon now resolves wiki stores and launcher factories from per-wiki child profiles. The CLI now resolves ordinary command stores from a request-scoped CLI profile.

Cordis remains a composition boundary, not a global service locator. Normal application code receives typed services or a narrow runner. It does not receive a `CordisContext`.

## Daemon creation and store contract

Production wiki creation uses `StoreBootstrap`. Bootstrap creates and seeds the
database artifacts without returning a live store connection.

`DaemonWikiCreationCoordinator` owns create admission and rollback. It reserves
the wiki ID, bootstraps the database, saves the registry, and boots the child
profile. It publishes the resolved child-profile services only after all steps
succeed.

A failed or canceled create removes unpublished services and the registry
entry. It also deletes the database, WAL, and shared-memory files. Cleanup
errors remain visible without replacing the primary creation error.

The daemon uses the exact store that the child profile supplies. Production
code has no injected `makeStore` path. Explicit test and Linux fixture APIs own
the remaining synchronous compatibility behavior.

## Launcher factory contract

The per-wiki profile supplies `LauncherServiceKeys.factory` with the fixed label `wiki.launcher-factory`. The service value is a Sendable `LauncherFactory`. It creates main-actor `LauncherPair` values without storing those objects in Cordis.

Each factory call returns a new `GenerationGate` and `AgentLauncher`. A daemon chat host calls the factory once and reuses that pair for its wiki session. Queue ingestion calls the factory once for each operation.

Chat RPC requests carry an explicit `WikiID`. `WikiDaemon` keeps one chat host for each wiki. It never searches hosts by chat ID and never falls back to another wiki.

Removing a wiki stops only that wiki's host. Daemon shutdown drains all hosts before it disposes the profile owner.

## CLI profile contract

`WikiCtlRunner.runOrdinary` resolves the selected wiki through `WikiResolver`. It then calls `CLIStoreProfile.withStore`.

`CLIStoreProfile` boots the CLI profile with one ambient store entry. It resolves `StoreServiceKeys.store`, runs one command, and shuts down the profile.

The profile shuts down after command success and command failure. A successful command reports a shutdown error. If the command and shutdown both fail, `CLIStoreProfileError.operationAndCleanup` preserves both errors.

The runner returns stdout bytes, stderr bytes, and an optional changed wiki ID. The executable writes those bytes and posts the Darwin change notification. The runner does not own process I/O.

`--dump-config` keeps its previous fallback. It can dump the shipped configuration when the App Group container is unavailable.

## Store bootstrap boundary

`StoreBootstrap` is the named database creation boundary for `wiki create`. It uses `StoreBackend` to create the concrete store. It seeds `Home` only when the database has no pages.

`WikiCtlRunner.runWikiCreate` calls this boundary, stores the returned home-page ID in the registry descriptor, and saves the registry. No concrete store initializer appears in `wikictl/main.swift`.

## CLI test seam

The runner accepts four injected boundaries:

- container resolution
- CLI profile boot
- store bootstrap
- command execution

The integration tests use real Cordis activation. They verify exact store identity, one profile disposal after success or failure, and combined operation and cleanup failures. Separate runner tests verify dump-config formatting and seeded wiki creation.

Cordis kernel tests own registration-order settlement. The CLI tests do not repeat that kernel contract.

These tests replace positive source-text assertions. The boundary script retains negative source-policy tests for forbidden constructors.

## Deliberate non-Cordis boundaries

The following construction sites remain outside a profile:

- `StoreBackend` selects the concrete store implementation.
- `WikiReadService` privately owns read-only pooled database connections.
- File Provider `Projection` creates query-only stores in a separate extension process.
- `WikiRegistryClient` uses an injected store factory before a wiki profile exists.
- `ProfileWikiSession` and `SessionsPlugin` retain synchronous test-fixture factories.
- `TransclusionEmbedder` documents its read-only projection boundary.
- `wikid/main.swift` retains the optional Linux stdio fixture factory.
- `RendererCompositionOwner` retains its app UI-shell launcher adapter.
- App UI-shell coordinators remain outside Cordis by design.

The boundary script lists each exception with its reason. It rejects concrete store and launcher construction at the migrated daemon and CLI paths.

## Verification contract

The implementation requires these gates:

- `make build`
- `make test`
- `make check-cordis`
- `WIKIFS_APP_TESTS=1 swift test`

Focused tests also cover daemon bootstrap rollback, exact child-profile store
identity, launcher routing, CLI lifecycle, registration order, and synthetic
boundary violations.
