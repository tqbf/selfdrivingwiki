# In-app ACP adapter upgrade manager

Status: implemented on `feature/agent-adapter-upgrade-manager`. This
document describes what ships. The one-off codex-acp 2.2.2 bump (#1401)
fixed the snapshot and the version predicate. This feature removes the
gap that remains: a provider command is frozen in stored settings at
add-time, so existing installs keep launching an old adapter until the
user re-adds it by hand.

## Problem

`AgentProvider.acp(from:)` copies the catalog command verbatim into
stored settings when the user adds a provider. Nothing revisits that
command later. The upstream agents release constantly. Hand-maintained
pins rot within days, and each rot reproduces the stale-model-metadata
failure class (#1396 follow-up).

## Design: adopt the newest version that passes

Never float. Launch commands stay exact pins. A scheduled loop adopts a
newer pin only after the candidate passes the compatibility gate.

### Trigger

`ACPAdapterUpgradeCoordinator` (app layer, owned by `WikiFSApp`) is the
bootstrap owner:

1. It runs an automatic check at app activation. The check is
   throttled to one per six hours. The registry client's own 24h cache
   TTL gates the network fetch.
2. A manual "Check for Adapter Updates" action in Settings bypasses
   the throttle, the probe backoff, and restore suppression.

AC 1 therefore reads: a user converges to the newest
predicate-supported adapter by the next eligible launch or activation
after the registry TTL expires.

### Per-provider decision (pure function, unit-tested)

Input: the stored provider command and the registry entry for the same
agent id. Output (`ACPAdapterUpgradeDecision`):

- `upToDate` — the registry pin equals the stored pin. An older or
  malformed registry pin never replaces a newer stored pin (no silent
  downgrades).
- `notApplicable` — no registry entry, or either command is not a
  package-runner launch. A plain binary such as `gemini --acp` is
  user-owned. A floating registry entry (`@latest`, a range) is never
  adoptable.
- `updateAvailable(target:support:)` — the registry publishes a
  strictly newer exact pin for the same package.

`support` comes from the verified contract table
(`ACPAdapterCompatibility`), not from the package name:

- `knownSupported` — a verified contract exists for the package and its
  version predicate admits the version. Eligible for probe and
  auto-adoption.
- `unsupported` — a verified contract rejects the version (a future
  major). Visible in Settings, never auto-adopted.
- `unverified` — no verified contract for the package. Fail closed:
  visible, never auto-adopted. Today only `@agentclientprotocol/
  codex-acp` carries a contract. An app update that ships a new
  verified contract unlocks adoption for that package.

A floating stored command is strictly less informed than any exact pin,
so any exact registry pin for the same package counts as newer.

### Ownership (package recognition is not ownership)

A provider command is adoptable only when the manager owns it:

- `managed(baseline:)` — the manager wrote (or froze at add) the exact
  argv. An adoption commits only while the live command still equals
  the baseline.
- `userOwned` — the user edited the command in Settings. Never
  touched.
- legacy (no record) — adoptable only when the stored command matches
  the registry command's version-stripped shape (same runner, same
  package, same trailing arguments). Custom wrappers, extra flags, and
  absolute custom runners are skipped.

Adoption preserves the user's label, environment, enabled state, and
model selections. Two providers sharing one package stay independent.

### Probe before adopt (initialize-only)

`ACPAdapterCandidateProbe` reuses the model probe's launch preparation
(fail-closed sandbox gate, spawn resolution, bun canonicalization, the
typed sandboxed launch plan, hard-bounded race, unconditional
teardown) but performs ONLY the ACP initialize handshake. It never
authenticates and never opens a session. No model enumeration: models
come from `session/new`, and adoption does not require them.

The probe returns a typed report (protocol version, reported identity,
reported version). `ACPAdapterProbeVerification` checks it against the
package contract:

1. The protocol version equals the version this build speaks.
2. The reported identity equals the contract's verified identity. The
   registry id, the distribution package name, and the reported
   identity are three different namespaces; only the contract joins
   them.
3. The reported version satisfies the contract's version predicate —
   defense in depth, because the candidate on disk can differ from the
   registry claim.

Any failure or timeout keeps the stored command and records a probe
failure with an exponential backoff (one hour doubling, capped at 24
hours), so a broken upstream release cannot loop probes. Manual checks
bypass backoff.

### Adopt and roll back

On probe success the manager commits through ONE locked
`AgentProvidersConfigStore.mutate`: the new command, the adoption
record, and the ownership baseline land together, with a CAS recheck —
the adoption lands only while the provider still exists and still runs
the probed from-command. A user edit that races the probe wins. No file
or process I/O happens under the lock.

`AdapterAdoptionRecord` stores the typed from/to specs plus the exact
previous argv. Settings shows an Adapter Updates panel with each
provider's state and a one-click **Restore previous command** action.
Restore swaps the command back byte-exactly and records the adopted
version as suppressed: automatic checks do not re-adopt that exact
version until a strictly newer candidate appears. A manual check is the
explicit retry.

Adoption never races a live chat: when any chat is generating, the
check defers all adoptions and the next eligible check retries. Live
backends keep their frozen spawn; an adoption applies at the next
fresh runtime preparation (the app's restart-to-pick-up model).

## CI complement

A weekly workflow fetches the live registry and compares it with
`Resources/acp-registry.json`. On drift it validates the JSON, commits
the refresh to a `chore/` branch, and updates one reusable open PR.
The PR body notes that a GITHUB_TOKEN-created PR does not trigger the
`pull_request` CI event. No-diff runs are no-ops. CI never merges and
never pushes to main.

## Testing

Named per acceptance criterion (all in the default `WikiFSTests`
graph, so CI runs them without opt-in):

- AC 1 — `startupCheckRunsWithoutOpeningSettings`,
  `expiredTTLChecksAgain` (`ACPAdapterUpgradeManagerTests`).
- AC 2 — `failedProbeLeavesCommandAndHistoryUnchanged`,
  `backoffDefersAutomaticChecksAndManualBypasses`,
  `backoffEscalatesAndCapsAtOneDay`.
- AC 3 — `restoreButtonCommitsPreviousCommand`
  (`AdapterUpgradeStateTests`),
  `restoredCandidateIsSuppressedForAutomaticChecksAndRetriedManually`.
- AC 4 — `unsupportedCandidateIsVisibleAndNeverCommitted`,
  `unverifiedPackageIsVisibleAndNeverCommitted`.
- AC 5 — `adoptedSpawnArgvContainsExactPinOnly`.

Plus: the decision table and parser
(`ACPAdapterUpgradeDecisionTests`), probe verification
(`ACPAdapterProbeVerificationTests`), the probe failure table against a
deterministic shell JSON-RPC fixture through the real sandboxed launch
(`ACPAdapterCandidateProbeTests`, serialized + timeLimit), and a source
scan that keeps the candidate probe initialize-only.

## Acceptance criteria

1. A user converges to the newest predicate-supported adapter by the
   next eligible launch or activation after the registry TTL expires.
2. A candidate that fails the probe never changes the stored command.
3. A supported-version adoption is reversible in one click.
4. An unsupported or unverified newer version is visible in Settings
   and never auto-adopted.
5. No launch command the manager writes is ever a floating tag. Legacy
   floating seeds (the claude-acp `bun x` default) stay user-owned
   until a verified contract ships for that package or the user
   re-adds the provider.

## Prior art

- Paseo managed Git plugins: stage a candidate, validate it, activate
  only after success, restore on failure. This is the runtime loop.
- Paseo ACP catalog drift checker: the CI job shape.
- Paseo app updater UX contract: silent check, explicit adopt, no
  silent downgrades, revalidate before install.
- Zed: registry-driven exact-version installs with background refresh.
