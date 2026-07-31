---
timestamp: 2026-07-31T04:26:07Z
title: "2026-07-30 — Chat presentation diagnostics Phase 6 corrective round 3"
branch: chat-presentation-diagnostics-phase6
status: implemented
timestamp_source: local-clock-america-los-angeles
---

# 2026-07-30 — Chat presentation diagnostics Phase 6 corrective round 3

## Progress

Completed the Phase 6 correction for the two high-severity audit findings on
PR #1002. This record does not add Phase 7 compatibility work or change a
plan index.

- Coalescing now uses a stable producer identity across interleaved records.
  Renderer planning uses the captured display-row context, while daemon runtime
  transcript observations carry the real durable message or tool identity.
  Receipt, reduction, and persistence observations for one runtime item now
  coalesce without collapsing a mixed batch.
- Renderer acknowledgements and recovery diagnostics retain the chat captured
  when their command was dispatched, rather than consulting a later selected
  transcript.
- Content fingerprints now use an ephemeral 256-bit HMAC-SHA-256 key. The key
  is not exported. A successful reset rotates and drains the ring; if an
  artifact was written but its daemon reset fails, the app and daemon retire
  their fingerprint epochs while retaining retry evidence.
- The exported merge contract is explicitly
  `source-instance-sequence; timestamps-informational`, with an exact
  coordinator assertion to prevent accidental reversion to the old label or
  ordering policy.

## Verification

- Focused hosted suites passed: `ChatDiagnosticsTests` (5),
  `ChatDaemonCoordinatorTests` (14), `ChatTranscriptRenderExecutorTests` (8),
  `DaemonChatControllerTests` (26), `DaemonChatHostTests` (27), and
  `ChatDiagnosticTypesTests` (3).
- `make build` — passed; assembled and signed `Self Driving Wiki.app`.
- `make test` — passed: 2,715 tests in 219 suites.
- `WIKIFS_APP_TESTS=1 swift test` — the full hosted aggregate was
  inconclusive: its test helper remained active for more than three minutes
  after the launcher returned and was stopped. The focused hosted diagnostics,
  renderer, coordinator, controller, and daemon-host suites above passed.
- `/usr/bin/log show` scoped to the project debug subsystem found no matching
  SwiftUI "Modifying state during view update" or "undefined behavior"
  warnings during the run.
- `git diff --check` — passed.

## Remaining gate

An independent exact-head audit and green PR CI are still required before any
merge-readiness decision.
