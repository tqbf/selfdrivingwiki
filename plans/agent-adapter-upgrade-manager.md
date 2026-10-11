# In-app ACP adapter upgrade manager

Status: planned. The one-off codex-acp 2.2.2 bump (#1401) fixed the
snapshot and the version predicate. This plan removes the gap that
remains: a provider command is frozen in stored settings at add-time,
so existing installs keep launching an old adapter until the user
re-adds it by hand.

## Problem

`AgentProvider.acp(from:)` copies the catalog command verbatim into
stored settings when the user adds a provider
(`AgentProvider.swift:100`). Nothing revisits that command later. The
upstream agents release constantly — codex-acp shipped 2.2.2 the day
after 2.2.1 — so hand-maintained pins rot within days, and each rot
reproduces the stale-model-metadata failure class (#1396 follow-up).

## Existing machinery (reuse, do not rebuild)

- `ACPRegistryClient.loadAgents()` (#665): live registry from
  `cdn.agentclientprotocol.com/registry/v1/latest/registry.json`, 24h
  cache TTL, stale-cache → bundled snapshot → fallback chain. Entries
  carry the exact package spec per agent (`npx`/`uvx` distribution).
- `CodexThinkingCapabilityAdapter.supportedVersions` and the
  fingerprint system (`ACPAgentFingerprint`, `agentInfo` observations
  in `AgentProviderModelCache`): the compatibility contract between
  this app's interpreter code and an agent version.
- `ACPProviderModelProbe`: launch-time model discovery.
- `PackageRunnerKind` / launch-plan machinery: safe subprocess shapes.

## Prior art

- **Paseo managed Git plugins** (strongest): stage a candidate at an
  exact revision, validate it, activate only after success, restart
  the old version on failure, delete the old version last. Atomic
  pointer file. This is the runtime loop to copy.
- **Paseo ACP catalog drift checker** (`check-acp-catalog-*
  version-drift.mjs`): release-time script queries npm/PyPI and
  rewrites exact pins; binaries skipped as user-owned. Copy as a CI
  job shape.
- **Paseo app updater** (UX contract): silent check, explicit adopt,
  no silent downgrades, revalidate before install.
- **Zed**: registry-driven exact-version installs with background
  refresh — never floating `@latest`.

## Design: adopt the newest version that passes

Never float. Launch commands stay exact pins. A scheduled loop adopts
a newer pin only after the candidate passes the compatibility gate.

### Trigger

1. After `ACPRegistryClient` refreshes (24h TTL) at app launch.
2. A manual "Check for Adapter Updates" action in Settings (bypasses
   backoff, like Paseo's manual checks).

### Per-provider decision (pure function, unit-testable)

Input: stored `AgentProvider` command, live registry entry for the
same agent identity, this build's adapter predicates. Output: one of

- `upToDate` — registry spec equals stored spec.
- `notApplicable` — command is not a registry package spec (plain
  binary such as `gemini acp` is user-owned; skip like Paseo does).
- `updateAvailable(knownSupported)` — registry is newer and every
  registered adapter predicate for that identity admits the version.
- `updateAvailable(unsupported)` — newer but this app build cannot
  interpret it yet (e.g. a future 3.0 with changed conventions).
  Surface in UI; never auto-adopt. The app update that widens the
  predicate unlocks adoption — deliberate coupling, as today.

### Probe before adopt

For `updateAvailable(knownSupported)`, spawn the candidate once
through the normal launch-plan machinery with a short timeout and an
ACP initialize handshake only — no model traffic, no auth. Verify:

1. Reported `agentInfo` identity matches the registry entry.
2. Version satisfies the predicates (defense in depth; the candidate
   on disk could differ from the registry claim).
3. Model enumeration returns non-empty.

Any failure or timeout: keep the stored command, log through
`DebugLog.agent`, record the failure (with count/backoff so a broken
upstream release cannot loop probes).

### Adopt and roll back

On probe success, write the stored provider command atomically
(temp-file + rename, same primitive class as the rest of the store).
Persist an adoption record — provider, from-spec, to-spec, date — and
show it in Settings with a one-click **Restore previous command**
action. Adoption writes stop while a chat using that provider is
live; the next launch picks the new pin (matches the app's
restart-to-pick-up model for backends).

### State modeling

Typed, per the house rules: an `AdapterAdoptionRecord` with
namespaced ids, no stringly-typed specs; the decision output is an
enum, not flags. Stored inside the existing provider settings
migration envelope so older configs load unchanged.

## CI complement

A weekly workflow fetches the live registry and opens a PR when
`Resources/acp-registry.json` drifted (the bundled offline fallback
must not rot the way 1.1.4 did). Report-only elsewhere; no CI writes
to main.

## Testing

- Decision function table tests: up-to-date / newer-supported /
  newer-unsupported / non-package / offline (no registry → no-op).
- Probe seam injected; no network in unit tests. Failure paths:
  handshake timeout, identity mismatch, predicate rejection, empty
  models.
- Adoption write + rollback round-trip through the settings store.
- App-target wiring test: the Settings surface renders all four
  decision states from fixtures.

## Acceptance criteria

1. After this ships, a user who never touches Settings converges to
   the newest predicate-supported adapter within one registry TTL.
2. A candidate that fails the probe never changes the stored command.
3. A supported-version adoption is reversible in one click.
4. An unsupported major is visible in Settings but never auto-adopted.
5. No launch command is ever a floating tag.
