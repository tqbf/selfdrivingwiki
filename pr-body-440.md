## Queue readiness check: guide users to configure agents/extraction before cryptic spawn failures

Closes #440

### Problem

When no agent provider (Claude/Hermes/OpenCode) or extraction backend is installed/configured, queue items fail with a cryptic process-spawn error like `"bun: not found"` instead of guiding the user to set things up.

The ingestion side had no readiness check at all — `QueueIngestionWorkerFactory.providerID(for:)` always returned `"default-ingest"`, and the real failure happened deep inside `AgentLauncher.run()` → `Process.run()`, surfacing as an unhelpful `.failed` item.

The extraction side already had a `readiness()` mechanism on `MarkdownExtractor` (checked inside `QueueExtractionWorker.execute()`), but the error messages were stored as raw `String(describing:)` output (e.g. `notReady("Add your Anthropic API key...")`) and the Activity window offered no call-to-action.

### What this PR does

#### 1. Ingestion provider readiness gate

- Added `func readiness() async -> String?` to the `QueueIngestionProvider` protocol — returns `nil` when ready, or a user-facing message explaining what to fix.
- Added `QueueIngestionError.notReady(String)` — carries the readiness message.
- `QueueIngestionWorker.execute()` now calls `readiness()` **before** running the full pipeline. If not ready, it throws `.notReady` and the item fails with the clear message (the provider is never invoked).
- Added `AgentLauncher.readinessMessage(for:)` — a pure, injectable static function that checks whether the selected agent provider's `command[0]` binary exists on the login-shell PATH (or is the bundled bun helper). Mirrors `ACPExtractionClient.resolveProvider`'s `resolveCommand` seam. Returns `nil` when ready, or a message like:
  > 'bun' was not found on your PATH. Install bun (bun.sh) or configure a different agent provider. Open Settings → Agents to configure one.
- Implemented `readiness()` in `AppQueueIngestionProvider` with an injectable `resolveSelectedProvider` closure (for testability — mirrors the launcher's pattern).

#### 2. Cleaner error storage in the queue engine

- `QueueEngine` now prefers `LocalizedError.errorDescription` over `String(describing:)` when storing failure messages on items. This means the user sees "bun was not found on your PATH…" instead of `notReady("bun was not found…")`. Benefits both ingestion and extraction errors.

#### 3. Activity window call-to-action button

- When a queue item fails with a "not configured" error (binary not on PATH, no API key, no endpoint, missing dependencies), the Activity window detail pane now shows a **"Configure Agents…"** (or **"Configure Extraction…"**) button next to the error text.
- Clicking it opens Settings on the relevant tab (`agents` for ingestion, `extraction` for extraction) via `OpenWindowBridge.openSettings(tab:)`.
- `isConfigurationError(_:)` conservatively detects configuration errors by matching known readiness message markers — so a generic "convert failed" or "agent crashed" error does **not** show a misleading gear button.

### Files changed

**Engine (`WikiFSEngine`):**
- `QueueIngestionProvider.swift` — added `readiness()` to the protocol, `.notReady` to `QueueIngestionError`, readiness gate in `QueueIngestionWorker.execute()`
- `AgentLauncher.swift` — added `readinessMessage(for:resolveCommand:)` static helper
- `QueueEngine.swift` — cleaner error messages via `LocalizedError.errorDescription`

**App (`WikiFS`):**
- `AppQueueIngestionProvider.swift` — implemented `readiness()` with injectable provider resolution
- `ActivityWindowView.swift` — added CTA button + `isConfigurationError` helper
- `OpenWindowBridge.swift` — added `openSettings(tab:)` helper
- `MenuBarItemController.swift` — passes `openWindowBridge` to `ActivityWindowView`

**Tests:**
- `QueueIngestionTests.swift` — `FakeIngestionProvider` updated with `readinessMessage`; two new worker tests (not-ready fast-fail + ready-proceeds)
- `AgentProviderModelTests.swift` — four new `readinessMessage` tests (command resolves, binary not found, no command configured, bun-specific message)

### Testing

- `swift build` passes
- Fast test tier: 2505 tests in 214 suites passed (6 new tests)
- The `readiness()` check is fast (synchronous `which`-style check, wraps a `zsh -lc` PATH hop — same as the existing `PathPreflight.resolveOnLoginShell` used at spawn time). It runs once per dispatch before the worker pipeline starts, so it does not block the queue engine.
