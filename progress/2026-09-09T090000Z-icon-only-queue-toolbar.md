---
timestamp: 2026-09-09T090000Z
title: Icon-only right-aligned queue toolbar
branch: feature/integrated-queue-workspace
status: complete
---

# Icon-only, right-aligned queue toolbar (design change 7)

Date: 2026-09-09. Branch: `feature/integrated-queue-workspace`. Layered on the
uncommitted toolbar-search (design change 6) work; nothing committed or pushed.

## Progress

- `Sources/WikiFS/Queue/ActivityWindowView.swift`
  - Toolbar order is now search → `ToolbarSpacer(.flexible)` →
    `ToolbarItemGroup(placement: .automatic)` holding Queue Actions and the
    Run Details toggle — the main window's geometry
    (`ContentView.swift:317-351`). Both icon controls pin to the trailing
    edge; the search sits left of them.
  - Queue Actions menu renders `.labelStyle(.iconOnly)` with
    `.help("Queue Actions")` and `.accessibilityLabel("Queue Actions")`. The
    menu contents, section guidance headers, Pause/Resume and Stop All
    semantics, and the confirmation are unchanged. The toolbar item label
    "Queue Actions" survives (customization palette).
  - `RunDetailsToolbarToggle` is icon-only: empty title, `sidebar.right`
    image (was `sidebar.trailing`), `isBordered = false`, `.imageOnly`.
    Tooltips are now "Show Run Details" / "Hide Run Details". Accessibility
    label stays "Run Details"; accessibility value stays
    "Panel shown"/"Panel hidden". The coordinator's toolbar-item label
    reassert ("Run Details") is unchanged.
- `Tests/WikiFSAppTests/ActivityWindowWorkspaceHostedTests.swift`
  - Harness finder `toolbarControls(titled:)` → `toolbarControls(labeled:)`
    (accessibility label — the button title is now "").
  - New ungated scenario `toolbarIconControlsPinnedRightVisibleAndToggling`:
    at preferred size AND 640×400 asserts both controls are hosted in
    `window.toolbar.items` with real frames (not overflow), Run Details pins
    to the trailing edge, order is search → Queue Actions → Run Details, both
    render icon-only, the Queue Actions item keeps its AppKit label, and the
    toggle still opens/closes the inspector (facts table + a11y value flip).
- Docs: `organizing-and-managing.md` (search bullet + new icons bullet; Run
  Details paragraph), `sources-and-ingestion.md` (toolbar bullet).
- `plans/integrated-queue-workspace.md`: design change 7; intro count
  corrected four → seven.

## Verification

- `WIKIFS_APP_TESTS=1 swift test --filter QueueWorkspace` — 56 tests, 2
  suites, pass.
- `WIKIFS_APP_TESTS=1 swift test --filter ActivityWindowWorkspaceHostedTests`
  — 15 tests, pass (5.3 s). The two env-gated search scenarios stay skipped
  in this sandbox (documented runner-session hazard).
- `make build` — pass (signed app).

## Behaviors observed worth remembering

- With `ToolbarSpacer(.flexible)`, the toolbar items bridge as
  `[Search][flexible space][Queue Actions][Run Details]` — the spacer is an
  item with an empty label in `toolbar.items`.
- SwiftUI re-derives toolbar item labels asynchronously; the coordinator's
  "Run Details" reassert is not mount-time observable (assert not added —
  same timing as before this change).
- SwiftUI AX attributes (`.accessibilityLabel`) and `.help` do NOT bridge to
  NSView-level probes in the swift-test host; the AppKit-visible identity for
  a toolbar menu is its `NSToolbarItem.label`.
- At 640×400 with the inspector open, closing it does not widen the center
  inventory — the navigator re-expands and keeps the reclaimed width. The
  close signal used is the button's accessibility value flip.

## Remaining risks

- The customization-palette label "Run Details" depends on the coordinator's
  async reassert winning against SwiftUI's label re-derivation — pre-existing
  timing, unchanged by this work.
- Real VoiceOver reading of the icon-only Queue Actions button relies on the
  SwiftUI AX layer (`.accessibilityLabel` set), which this host cannot probe;
  worth a manual VoiceOver pass.
- The gated search scenarios (`WIKIFS_ENABLE_SEARCH_HOSTED_TESTS=1`) have not
  re-run against the new layout; their ordering assertion (search index <
  Queue Actions index) holds structurally, but they should run in a full
  session.
