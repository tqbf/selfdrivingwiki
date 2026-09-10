---
timestamp: 2026-09-09T124500Z
title: Closed-wiki queue name resolution
branch: feature/integrated-queue-workspace
status: complete
---

# Closed-wiki name resolution for the queue workspace

Date: 2026-09-09. Branch: `feature/integrated-queue-workspace`. Layered on the
uncommitted toolbar-sizing + Run-Details-facts work; nothing committed or
pushed.

## Problem

Queue rows resolved target names only through the live session map
(`ActivityWindowView.makeNameIndex`). For a job whose wiki window was closed,
the index was empty: lint inputs rendered "Deleted page" although the pages
existed, no navigation link was offered, and navigator rows collapsed to
"Lint N pages".

## Progress

1. **Enqueue-time title capture** — `QueueItemPayload` gains an additive
   optional `recordedNames: [String: String]?` (raw target-ID strings →
   display names; legacy payloads and the daemon decode unchanged). Typed
   accessors `recordedPageTitle(for:)` / `recordedSourceName(for:)` restore
   the namespace; an empty recorded string counts as unrecorded. Captured at:
   - `PageDetailView.lintButton` (page title in hand),
   - `PagesContainerView.onLint` (titles from `store.summaries`),
   - `QueueIngestionHelper.enqueueIngestion` (source `effectiveName`s —
     trivial, so ingestion payloads got the same treatment).
2. **Precedence** — `QueueTargetNameIndex.effective(live:readOnlyCache:payload:)`
   layers live session index → payload-recorded names → read-only cache.
   `record*`'s first-match semantics make the layering the precedence; the
   recorded map records into both typed maps (PageID/SourceID dictionaries
   cannot cross-contaminate).
3. **Read-only fallback** — `QueueClosedWikiNameLoader` resolves exactly the
   payload's target IDs through `WikiReadService.asyncRead` (per-ID
   `getPage`/`getSource`; `notFound` is an expected miss), per wiki. The
   tracker caches results (`closedWikiNameIndexes`, `closedWikiNameLoadStates`,
   in-flight guard) via `refreshClosedWikiNames(for:sessions:databaseURL:loader:)`;
   the window drives it from a `.task(id: closedWikiNamesKey)`. Failures log
   via `DebugLog.store` and mark the wiki `.unavailable`; while a load is
   pending the row shows "Resolving…" — never the deletion text.
