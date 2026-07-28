---
timestamp: 2026-07-19T170611Z
title: "2026-07-19 — Issue #665: Fetch official ACP registry for provider catalog (branch `feature/acp-registry`)"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-07-19 — Issue #665: Fetch official ACP registry for provider catalog (branch `feature/acp-registry`)

## Progress


**Problem.** The provider catalog (`ACPProviderCatalog.agents`) was a
hardcoded 12-entry list maintained by hand. The official ACP agent registry
(38 agents at `cdn.agentclientprotocol.com/registry/v1/latest/registry.json`)
exists and is the canonical source — every agent the protocol tracks should
show up in *Add Provider* automatically.

**Scope.**

- `Resources/acp-registry.json` — NEW; the official registry snapshot
  (47 KB, 38 agents) shipped as a bundled resource so the catalog is
  non-empty even on first launch, offline. The build script copies it to
  `Contents/Resources/acp-registry.json`.
- `Sources/WikiFSCore/Integrations/ACPRegistry.swift` — NEW (~260 lines).
  - `ACPRegistryResponse` / `ACPRegistryAgent` / `ACPRegistryDistribution`
    (`Codable` + `Sendable`). `ACPRegistryDistribution` is a custom-decoded
    enum (`.npx` / `.binary([String:])` / `.uvx`) — the registry tags each
    agent with at most one; decoded by inspecting which key is present
    (forward-compatible if the schema ever adds a second distribution per
    agent).
  - `ACPRegistryClient` — the registry client. `loadAgents()` (async) is
    always best-effort: fresh cache → live fetch → stale cache → bundled
    snapshot → hardcoded `fallbackCatalog`. Never throws, never crashes,
    never blocks the UI. Cache TTL is 24h; fetch timeout is 10s. All errors
    route through `DebugLog.agent`.
  - `mapRegistryToCatalog(_:)` (pure, internal) — the distribution→argv
    mapping:
    - `npx` → `["npx", package] + args`, `detectExecutable = "npx"`.
    - `uvx` → `["uvx", package] + args`, `detectExecutable = "uvx"`.
    - `binary (darwin-aarch64)` → strips leading `./` from `cmd`,
      `command = [cmd] + args`; falls back to `darwin-x86_64` (Rosetta).
    - Skips entries whose distribution is nil or has no darwin platform.
- `Sources/WikiFSCore/Integrations/ACPProviderCatalog.swift` — the public
  surface changes:
  - `agents` (static let, 12 hardcoded entries) → renamed
    `fallbackCatalog` (still 12; used as the last-resort floor).
  - `agents` (NEW computed var) — sync accessor: bundled snapshot →
    `fallbackCatalog`. (In `swift test`, where `Bundle.main` is the test
    runner — no bundled resource — returns `fallbackCatalog` so the existing
    `catalogHasExpandedEntries` / `defaultCatalogIsNonEmptyAndClaudeAcpPresent`
    assertions still hold. In the .app, returns the official 38-agent
    snapshot.)
  - `loadAgents()` (NEW async) — fresh cache → fetch → stale cache →
    bundled snapshot → `fallbackCatalog`. Delegates to
    `ACPRegistryClient.loadAgents()`.
- `Sources/WikiFS/Settings/AddProviderSheet.swift` — the sheet's model now
  owns `catalogAgents: [KnownACPAgent]` (initialized to the bundled snapshot
  via `ACPProviderCatalog.agents`, refreshed from the live registry by the
  sheet's `.task`). The footer count reads `catalogAgents.count`; on a
  successful refresh the sheet reflows from 12 → 38 rows without further
  code changes. First paint is the bundled snapshot (no network fetch on
  the critical path of UI rendering).
- `build.sh` — copies `Resources/acp-registry.json` to
  `Contents/Resources/acp-registry.json` (a plain JSON resource; sealed by
  the outer .app codesign — no separate signing step, matches `merval.js`).
- `.github/workflows/ci.yml` + `Makefile` `FAST_TEST_SKIP` — appended
  `ACPRegistryTests/loadAgentsReturnsNonEmpty` to the fast-tier skip regex
  (it's tagged `.integration` AND has a 2-min time limit because it can hit
  the network — the rest of `ACPRegistryTest` is pure + bundled-snapshot,
  fast).
- `Tests/WikiFSTests/ACPRegistryTests.swift` — NEW (~230 lines, 17 tests).
  Pins:
  - Codable round-trip for each distribution variant (npx / binary / uvx /
    nil).
  - Mapping invariants per distribution (command / detect / convention).
  - Bundled snapshot decodes and maps to ≥30 agents (the floor — the
    live count is 38 at the time of #665).
  - Skip rules: nil distribution + binary with no darwin platform → entry
    absent from the mapped catalog.
  - `ACPProviderCatalog.agents` returns `fallbackCatalog` in `swift test`
    (no bundled resource in the test runner).
  - `ACPProviderCatalog.loadAgents()` (integration-tagged) → non-empty +
    contains `claude-acp` + invariant preserved across the whole cache →
    fetch → fallback chain.

**Behavior change for users.** `claude-acp` in the *Add Provider* catalog
moves from `bunx @agentclientprotocol/claude-agent-acp` (the old hardcoded
entry, still in `fallbackCatalog`) to `npx @agentclientprotocol/claude-agent-acp`
(per the official registry's `npx` distribution). The default provider
seeded on first run is unaffected — it's still the hardcoded
`AgentProvider.claudeAcpDefault` (which uses `bun`), so existing installs
see no regression; only catalog-driven adds from the refreshed UI use the
npx form. Other 26 new agents appear in *Add Provider* automatically
(amp-acp, codex-acp, cline, devin, factory-droid, qwen-code, …).

**Testing gates.**
- `swift build` — ✓ (34.88s).
- `swift test --filter 'ACPRegistryTests'` — 17/17 passed (loadAgents round
  trip 0.224s; the rest are pure decode/map).
- `swift test --filter 'ACPProviderDiscoveryTests|AddProviderSheetTests|AgentProviderCatalogTests'`
  — 19/19 passed (the existing catalog/discovery tests, no regressions).
- `swift test` (full, no skip) — 3042/3042 in 33s. ✓

**Closes #665**. NOT merged — branch `feature/acp-registry` left open for
review; tagged `Closes #665` in the PR body so a merge closes the issue.

---

## Verification

Historical verification remains in the progress record above.
