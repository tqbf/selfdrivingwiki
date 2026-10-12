# Model probe isolation tiers

Status: shipped (PR #1408). This records the probe launch-isolation
policy and the true caller graph, corrected by the conceptual audit of
that PR.

## The two tiers

`ACPProviderModelProbe.LaunchIsolation` selects the launch plan for one
adapter probe:

- **`.sandboxedProduction` (default)** — the fail-closed sandbox-exec
  launch plan (issue #1276): front-end usability gate, read-only
  provider-home-layered profile, W^X scratch as the only writable tree,
  relocated TMPDIR. The fail-safe tier for any caller that does not
  explicitly choose.
- **`.manualRefreshUnsandboxed`** — Paseo parity for the explicit
  "Refresh Models" action: the canonicalized adapter command spawns
  directly. Every ACP refreshes without a per-adapter sandbox
  allowance.

## The caller graph (verified 2026-10-12)

- Settings "Refresh Models" (`ProviderDetailPane.refreshModels`) —
  the ONLY `.manualRefreshUnsandboxed` caller. Runs via
  `AgentProviderServices.discoverCatalog(for:isolation:)`.
- Chat-launch model capture — reads the CACHED catalog
  (`providerModels`); it does not probe through this type.
- The summarizer and transcript-cleanup lanes — spawn through their
  own preparation paths; they do not probe through this type.
- The upgrade manager's candidate probe
  (`ACPAdapterCandidateProbe`) — builds its own sandboxed launch plan
  directly and never touches `LaunchIsolation`. It stays sandboxed
  because it is UNATTENDED and auto-downloads the package it executes:
  "initialize-only" bounds the protocol surface, not code execution —
  the adapter's `main()` runs before any verification check.

## The secrets rule

An unsandboxed probe carries a Keychain credential ONLY for an adapter
with a verified compatibility contract (`ACPAdapterCompatibility`,
today codex-acp). Unverified adapters run secrets-free; an
auth-required candidate fails with a clear authenticate error. The
key travels IN BAND to the `authenticate` call — it never reaches the
child environment (`acpAgentApiKey` has no `env.` prefix, so
`resolveSpawnConfig` drops it from the spawn environment). Applied at
`discoverObservation`'s `providerHints` call via the pure
`effectiveAPIKey` helper.

## Rationale for the split

The manual refresh is presence-plus-consent: the user clicked, on a
provider the user installed. The candidate probe is unattended,
auto-downloads the package it executes, and auto-adopts on success —
the least-trusted binary in the system, which must keep containment.
The sandbox front-end gates are fail-closed by design (issue #1276):
a broken seatbelt means no agent subprocess, and the unsandboxed tier
is the one deliberate exception, chosen per call.

## Scaling the adapter config-home table

`providerHomeSubpaths` maps adapters to writable config homes
(`.codex`, `.gemini`, `.pi`), one captured Seatbelt denial per entry.
Alternatives evaluated in the PR #1408 audit: registry-derived homes
(the upstream registry carries no such metadata and the weekly drift
refresh would clobber local fields), config-supplied allowances
(moves a writable+executable exception into data), and dropping chat
sandboxing (reopens the #1279 containment design). Denial-surfacing
(issue #1409) is the prerequisite for the long-term consent loop:
capture the denial, prompt in Settings, persist per-provider. A
fourth config-home entry is the trigger to promote the string
matches to a typed classifier.
