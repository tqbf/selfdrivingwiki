# Chat Redesign Phase 6 Corrective Work

Last updated: July 30, 2026 (America/Los_Angeles)

Issue: #982

## Scope

Correct the Phase 6 audit findings. Do not add Phase 7 work.

## Documentation disposition

`PLAN.md` is reserved by `AGENTS.md` for feature and design-refactoring
records, so this bug-fix-only corrective note is deliberately not indexed
there. The Phase 6 completion record in
[`chat-architecture-redesign.md`](chat-architecture-redesign.md) links here
and to its dated progress evidence instead. This keeps the master index honest
while preserving a durable, discoverable audit trail.

## Changes

- Reserve registry entries before idle eviction. A submit cancels that
  reservation before it can use the controller.
- Mark an idle runtime close before its await. A submit during the close stays
  queued until the close finishes. The controller then rechecks quiescence.
- Give a single close owner responsibility for generation rotation and queued
  turn recovery, so nested stop/transport lifecycle paths cannot reopen work
  while an earlier `runtime.close` is still awaiting.
- Arm idle eviction when the host inserts a controller. Remove a new-chat
  controller after a preflight rollback when it remains idle, and re-arm a
  refused reservation rather than retaining a completed timer task.
- Cache the composer provider configuration in observable session state and
  refresh it after the atomic Settings save; disable direct and queued sends
  when no enabled provider and resolved chat model exist.
- Correct the Phase 6 polling and badge-diagnostic documentation claims.

## Verification

Run the normal SwiftPM build and test gates. Record hosted and mutation limits
as limits. Do not report an interrupted command as passing.
