---
timestamp: 2026-10-04T120500Z
title: Sidebar went stale after daemon ingestion because the Darwin change bridge deallocated at launch
branch: bugfix/sidebar-stale-after-daemon-writes
status: complete
---

# Sidebar went stale after daemon ingestion because the Darwin change bridge deallocated at launch

## Symptom

The user opened "The Flower That Bloomed Nowhere". The ingestion agent created
19 pages. The pages did not show in the sidebar Pages list. "Show in List"
selected nothing. Page links from the job still opened the page detail.

Example: page `01M43ZGNZM3GRB36STPXP0APWQ` ("Linos") existed in the database.
The sidebar list held 23 pages while the database held 42.

## Root cause

`WikiFSApp` stored the bridge in `@State private var changeBridge`. The Task
that creates the bridge runs from the `AppDelegate.bootstrap` closure. That
closure captures a copy of the App struct from `init()`. SwiftUI installs
`@State` storage only after the first body evaluation. The write through the
captured copy landed in throwaway storage. No strong reference kept the bridge
alive after the Task ended. `WikiChangeBridge.deinit` calls
`CFNotificationCenterRemoveEveryObserver`, so the dead bridge removed every
Darwin observer. From then on, all cross-process writes were silent to the app
until relaunch.

The ingestion agent runs in a child process of the `wikid` daemon. Its page
writes never reach the app's in-process bus. Cross-process reloads depend on
the Darwin notification `org.sockpuppet.wiki.changed.<wikiID>`, so the sidebar
never reloaded.

The same lifetime trap already hit `menuBarItemController` and
`operationNotifier`. Both carry "strong on purpose" comments on
`AppDelegate` for this reason.

## Progress

- Read the database. The page row existed and `listPages` has no filter. The
  list itself was stale, not the query.
- Read the log. Every "Show in List" tap showed
  `PagesListView.updateNSVC: count=23 needsReload=false`. The model's
  `summaries` array never changed after launch.
- Confirmed the bridge logged "observing 7 wiki(s)" at launch, then nothing
  for the whole session. A manual post of the notification from a test script
  also produced no log line in the running app.
- Confirmed the same notification worked between two unsandboxed test
  processes. The app has no App Sandbox entitlement. The mechanism and the
  registration were correct, so the observer itself was dead.
- Moved the bridge to `AppDelegate.changeBridge`, held strongly for the app
  lifetime. The write site and the `.onChange(of: registry.wikis)` reader use
  that property. The `@State` property is gone.
- Added two observability lines to `WikiChangeBridge`: raw CF receipt before
  name matching, and `deinit`. A dead bridge now leaves a trace.

## Verification

- `make test` passes (4375 tests, 452 suites).
- Quit the app, ran `make install`, and relaunched.
- Launch log: "observing 7 wiki(s)", no `deinit` line, list count 42.
- A manual post of the per-wiki notification produced, in order:
  "CF callback fired", "Darwin change notification → wiki 01M41BV9",
  "flush wiki 01M41BV9 — poked 1 session(s)", then a sidebar re-render
  50 ms later. Before the fix, the same post produced no log lines in the
  running app.

## Limits

The ingestion executor writes pages through its own store connection. It
posts no per-page notification. The sidebar refreshes when the job completes,
not per page. That behavior is out of scope for this fix.
