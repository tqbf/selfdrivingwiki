---
timestamp: 2026-08-31T210000Z
title: Extractor settings package table with inline diagnostics
branch: feature/extractor-settings-package-table
status: complete
---

# Extractor settings package table with inline diagnostics

## Progress

Settings → Extraction showed installed packages as two lists of disclosure
rows: active registrations first, then revisions whose activation failed. The
lists grew the Settings window, they did not align the version or the status,
and they hid the import control in a disclosure group. Diagnostics went to two
labels at the end of the section, far from the package they described.

This applies the pattern that
[the renderer pane](2026-08-31T200000Z-renderer-settings-package-table.md) now
uses.

* **A package table.** `Table` with four columns: Package, Version, Handles,
  and Status.

* **One row type.** `ExtractorPackageTableRow` folds the snapshot's two lists
  into one presentation identity. An active registration and a failed revision
  do not share an id space, so the `Subject` case tag stops a failure id from
  colliding with a registration id. Failed revisions sort first: they are the
  rows a user opens this pane to understand.

* **Inline diagnostics.** `ExtractorPackageStatus` resolves the facts the
  snapshot keeps apart — the failed-activation list, `waitingRevisionIDs`, and
  the per-requirement authorization state — into one status for each revision.
  A revision that has not activated cannot be judged on its credentials, so
  `waiting` outranks `needsAuthorization`. An optional requirement never claims
  the package needs attention. A failed revision carries the reconciler's own
  redacted message as the status payload, so the message stays with its row
  instead of living in a separate list.

  `ExtractorPackageNotice` replaces the two strings `lastError` and
  `lastDiagnostic`. It holds one outcome with a severity and a scope, so an
  import renders with the row it produced and a failed removal renders with the
  package it could not remove. A successful removal has no row left, so it
  reports on the pane. `lastError` and `lastDiagnostic` remain as computed
  properties of that notice.

* **An Add button.** `Add Package…` and `Remove Package…` are below the table,
  with `Refresh` opposite them. The import disclosure group is gone. The
  local-directory import contract and the executable-code trust warning moved
  to the section footer, where they are always visible. This matters more here
  than for renderers: an extractor package contains executable code.

### Podcast transcripts join the route table

The podcast transcript default was its own section below the route table. It is
a default extractor like PDF, HTML, and Word, so it is now a row of the same
table.

`ExtractionDefaultsTableRow` is the table's row type: `.route` or
`.podcastTranscript`. The two are different operation domains. A route resolves
through the package protocol's registrations and writes an
`ExtractorRouteSettingsSelection`; a transcript resolves through a host adapter
and writes a `PodcastTranscriptionBackend`. They share no selection type and no
id space, so the case tag is what lets one table show both without either
pretending to be the other. A synthesized route id for transcripts would have
been a sentinel.

The transcript row shows `Ready`, which is the same answer
`ExtractorRouteTableBuilder` already gives every non-package selection: a host
adapter has no package to install, activate, or authorize. The contract line
"Podcast transcripts are not package-backed in protocol revision 1." moved to
the table's section footer and the row's help text.

The route table's fixed 172 pt height is gone. It uses
`SettingsPackageTableMetrics.height(forRowCount:)` like the package table, so
the added row cannot push a route out of view and a registration-derived route
scrolls instead of growing the window.

`SettingsPackageTableMetrics` is now shared by both panes. Both tables are the
same control at the same control size, so the row height, the header height,
and the floor and ceiling have one definition.

### Two panes

Settings → Extraction does two jobs: it chooses what opens each document type,
and it manages the packages those choices draw from. Only one is needed at a
time, so a segmented switcher picks between them. `ExtractionSettingsPane` names
the two, and Defaults opens first, because that is the question the pane exists
to answer. The selection is not persisted for the same reason.

The service configuration sheet moved from the route table to above the
switcher. Both panes raise it — a route's `Configure…` and a package's
`Configure…` — so a sheet attached to one pane would never present from the
other.

`initialPane` on `ExtractionSettingsView.init` lets a hosted test mount either
pane directly. It defaults to `.defaults`, so the production call site says
nothing.

### Help

`ExtractorPackageHelp.swift` mirrors `RendererPackageHelp.swift`: a
question-mark button in the section header opens a popover that explains what a
package is, what the manifest declares, how a package runs, what import does,
which sources are supported, how credentials are authorized, and what happens
when a package cannot run.

The popover states the executable-code risk near the top, before anything the
reader might act on. That is the one thing that separates an extractor package
from a renderer package. It reuses `ExtractionSettingsView.trustWarningMessage`,
the same string the import footer shows, so the two cannot drift apart.

## Verification

* `make build` passes.
* SwiftLint `--strict` reports 0 violations.
* `WIKIFS_APP_TESTS=1 swift test --filter 'ExtractorPackageSettingsTests'` — 32
  tests pass.
* `WIKIFS_APP_TESTS=1 swift test --filter 'ExtractionRouteTableHostedTests'` —
  16 tests pass, including a new hosted test that mounts the pane with one
  active and one failed revision and confirms both tables render. The hosted
  row counts pin the transcript row: the route table holds one more row than
  its routes.
* New tests cover the row fold, the status precedence, the optional-requirement
  case, and the notice scope for import, removal, and failed removal.
* `WIKIFS_APP_TESTS=1 swift test --filter 'Extract'` — 592 tests, 3 stable
  failures plus one rotating failure. The three also fail on a clean tree and
  depend on this machine, not on this change: two need reviewed packages that
  the test environment does not install, and one needs a mise-managed `uv`. The
  rotating one is a different subprocess-timing test on each run
  (`streamProcessCapturesStderrLines`, then
  `malformedProtocolAndNonzeroExitAreTyped`); both pass in isolation, so they
  flake under parallel load rather than failing.
* The help popover was opened in the running app and captured.
* The pane was installed and seen in the running app. A clean launch opens on
  Defaults and shows all four rows, including the podcast transcript row. The
  Packages pane shows the package table, the add and remove controls, the
  inline diagnostic, and the trust warning.
* The transcript row was missing at first. The route table's rows are 32 pt
  because every cell holds a pop-up, not the 24 pt a table of text rows uses,
  so the computed height was one row short and the last row sat below the fold.
  The accessibility geometry of the live pane gave both numbers.
* The full suite did not run locally. CI runs it.
