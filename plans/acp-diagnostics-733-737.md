# Plan: ACP Failure Diagnostics (#733 + #737)

## Goal
When an ACP provider subprocess fails to launch (e.g. `claude` or `codex` binary not found), surface actionable diagnostics instead of an opaque error. Combine #733 (bun debug logs + `CLAUDE_CODE_EXECUTABLE` hint) and #737 (`CODEX_PATH` hint) into one PR.

## Implementation

### 1. Add `ACPBackendError.launchFailed` case (~ACPBackend.swift:2250)
```swift
case launchFailed(executable: String, stderr: String?, hint: ProviderEnvHint?)
```
With a `ProviderEnvHint` struct (or enum):
```swift
struct ProviderEnvHint: Sendable {
    let envVar: String     // "CLAUDE_CODE_EXECUTABLE" or "CODEX_PATH"
    let description: String
}
```

### 2. Capture stderr on launch failure (~ACPBackend.swift:384)
Wrap `client.launch()` in a do/catch. If it throws:
- Check if the error indicates a "binary not found" pattern (exit code 127, "command not found", "no such file or directory", non-zero exit with no ACP handshake).
- Determine the hint: if the provider command includes `claude-agent-acp` → hint `CLAUDE_CODE_EXECUTABLE`. If it includes `codex` → hint `CODEX_PATH`. Generic → no hint, just surface stderr.
- Throw `ACPBackendError.launchFailed(executable:stderr:hint:)`.

### 3. Surface in `localizedDescription` (~ACPBackend.swift:2265)
### 4. Surface in settings UI (AgentsSettingsView)
### 5. Document agent-providers.json location

## Acceptance criteria
- [ ] When `claude` binary is not found, the error message includes the bun stderr and suggests `CLAUDE_CODE_EXECUTABLE`.
- [ ] When `codex` binary is not found, the error suggests `CODEX_PATH`.
- [ ] Generic launch failures (not binary-not-found) still surface stderr without a misleading hint.
- [ ] `agent-providers.json` location is documented in the settings UI.
- [ ] No `print` (DebugLog only); no bare `try?`.
- [ ] `make build && make test` passes.
- [ ] PR links #733 and #737.

## Files to modify
| File | Change |
|---|---|
| `Sources/WikiFSEngine/ACPBackend.swift` | Add `launchFailed` case + `ProviderEnvHint`; wrap `client.launch()` in do/catch with heuristic; update `localizedDescription` |
| `Sources/WikiFS/Settings/AgentsSettingsView.swift` | Surface `launchFailed` messages; add agent-providers.json help text |

(See full plan in git history / above.)
