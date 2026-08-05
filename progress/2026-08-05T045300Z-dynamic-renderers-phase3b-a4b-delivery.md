---
title: Dynamic renderers Phase 3b A4b machine delivery and isolation
issue: 1026
---

# Dynamic renderers Phase 3b A4b machine delivery and isolation

## Delivered

- Added one actor-owned, ordered, at-least-once drain per machine process lease.
  It reads durable records after the cursor, calls the idempotent authoritative
  handler, then atomically advances the cursor/checkpoint. Failed handlers do
  not advance either value; duplicate wakes collapse into the active drain.
- Added payload-free machine wake routing that is separate from resource wake
  routing. Machine names cannot reach the File Provider/resource coalescer.
- Added main-actor fan-out to live `WikiStoreModel` renderer-availability
  revisions. The delivery slice does not activate installed records or modify
  active renderer pins; inactive models refresh when registered/opened.
- Added explicit subscription teardown that removes live model references and
  retires its lease.

## Verification

- Focused Swift Testing suites passed: 10 tests across at-least-once delivery,
  wake routing, fan-out, projection isolation, and subscription teardown.
