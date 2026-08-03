# Sandbox is not configurable — mode is fixed by spawn type

**Status:** Implemented on `security/sandbox-ingest-edit-by-default`. Supersedes
the "Config" / "opt-in" sections of [`sandbox-agent.md`](sandbox-agent.md) and
the "re-add the sandbox toggle" half of [`sandbox-and-chat-modes.md`](sandbox-and-chat-modes.md).

## What changed

The sandbox is **no longer user-configurable**. There is no `sandbox-config.json`,
no `enabled` toggle, and no `extraAllowedPaths` escape hatch. The confinement a
spawn gets is determined entirely by **what kind of run it is**:

| Spawn | Sandbox | What's writable |
|-------|---------|-----------------|
| **Ingest / Edit** | write whitelist (`SandboxProfile.invocation`) | scratch dir + active wiki DB (+ SQLite sidecars) + `~/.claude` |
| **Ask (Query)** | read-only (`SandboxProfile.readOnlyInvocation`) | scratch dir + `~/.claude` only — the wiki DB is **not** writable |

Both are **always on**. There is no off switch and no per-path widening.

## Why

The `SandboxConfig` model (`enabled: Bool`, `extraAllowedPaths: String`) was an
opt-in escape hatch carried over from when the sandbox was default-off. Two
things made it dead weight:

1. **`enabled` was already ignored.** Ingest/Edit sandboxes by default; the Ask
   session is forced read-only by `selectQuerySandbox`. The toggle had already
   been removed from Settings (commit `fb8b20d`); the only code still reading
   `SandboxConfig` was `resolveSandboxInvocation`, and only for `extraAllowedPaths`.
2. **`extraAllowedPaths` was a manual-edit-JSON-only escape hatch** with no UI. It
   widened the allowlist (the one thing you do *not* want easy access to) and could
   never remove the scratch/DB core by design. Keeping a "config that isn't
   configurable" invited confusion about what actually controls confinement.

The actual security boundary is the spawn type, decided in code, not a file on
disk. Removing the config makes that unambiguous.

## What was deleted

- `Sources/WikiFSCore/SandboxConfig.swift` — the `Codable` model, `load`/`save`,
  `parsedExtraAllowedPaths`, the `sandbox-config.json` filename.
- `Tests/WikiFSTests/SandboxConfigTests.swift` — entire suite.
- The `extraAllowedPaths` parameter from `SandboxProfile.generate(...)` and
  `SandboxProfile.invocation(...)`, plus the now-dead `isDirectory` / `escape`
  private helpers and the extra-paths splicing loop.

## What changed (call sites)

- **`AgentLauncher.resolveSandboxInvocation`** — no longer loads any config. It
  resolves the write-whitelist `SandboxInvocation` directly from the scratch dir
  + DB path. Stale comments referencing the opt-in toggle removed.
- **`ClaudePromptHelp.currentSandboxInvocation`** — returns the write-mode
  invocation unconditionally (sandbox always on for the Command Template preview).
  The `guard config.enabled` gate and the App Group container read are gone.

## Runtime artifact on disk

An existing `sandbox-config.json` in the App Group container
(`~/Library/Group Containers/.../sandbox-config.json`) is now **orphaned** — the
app never reads it. It is harmless (a few bytes of stale JSON) and can be deleted
manually if desired. It is not regenerated.

## How confinement is actually decided (current flow)

```
spawn type
   │
   ├── Ingest / Edit ──► resolveSandboxInvocation ──► invocation(...)      [write]
   │
   └── Ask ───────────► selectQuerySandbox ──► readOnlyInvocation(...)     [read-only]
```

`OperationCommand` receives whichever `SandboxInvocation` (or `nil` for a
fail-open misconfiguration) and wraps the provider in `sandbox-exec -p <profile>
-D … -- <provider>`. This layer is unchanged; only the *choice* of invocation is
no longer config-driven.

## Adapting for a new provider

With `extraAllowedPaths` gone, the only way to let a provider write outside
scratch/DB is to **relocate** that write target into the scratch dir via an env
var in `OperationCommand.applySandbox` (the existing `CLAUDE_CONFIG_DIR` /
`TMPDIR` pattern). The seatbelt profile itself stays provider-agnostic — it never
names a provider. To diagnose a denied write:

```sh
log show --predicate 'process == "sandboxd"' --last 5m --info --debug
```

## Files

- `Sources/WikiFSCore/SandboxProfile.swift` — `generate` / `generateReadOnly` /
  `invocation` / `readOnlyInvocation` (no config; pure path → profile).
- `Sources/WikiFSCore/OperationCommand.swift` — `sandbox:` param + `applySandbox`.
- `Sources/WikiFS/AgentLauncher.swift` — `resolveSandboxInvocation` (write mode).
- `Sources/WikiFSCore/ClaudePromptHelp.swift` — Command Template preview.
- Tests: `SandboxProfileTests`, `SandboxedOperationCommandTests`,
  `QuerySandboxSelectionTests`.
