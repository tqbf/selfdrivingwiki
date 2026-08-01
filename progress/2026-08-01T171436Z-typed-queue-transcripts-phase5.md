---
timestamp: 2026-08-01T10:14:36-07:00
title: Typed Queue Transcripts Phase 5
branch: feature/typed-queue-transcripts-phase5
status: complete
---

# Typed Queue Transcripts Phase 5

Phase 5 completes verification and documents the terminal ACP output policy.
ACP terminal tool updates now preserve the provider's status and matching tool
identity when output is absent. Nonempty rendered content remains preferred;
the only structured fallback is a string `formatted_output`, `output`, or
`metadata.output`. The exact trimmed provider marker `(no output)` means no
output. Other objects and arrays are not serialized.

## Progress

- Made `AgentEvent.toolResult.summary` optional and carried `nil` through the
  shared translator and typed transcript output without synthetic text.
- Added ACP, Codable, FIFO translation, persistence/reopen, and presentation
  coverage for terminal nil output, marker normalization, output precedence,
  whitespace, and arbitrary structured output rejection.
- Ran signed Luna lint item `01KYZ4GJK9MXEJ5M54X1TVJJ06` through the supported
  Page Detail Lint action. Activity rendered its streaming typed rows and 16
  terminal tool cards; durable storage contains 33 rows with stable identities.
- The real queue trace contains zero canonical `(no output)` markers. The
  exact marker-to-nil behavior is verified by decoded real-wire fixtures, not
  claimed as a live queue observation.

## Verification

- The Activity Copy assistant response command copied the visible assistant
  bullets exactly; no marker text was copied.
- `make run` rebuilt, signed, and restarted the application and bundled daemon.
  The queue's 33 typed rows remained durable. The documented Command-I Activity
  reopen did not surface a window through Accessibility after close/restart;
  this is an automation limitation, not a visual-reopen claim.
- The queue database retains progress-only items without transcript rows; the
  hosted progress-fallback suite covers that presentation path. `wikictl chat
  list --json` after restart returned four existing conversations.
- Full focused, build, test, lint, check, and diff verification is recorded in
  `plans/typed-queue-transcripts.md` and rerun at the final Phase 5 head.

## Review

The terminal normalization is pure `Sendable` translation with no new shared
state, tasks, actors, or UI architecture. The SwiftUI and macOS review found no
new presentation structure: typed rows, copy, and progress fallback keep using
the existing canonical Activity projection. Swift Testing coverage uses
deterministic decoded provider updates and explicit output precedence.
