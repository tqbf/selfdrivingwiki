---
timestamp: 2026-10-06T050754Z
title: Wiki-agnostic change notification so the bridge hears newly-created wikis
branch: bugfix/issue-1374-bridge-observations
status: in-review
---

# Wiki-agnostic change notification so the bridge hears newly-created wikis

## Progress

Issue #1374: a wiki created from the app's own UI at 14:12:24 never heard its
own writes. A chat agent authored pages into it at 14:33:47; the pages reached
SQLite and never appeared in the UI. The change bridge logged
`observing 7 wiki(s)` at 14:11:09 and never logged again, and no `CF callback
fired` receipt exists for that wiki in the whole hour.

Two failures shared one root cause: the bridge had to know the wiki set before
it could hear or accept anything.

Failure 1 — subscription. `WikiChangeBridge` registered one Darwin observer per
wiki name. The observation set refreshed only at a one-shot bootstrap `Task` and
from `.onChange(of: registry.wikis)`, which was attached to the main
`WindowGroup`'s content and therefore only evaluated while that window was on
screen. A wiki created while the app ran could never be subscribed.

Failure 2 — receipt. `didReceiveDarwinNotification(named:)` resolved the wiki by
matching the posted name against that same `observedWikiIDs` set. A notification
for a wiki outside the set was silently dropped, even when it arrived.

The daemon already solved the equivalent problem by adopting a late-registered
wiki. The app had no adoption path.

The fix is one stable, payload-free notification name, mirroring the existing
`postAgentProvidersConfigChange` / `postExtractorCatalogChange` pattern in
`DarwinNotifier`: the post is stable and carries no payload, and the consumer
re-reads authoritative state to learn what changed. Darwin notifications cannot
carry a payload, so this is the established pattern in this codebase rather than
a workaround.

Changes:

- `WikiChangeNotification` now publishes ONE name, `baseName`
  (`org.sockpuppet.wiki.changed`). The per-wiki `name(forWikiID:)` variant and
  its observer helpers are gone — nothing else used them.
- `DarwinNotifier.postChange()` lost its wiki-id argument. Every call site
  (`wikictl`, the `wikid` daemon's event-bus wiring, the ingestion and
  extraction queue providers) used the id only to build the notification name,
  so the smaller signature is the honest one.
- `WikiChangeWakeRouting` is a new pure function that resolves a received name
  to the wikis to refresh. It is deliberately wiki-agnostic: a wake resolves to
  every wiki the registry lists, or to `nil` when the name is not a wiki wake.
- `WikiChangeBridge` subscribes ONCE at launch (`start()`, idempotent) and
  re-reads the registry from disk on every receipt.
- `WikiRegistryClient.reloadFromDisk()` re-reads `wikis.json` and publishes the
  change to `wikis`. The app is not the only registry writer — `wikictl wiki
  create` and the daemon both write the file directly — so the bridge needs this
  to learn about a wiki it has never seen.
- The `.onChange(of: registry.wikis)` handler is removed. It existed only to keep
  the per-wiki subscription set in lockstep; there is no such set any more.

Preserved deliberately:

- Per-wiki flush semantics. A flush still signals the File Provider for the
  changed wiki and pokes every live session whose `wikiID` matches, per the
  issue #303 comment. Both paths fire unconditionally for their targets.
- The raw CF-receipt observability line before any name matching. It is what
  made this failure diagnosable, so it stays.
- The in-process hint path, `noteSuspectedExternalWrite(forWikiID:)`. It carries
  a real wiki id, so it still feeds the per-wiki coalescer directly.

### The coalescer choice

`ChangeCoalescer` is wiki-keyed: `noteChange(forWikiID:)` schedules one flush per
wiki, so a write burst collapses into one flush per wiki. A wiki-agnostic wake
cannot name the changed wiki, which leaves two shapes:

- Reconcile the observed set, then resolve to the one wiki that changed. This
  needs the changed wiki's id, and the wake cannot supply it, so the step
  collapses into guessing.
- Fan out to every wiki the registry currently lists.

The implementation fans out. The changed wiki is by definition in the registry,
so it is always refreshed, and a wiki that is not in the registry has no File
Provider domain to signal and no session to poke, so skipping it costs nothing.
The cost is bounded by the registry size — a handful of wikis — and each flush is
idempotent. The per-wiki coalescer still collapses a burst into one flush per
wiki, so a burst does not multiply by the wiki count.

The chosen shape is pinned by `WikiChangeWakeRoutingTests.wakeFansOutToEveryKnownWiki`.

## Verification

- `make build` — exit 0.
- `make test` — full suite, exit 0.
- `WIKIFS_APP_TESTS=1 swift test --filter WikiChangeBridgeTests` — 9 tests, pass.
  This suite links the app target, so it is outside the default `make test`
  graph; it must be run explicitly.
- `swift test --filter WikiChangeWakeRoutingTests` — 5 tests, pass. These live in
  the portable `WikiFSCoreTests` target so the regression pin runs in the default
  graph.
- Regression pin confirmed to fail on the old semantics. The receipt path was
  temporarily changed back to resolve against the launch-time wiki set, and the
  three new pins failed exactly as intended:
  `testPostForWikiNotInLaunchTimeSetIsHandled`,
  `testWikiAddedAfterLaunchReceivesChangesWithoutExplicitRefresh`, and
  `testWakeRefreshesEveryRegisteredWiki`. The temporary change was then reverted
  and the suite re-run green.

New tests:

- `WikiChangeWakeRoutingTests` (5) — a wake resolves for a wiki absent from the
  launch-time set; the resolution follows the current registry rather than the
  launch-time set; the wake fans out to every known wiki; an empty registry
  resolves to an empty set rather than `nil`; a foreign name is not a wiki wake.
- `WikiChangeBridgeTests` (4 new, 5 ported) — a post for a wiki not in the
  launch-time set is still handled; a wiki added to the registry after launch
  receives changes with no explicit refresh call; a wake refreshes every
  registered wiki; a foreign name never enters the wiki fan-out. The five
  pre-existing tests were ported to `start()` and the stable name rather than
  deleted.

`WikiChangeBridge.didReceiveDarwinNotification(named:)` is now `internal` so the
app-target tests can drive the receive path directly, the same precedent as the
existing `flush(wikiID:)`. Posting a real Darwin notification would exercise the
same code through an in-process broadcast that is not reliably ordered with a
test's assertions.
