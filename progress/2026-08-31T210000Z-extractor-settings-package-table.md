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

`SettingsPackageTableMetrics` is now shared by both panes. Both tables are the
same control at the same control size, so the row height, the header height,
and the floor and ceiling have one definition.

## Verification

* `make build` passes.
* SwiftLint `--strict` reports 0 violations.
* `WIKIFS_APP_TESTS=1 swift test --filter 'ExtractorPackageSettingsTests'` — 32
  tests pass.
* `WIKIFS_APP_TESTS=1 swift test --filter 'ExtractionRouteTableHostedTests'` —
  15 tests pass, including a new hosted test that mounts the pane with one
  active and one failed revision and confirms both tables render.
* New tests cover the row fold, the status precedence, the optional-requirement
  case, and the notice scope for import, removal, and failed removal.
* `WIKIFS_APP_TESTS=1 swift test --filter 'Extract'` — 590 tests, 3 failures.
  All three also fail on a clean tree and depend on this machine, not on this
  change: two need reviewed packages that the test environment does not
  install, and one needs a mise-managed `uv`.
* The change was not seen in the running app. The app on this machine runs an
  older build.
* The full suite did not run locally. CI runs it.
