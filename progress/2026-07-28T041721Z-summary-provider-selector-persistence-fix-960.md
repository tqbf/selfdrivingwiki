---
timestamp: 2026-07-28T041721Z
title: "2026-07-28 — Summary provider selector persistence fix (#960)"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-07-28 — Summary provider selector persistence fix (#960)

## Progress


**Scope.** Fixed the Settings → Operations → Summary Provider selector so an
explicit non-default summary-provider pin no longer snaps back to the default
provider in the shared stage picker, and the UI now surfaces an explicit
validation state when the pinned summary provider is disabled or missing.

**What landed.**
- Fixed `StageProviderModelPicker` so the provider picker tags use the stored
  raw provider id (`String`) rather than `ProviderID`, matching the binding
  type and preserving explicit non-default selections.
- Added `StageProviderSelectionState` as a pure resolver for the shared picker
  so the UI can distinguish inherited, enabled-pinned, disabled-pinned, and
  missing-pinned states without rewriting the stored config.
- For the `"summarizer"` stage specifically, the model picker now disables and
  shows a clear warning when the pinned provider is unavailable, rather than
  silently pretending the default provider is selected.
- Added persistence/default-independence coverage for the summary stage pin in
  `AgentProviderModelTests`.
- Added unavailable-pin routing coverage in `MessageSummaryTests` proving
  `resolveProfile` returns `nil` without clearing the stored `"summarizer"` pin.
- Added `StageProviderModelPickerTests` to pin the new pure selection-state
  behavior.

**Verification.**
- `make keychain` — regenerated the required local
  `Sources/WikiFSCore/GeneratedKeychain.swift` prerequisite for SwiftPM builds.
- `make version` — regenerated the required local
  `Sources/WikiFSCore/GeneratedVersion.swift` prerequisite for SwiftPM builds.
- `swift test --filter 'AgentProviderModelTests|StageProviderModelPickerTests|MessageSummaryTests'`
  — 41 tests in 2 suites passed after the prerequisite regeneration.
- `WIKIFS_APP_TESTS=1 swift test --filter AgentProviderModelTests`
  — 44 tests in 5 suites passed, including the new summary-pin persistence and
  default-change coverage.
- `git diff --check` — clean.

## Verification

Historical verification remains in the progress record above.
