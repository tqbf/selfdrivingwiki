---
timestamp: 2026-10-06T152553Z
title: Follow-ups from the review of the wiki-agnostic change bridge
branch: bugfix/issue-1374-review-followups
status: in-review
---

# Follow-ups from the review of the wiki-agnostic change bridge

## Progress

An independent review of the merged change-bridge work (PR #1376) found three
major and five smaller problems. This note records the fixes. The behavior the
bridge exists for is unchanged: one payload-free wake, a registry re-read at
receipt, and a per-wiki flush.

### A corrupt registry no longer blanks the live wiki list

`WikiRegistryClient.reloadFromDisk()` read `wikis.json` through the lenient
`WikiRegistry.load(from:)`. That loader turns a malformed file into an EMPTY
registry, so the app then assigned the empty list to its live `wikis` and
dropped every wiki from the sidebar. The bridge now reads through
`loadStrictly(from:)`. On a read failure it keeps the in-memory list, logs the
failure through `DebugLog.store`, and returns `false`.

The daemon already refuses the same read. `WikiDaemon.readDiskRegistry()` returns
`.unreadable(reason)` and the daemon keeps its in-memory view, because treating
corruption as mass deletion destroys state. The bridge now matches that
precedent.

A genuinely missing file is still a valid empty registry, so first-run behavior
does not change.

### The wake path no longer re-arms every wiki's flush timer

The fan-out called `ChangeCoalescer.noteChange(forWikiID:)` once per registry
wiki on every wake. That method cancels and re-arms the pending flush, so each
wake rescheduled all N timers. This contradicted the invariant the type
documents: one wiki's burst must not delay another wiki's refresh. A burst of
writes to wiki A therefore deferred a concurrent commit on wiki B until A went
quiet.

`ChangeCoalescer` now has `noteChangeIfNotPending(forWikiID:)`, which arms a
flush only when none is pending for that wiki. The wake path uses it. The
in-process hint path, `noteSuspectedExternalWrite(forWikiID:)`, keeps
`noteChange`: it carries a real wiki id, so re-arming there is correct.

The doc comments on both methods now state which path uses which.

### The tests that pin the change bridge run in CI

The tests that pin the wiki-set timing live in `WikiFSAppTests`. That target
needs `WIKIFS_APP_TESTS=1`, and no CI step named the suite, so the regression pin
did not run in CI. `WikiChangeBridgeTests` is now in the opt-in chat-lifecycle
filter in `.github/workflows/ci.yml`. The suite is non-AppKit and non-WebKit and
runs in under a second.

### Smaller corrections

- The receipt path resolved the notification name AFTER reading the registry, so
  a wake from another namespace paid a main-actor disk read it never uses. The
  name is now resolved first.
- The flush-cost comment claimed a stale registry entry costs "one lookup that
  returns nothing". The real cost is 13 enumerator signals per wiki per flush:
  `signalChange(forWikiID:)` iterates 13 containers and awaits `signalEnumerator`
  on each with a 3 s timeout, and `NSFileProviderManager(for:)` returns a manager
  for any identifier whether the domain is registered or not, so nothing
  short-circuits. The comment now states that shape. No stall was observed, so
  this is a comment correction and not a performance claim.
- Five stale references in `plans/` described the retired per-wiki notification
  API (`DarwinNotifier.postChange(forWikiID:)`) or the retired
  `refreshObservations()` call. They now describe the single-name wake and the
  registry re-read.
- The comment block above the `wiki` subcommands in `Sources/wikictl/main.swift`
  asserted that a registry change becomes visible "on its NEXT launch" and that
  the app "only watches PER-PAGE Darwin notifications, not `wikis.json` itself".
  Both statements became false when the bridge shipped. The comment now states
  the shipped behavior: the bridge re-reads `wikis.json` on every wake, so a
  registry change becomes visible on the next committing write.
- `Sources/WikiFSCore/Core/WikiChangeWakeRouting.swift` now carries the
  `// pattern: Functional Core` marker, matching its sibling
  `RendererMachineWakeRouting.swift`.

## Verification

- `make build` — exit 0.
- `make test` — full suite, exit 0.
- `swift test --filter 'ChangeCoalescerTests|WikiRegistryClientTests|WikiChangeWakeRoutingTests'`
  — 34 tests in 3 suites, pass.
- The exact CI filter, run locally as CI runs it:
  `WIKIFS_APP_TESTS=1 swift test --parallel --num-workers 1 --filter
  'ChatPresentationAPIManifestTests|DaemonChatUsageTests|DaemonChatControllerMetadataTests|DaemonChatControllerTests|WikiChangeBridgeTests'`
  — 85 tests in 5 suites, pass, with `WikiChangeBridgeTests` among them.
- `WIKIFS_APP_TESTS=1 swift test --filter WikiChangeBridgeTests` — pass.

New tests:

- `ChangeCoalescerTests` (4) — a second `noteChangeIfNotPending` for the same
  wiki does not extend the deadline and cancels nothing; `noteChange` still
  re-arms (the contrast); a 15-wake burst on wiki A does not defer wiki B's
  pending flush; a wiki is armed again once its flush has landed.
- `WikiRegistryClientTests` (3) — a malformed `wikis.json` leaves `wikis`
  untouched and returns `false`; a missing file is still adopted as an empty
  registry; an externally added wiki is adopted and the second read reports no
  change.
- `WikiChangeBridgeTests` (1) — a foreign notification name does not reload the
  registry, while the wiki-change name does.
