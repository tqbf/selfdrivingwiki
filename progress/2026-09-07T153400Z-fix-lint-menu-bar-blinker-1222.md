---
timestamp: 2026-09-07T153400Z
title: Fix lint operations not starting the menu-bar activity blinker (#1222)
branch: fix/lint-menu-bar-blinker-1222
status: complete
---

# Fix lint operations not starting the menu-bar activity blinker (#1222)

## Progress

The menu-bar status item shows live queue work by breathing the books glyph.
`MenuBarItemController` derived the working state only from
`lastSnapshot.activeItems`. Every queue event spawned an async snapshot RPC,
and the icon waited on that reply. The reply can return stale data: a fetch
that started before an enqueue can land after it and erase the new item, and
unstructured fetch tasks can apply out of order. A lint enqueue showed the
"Lint queued" hint (the event arrived) while the icon stayed idle (the
snapshot disagreed).

The controller now records active items from the events themselves:

- `.enqueued` inserts the item into `queuedItemIDs`.
- `.started` moves it to `runningItemIDs`.
- `.completed`, `.failed`, and `.cancelled` remove it.

`updateIcon` reads these sets, so the blinker starts on the enqueue event.
Tooltip counts come from the same sets, so the tooltip agrees with the icon.

Snapshot replies still refresh `lastSnapshot` and the failure badge, and they
replace the membership sets when they are provably fresh. Each fetch captures
a membership epoch at its start. The controller bumps the epoch on every
event-driven membership change and discards replies from older epochs. A
stale reply can no longer clear the blinker or resurrect a removed item. The
initial snapshot still seeds items the daemon hosted before the app
subscribed.

Tests found an unrelated fixture bug: `QueueStore(databaseURL:
URL(fileURLWithPath: ":memory:"))` does not give a private in-memory
database. URL path conversion drops the colon, so GRDB opened a literal
`:memory:` file in the working directory. The file persisted across test runs
and collected stale queued items, which made the controller sit in the
working state forever. Both test helpers now use a unique temporary
directory, and the stray files are deleted.

## Verification

- `WIKIFS_APP_TESTS=1 swift test --filter MenuBarItemLintBlinkerTests` —
  4 tests pass in ~0.5 s. Covers page-level lint, whole-wiki lint,
  extraction parity, enqueue-to-blink timing, and the stale-snapshot race
  with a gated snapshot engine.
- `WIKIFS_APP_TESTS=1 swift test --filter MenuBarItemMaintenanceMenuTests` —
  2 tests pass.
- `make build` — clean.
- `make test` — full default suite passes (4232 tests, 460 suites). The
  opt-in app-test suites that host AppKit views are not part of CI; they run
  locally per `scripts/test-vm.sh`.
