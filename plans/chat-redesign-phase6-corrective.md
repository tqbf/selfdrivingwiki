# Chat Redesign Phase 6 Corrective Work

Last updated: July 30, 2026 (America/Los_Angeles)

Issue: #982

## Scope

Correct the Phase 6 audit findings. Do not add Phase 7 work.

## Changes

- Reserve registry entries before idle eviction. A submit cancels that
  reservation before it can use the controller.
- Mark an idle runtime close before its await. A submit during the close stays
  queued until the close finishes. The controller then rechecks quiescence.
- Arm idle eviction when the host inserts a controller. Remove a new-chat
  controller after a preflight rollback when it remains idle.
- Disable the composer when no enabled provider and resolved chat model exist.
- Correct the Phase 6 polling and badge-diagnostic documentation claims.

## Verification

Run the normal SwiftPM build and test gates. Record hosted and mutation limits
as limits. Do not report an interrupted command as passing.
