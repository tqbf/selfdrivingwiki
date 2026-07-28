---
timestamp: 2026-07-20T013800Z
title: "2026-07-19 — Per-operation provider overrides (chat / ingest / lint) (branch `per-op-provider`, PR #704)"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-07-19 — Per-operation provider overrides (chat / ingest / lint) (branch `per-op-provider`, PR #704)

## Progress


**Problem.** A single shared `defaultProvider` was used for all three ACP
operations (chat / ingest / lint). Changing the default for one operation
changed it for all three. The `AgentProvidersConfig` config model and the
spawn path offered no per-operation surface, and the `PermissionsSettingsView`
had no UI for setting one.

**Fix.** Add three optional per-operation provider id fields to
`AgentProvidersConfig` (`chatProviderId` / `ingestProviderId` /
`lintProviderId`), each falling back to `defaultProvider` when the pin is
`nil` OR points at a deleted provider (no dangling references). Each
operation resolves its OWN provider at spawn time through the new resolvers,
then reads `selectedModelId(forProvider:)` on that provider and feeds both
into `SpawnModelGuard` (unchanged validation).

### Config — `Sources/WikiFSCore/Core/AgentProvidersConfig.swift`

- New optional `Codable` fields: `chatProviderId` / `ingestProviderId` /
  `lintProviderId`. Forward-compatible — old configs without these keys
  decode to all-`nil`, and every operation routes to `defaultProvider` (the
  legacy behavior). No migration, no behavior change for existing users.
- New resolution methods: `providerForChat()` / `providerForIngest()` /
  `providerForLint()`, each:
  ```swift
  chatProviderId.flatMap { provider(id: $0) } ?? defaultProvider
  ```
  — falls back to `defaultProvider` when the pin is `nil` OR points at a
  provider that no longer exists.
- New PURE setters: `settingChatProvider(id:)` / `settingIngestProvider(id:)`
  / `settingLintProvider(id:)`. Whitespace is normalized to `nil`; empty/
  whitespace clears the pin. NEVER validates that the pinned id exists —
  the resolver falls back when a pinned id is later deleted, so accepting
  an unknown id here is safe (and a re-add of the same id later just starts
  working again).
- The three new fields are carried through ALL existing setters
  (`settingDefault` / `settingCachedModels` / `settingSelectedModel` /
  `togglingFavoriteModel`) and through `loadOrSeed` so a Settings edit
  doesn't silently wipe an operation's pin.

### Spawn path — `Sources/WikiFSEngine/AgentLauncher.swift`

- `startInteractiveQuery` (chat): `providersConfig().providerForChat()`
- `runACPIngestPlannerExecutors` (multi-phase large-source ingest):
  `providersConfig().providerForIngest()`
- `run()` single-session (covers `.ingest` + `.lint` / `.lintPage` + a
  defensive `.query` branch): switches on `permissionKind` to pick
  `providerForChat/Ingest/Lint()`.
- New launcher wrappers `setChatProvider(id:)` / `setIngestProvider(id:)` /
  `setLintProvider(id:)` mirror `setDefaultProvider(id:)`'s load→mutate→save
  shape + `DebugLog` error path.

### UI — `Sources/WikiFS/Settings/PermissionsSettingsView.swift`

- New "Provider Assignment" section next to the existing "Permissions"
  section, with a Provider + Model picker per operation.
- Provider picker lists `config.enabledProviders` plus a leading
  "Default (Claude)" row (the `nil` pin = legacy behavior). Selecting it
  clears the pin.
- Model picker lists the resolved provider's cached models plus an
  "Agent default" row (clears the per-provider model selection). When no
  models are cached, displays "Chat with this provider once to discover
  models" and is disabled.
- `containerDirectory` is threaded in from `WikiFSApp`; loads config on
  init + on appear.
- `persist()` uses `do/catch + DebugLog` per the house rule against bare
  `try?`.

### Tests

- NEW `Tests/WikiFSTests/AgentProvidersConfigPerOpProviderTests.swift`
  (25 tests): resolution fall-back to `defaultProvider` when pin is `nil`;
  resolution fall-back when the pinned provider was deleted (the
  "no dangling references" AC); setter round-trip + `nil`/whitespace
  normalization; carry-through across existing setters; Codable
  backward-compat (a pre-per-op-provider `agent-providers.json` decodes to
  all-`nil`); round-trip through disk; `loadOrSeed` carry-through (including
  a stale pin pointing at a deleted provider — preserved on disk, falls
  back at read time).
- Updated `Tests/WikiFSTests/AgentLauncherSpawnRefusalTests.swift` +
  `ChatViewPreflightBannerTests.swift`: the chat-path spawn refusal used to
  inject `launcher.resolveSelectedProvider` to override the provider. With
  per-op-provider, the chat path now resolves via
  `providersConfig().providerForChat()`, so the no-model scenario is set up
  by pre-writing an `agent-providers.json` whose default provider is
  opencode with no `selectedModelIds` entry — `providerForChat()` returns
  opencode (no chat pin → fallback to default) and the guard fires on the
  nil-model state. Same observable contract (`preflightError != nil`,
  `isRunning == false`); the setup change reflects the actual seam the
  spawn path now reads.

### Verification

- `make version prompts` ✓
- `swift build` ✓ (clean, 0 errors / 0 warnings)
- `swift test` (full suite) — **3092 tests / 262 suites pass** (~33 s).
  No regressions.

### Status

PR #704 open (branch `per-op-provider`), not merged.

---

## Verification

Historical verification remains in the progress record above.
