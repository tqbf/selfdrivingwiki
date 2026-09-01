---
timestamp: 2026-08-31T200000Z
title: Renderer settings package table with inline diagnostics
branch: feature/renderer-settings-package-table
status: complete
---

# Renderer settings package table with inline diagnostics

## Progress

The Renderer settings pane showed installed packages as a list of tall cards. The
list grew the Settings window, it did not align the version or the status, and it
hid the import control in a disclosure group. Diagnostics went to two sections at
the bottom of the pane, far from the package they described.

The pane now has three parts:

* **A package table.** `Table` with four columns (Package, Version, Renders,
  Status). This follows `ExtractionSettingsView.extractorRouteTable`.
  `RendererPackageTableMetrics.height(forRowCount:)` gives the height, because a
  `Table` has no intrinsic content size. The height follows the row count
  between a floor of two rows and a ceiling of eight. A short list leaves no
  space below its rows, and a long list scrolls in the table's own scroll area.
  The window height does not change with the package count. The row height and
  the header height come from the accessibility geometry of the live pane.

* **Inline diagnostics.** `RendererPackageStatus` resolves the three separate
  record fields — lifecycle state, safe-mode suppression, and the closed install
  diagnostic — into one status. Safe mode outranks the lifecycle state, because
  only the suppression is actionable. The Status column shows the short label and
  the icon. The detail under the table shows the full sentence for the selected
  package. `RendererSettingsNotice` replaces the two global strings
  `diagnostic` and `lastError`: it holds one outcome with a severity and a scope,
  so an install or a safe-mode reset renders with the package it changed. An
  outcome that no row owns, such as a rejected import, stays on the pane.
  `diagnostic` and `lastError` remain as computed properties of that notice.

* **An Add button.** `Add Package…` and a destructive `Remove` sit below the
  table, with `Refresh Registry` opposite them. The disclosure group is gone.
  The import contract copy moved to the section footer, where it is always
  visible.

Two other changes follow from inline diagnostics:

* The table keeps every record except a removal tombstone. Before, it kept only
  validated records, so a quarantined or a rejected package was invisible and the
  user got no reason. Only validated records still project descriptors, so an
  unavailable package cannot become a pinned source preference.

* Source renderer preferences use two pop-ups instead of one button for each
  installed descriptor. `Automatic` is a real choice: it calls
  `removeRendererSourcePreference` instead of pinning a sentinel version.

## Verification

* `make build` — passes.
* `WIKIFS_APP_TESTS=1 swift test --filter 'RendererSettingsManagementViewTests|RendererSettingsHelpTests|RendererSettingsPackagePickerTests'` — 13 tests pass.
* `swift test --filter RendererSettings` — 16 tests in 5 suites pass.
* A new hosted test puts `RendererSettingsView` in an `NSWindow` and checks that
  the table and the empty state lay out.
* The full suite did not run locally. CI runs it.
* The pane was seen in the running app and captured. The accessibility tree
  confirmed that the table has its own scroll area, and gave the row height
  (24 pt) and the header height (28 pt) that the metrics use.
* The content-driven height was not seen in the running app. It needs a new
  install and a restart.
