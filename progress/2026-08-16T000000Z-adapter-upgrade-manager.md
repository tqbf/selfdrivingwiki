# ACP adapter upgrade manager shipped

Date: 2026-08-16. PR #1403 (`feature/agent-adapter-upgrade-manager`).

## What landed

The in-app adapter upgrade manager per
`plans/agent-adapter-upgrade-manager.md` (the plan doc was rewritten in
the same branch to describe what ships, after an independent design
review corrected the probe scope and the identity join).

Slices:

1. Decision layer (`Sources/WikiFSCore/Integrations/ACPAdapterUpgradeDecision.swift`):
   typed npx/npm-exec/bun/uvx parse, exact-pin extraction, floating
   forms never adoptable, no silent downgrades.
2. Storage (`Sources/WikiFSCore/Core/AdapterUpgradeState.swift` +
   `AgentProvidersConfig.adapterUpgrades`): adoption records with
   byte-exact from-command, ownership states, probe-failure backoff,
   restore suppression. Forward-compatible decode; the field rides
   every reconstruction site and `mergeMutation`.
3. Candidate probe (`Sources/WikiFSEngine/ACPAdapterCandidateProbe.swift`):
   initialize-only handshake through the real sandboxed launch plan.
   Verification (`ACPAdapterCandidateReport.swift`) is pure: protocol,
   contract identity, version predicate against the on-disk candidate.
   A source-scan test keeps auth/session traffic out forever.
4. Manager (`Sources/WikiFSEngine/ACPAdapterUpgradeManager.swift`):
   decide, probe, one locked CAS commit. Ownership gates (user-owned,
   custom shapes, drifted baselines), live-use deferral, exponential
   backoff capped at 24h, manual checks bypass backoff and suppression.
5. App wiring (`ACPAdapterUpgradeCoordinator` + `WikiFSApp` +
   `AgentsSettingsView`): activation-throttled automatic checks, the
   manual check button, the Adapter Updates panel, one-click restore.
6. CI (`acp-registry-refresh.yml`): weekly bundled-snapshot refresh to
   a chore branch with one reusable PR, JSON validation first,
   GITHUB_TOKEN pull_request limitation documented, never merges.

## Review corrections incorporated

- Probe is initialize-only (no authenticate, no session/new, no model
  enumeration).
- Identity comes from a verified package-to-identity contract table,
  not the package name. Unknown packages fail closed (unverified,
  never auto-adopted).
- Package recognition is not ownership: user edits and custom shapes
  are never rewritten; adoption commits only over a matching managed
  baseline via CAS.
- AC 1 wording weakened to "by the next eligible launch or activation
  after the registry TTL" because no launch-time registry refresh
  existed before this branch.

## Known limitations

- Only `@agentclientprotocol/codex-acp` has a verified contract today,
  so only codex auto-adopts. Other agents' newer pins show in Settings
  as unverified. Adding a contract is a one-entry table change once an
  agent's reported identity is verified.
- The legacy claude-acp seed command (`bun x
  @agentclientprotocol/claude-agent-acp`) stays floating: it has no
  verified contract, so the manager cannot pin it automatically. The
  user can re-add the provider, or a future contract entry unlocks
  adoption.
- The live-use gate defers ALL adoptions while any chat is generating
  (conservative; the queue engine is not consulted).

## Gates

- `make build` green (app + signed).
- `make test` green: 4568 tests, 0 failures. New suites:
  ACPAdapterUpgradeDecisionTests (21), AdapterUpgradeStateTests (10),
  ACPAdapterProbeVerificationTests (6), ACPAdapterCandidateProbeTests
  (10, real sandboxed subprocess fixture), ACPAdapterUpgradeManagerTests
  (15). The candidate probe was registered in the
  LLMSpawnSandboxExhaustiveness and ProcessSignalSafety audit
  inventories with rationales.
