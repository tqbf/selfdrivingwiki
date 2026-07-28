---
timestamp: 2026-07-03T053230Z
title: "2026-07-02 — Remove configurable sandbox config (`sandbox-config.json`)"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-07-02 — Remove configurable sandbox config (`sandbox-config.json`)

## Progress


The sandbox is **not configurable**. Confinement is fixed by spawn type —
Ingest/Edit get the write whitelist, Ask gets the read-only profile, both always
on — so the persisted `SandboxConfig` (`enabled` toggle + `extraAllowedPaths`
escape hatch) was dead weight. `enabled` was already ignored (Ingest/Edit
sandbox by default; Ask forced read-only by `selectQuerySandbox`), and
`extraAllowedPaths` was a manual-edit-JSON-only widening hatch with no UI. See
[`plans/sandbox-always-on.md`](plans/sandbox-always-on.md) (supersedes the
opt-in "Config" section of `sandbox-agent.md`).

- **Deleted** `Sources/WikiFSCore/SandboxConfig.swift` (the `Codable` model,
  `load`/`save`, `parsedExtraAllowedPaths`) and `Tests/WikiFSTests/SandboxConfigTests.swift`.
- **`SandboxProfile.swift`** — dropped the `extraAllowedPaths` parameter from
  `generate(...)` and `invocation(...)`; removed the now-dead extra-paths splicing
  loop and the `isDirectory` / `escape` private helpers.
- **`AgentLauncher.resolveSandboxInvocation`** — no longer loads any config; builds
  the write-whitelist `SandboxInvocation` directly from scratch dir + DB path.
- **`ClaudePromptHelp.currentSandboxInvocation`** — returns the write-mode
  invocation unconditionally (always on for the Command Template preview); the
  `guard config.enabled` gate and App Group container read are gone.
- **`SandboxProfileTests`** — removed the 5 `extraAllowedPaths` tests; simplified
  the `profile()` helper.
- Gate: `swift build` clean; full suite 1259 tests + sandbox suite 30 tests green.
- Note: an existing `sandbox-config.json` on disk (App Group container) is now
  orphaned and harmless — the app never reads it; not regenerated.

## Verification

Historical verification remains in the progress record above.