4. **Click-through** — `QueueTargetRouter` routes a known target's action:
   live session → `openTab`/`requestSidebarReveal` on the shared model then
   `openWindowBridge.openWiki` (the #583/#598 path, navigate-before-focus);
   closed → stash a `wiki://page|source?title=…&id=…` deep link via
   `SessionManager.stashPendingWikiLink` (the #635 seam) then open the
   window; `RootView` delivers the link through
   `WikiReaderView.onWikiLinkHandler` once the session exists. Activity
   window gained an injectable `closedWikiDatabaseURLProvider` (hosted tests
   inject nil to stay hermetic).

`computeRowTitle` was promoted to a `nonisolated static` (matching
`navigatorSearchText`/`progressLine`) with an instance wrapper.

## Files

- `Sources/WikiFSCore/Core/QueueTypes.swift` — payload field + accessors
- `Sources/WikiFS/Pages/PageDetailView.swift`, `Sources/WikiFS/Pages/PagesContainerView.swift`,
  `Sources/WikiFS/Queue/QueueIngestionHelper.swift` — capture sites
- `Sources/WikiFS/Queue/QueueTargetNameIndex.swift` — entries accessors + overlay
- `Sources/WikiFS/Queue/QueueClosedWikiNameLoader.swift` (new), `Sources/WikiFS/Queue/QueueTargetRouter.swift` (new)
- `Sources/WikiFS/Queue/QueueActivityTracker.swift` — closed-wiki cache + batched load;
  review follow-ups: pending-set drain loop (F3), known-missing negative cache (F4),
  CancellationError → `.loading` (F5), `UsageFormatter.cost` doc (F6)
- `Sources/WikiFS/Queue/ActivityWindowView.swift` — effective index everywhere
  names/actions resolve, Resolving… placeholder, router, `.task` driver;
  review follow-ups: `targetRowActions` live-membership gate (F1),
  `closedWikiNamesKey(for:openWikiIDs:)` (F2)
- `Tests/WikiFSAppTests/QueueClosedWikiNameResolutionTests.swift` (new, 22 tests)
- `Tests/WikiFSAppTests/ActivityWindowWorkspaceHostedTests.swift` — hermetic
  provider injection in the shared mount only
- `Tests/WikiFSAppTests/QueueOverviewLayoutHostedTests.swift` — process guard
  (follow-up 7; see the corrected pre-existing-issue note below)

## Verification

- `make build` green (builds + signs).
- `WIKIFS_APP_TESTS=1 swift test --filter QueueClosedWikiNameResolutionTests` — 22/22
  (15 original + 7 review follow-ups: open/closed action-gate ×3, key-change ×1,
  negative-cache ×1, cancellation ×1, mid-load re-plan ×1).
- Adjacent value suites (presentation, integration, outputs mapping,
  tracker ×6, job filter, usage formatter) — 124/124 after the follow-ups.
- Hosted: `ActivityWindowWorkspaceHostedTests` 15/15. Hosted:
  `PageDetailViewHostedTests`, `PageContextMenuHostedTests` pass (pre-follow-up).
- Hosted: `QueueOverviewLayoutHostedTests` still dies silently — pre-existing,
  see the corrected pre-existing-issue section; not caused by this changeset.

## Review follow-ups (2026-09-09, GLM 5.3 review round)

- Review follow-ups (GLM 5.3): F1 gates Open Page / Reveal Source on LIVE
  store membership when the wiki's session is open (`targetRowActions`, no
  more dead-end navigation for targets deleted after enqueue; closed wikis
  keep the click-through; titles still come from the effective index), and
  F2 folds the open-wiki set into the closed-wiki load's `.task` identity
  (`closedWikiNamesKey(for:openWikiIDs:)`) so closing a wiki window
  re-triggers `refreshClosedWikiNames` instead of leaving rows at
  "Resolving…".

## Pre-existing issue found (not this work)

`QueueOverviewLayoutHostedTests` silently kills the test process mid-suite
(exit 0, no output) when run in isolation on this machine: the second test
(`inventoryKeepsFloorAndExactRowModel`) starts and the runner vanishes. It
reproduces identically on a pristine worktree at HEAD `2dd1b361` — same
hazard class the Activity suite documents (AppKit automatic termination; this
suite lacks the `disableAutomaticTermination`/`beginActivity` guard). Not
caused by this branch's changes; worth a follow-up fix adding the guard.

**Follow-up correction (2026-09-09, after adding the guard):** the guard does
NOT fix this suite. With `disableAutomaticTermination` plus a suite-lifetime
`beginActivity(.userInitiated)` assertion (token retained) all active, the
death still reproduces at the same test. lldb capture of the exit: `exit`
called from `_XCTestMain`'s own epilogue (`xctest main → _XCTestMain → exit`),
exit status 0, with no `-[NSApplication terminate:]` frames and no
swift-testing executor threads alive — i.e. the xctest integrated runner
returned from its run while the swift-testing suite was mid-flight, not an
AppKit terminate path. The guard stays (harmless, same hazard class as the
Activity suite). Suggested next steps for the follow-up: mirror the Activity
suite's persistent-window pattern (one suite-lifetime window lease instead of
per-test orderOut), or investigate the runner's early return
(swift-testing/XCTestCore versions, `--testing-library` variants).

## Remaining risks

- Read-only loads are keyed to displayed-set changes; a failed load retries
  only when the displayed set changes (bounded, no tight loop) — a
  permanently missing DB logs once per such change.
- `resolvingTargetPlaceholder` ("Resolving…") is transient; on `.unavailable`
  rows fall back to the honest deletion/unavailable text per plan.
- Whole-wiki lint "Browse Pages" still requires a live session (unchanged).
