---
timestamp: 2026-09-10T203118Z
title: Queue sidebar search
branch: feature/integrated-queue-workspace
status: complete
---

# Queue sidebar search

Date: 2026-09-10. Branch: `feature/integrated-queue-workspace`.

## Problem

The Agent Queue placed job search in the window toolbar. A custom AppKit bridge
expanded the field at wide sizes and collapsed it at narrow sizes. This made a
navigator filter compete with global queue actions.

## Progress

Job search now stays at the top of the left navigator. It appears above the
filter row and job sections. The field remains visible at all supported window
sizes.

The existing query model and loaded-job scope did not change. Search still uses
the same job title, wiki name, operation, target names, error, and report
summary text. An active query still disables reordering and uses the existing
outside-filter notice.

The toolbar now contains only global queue actions and the Run Details control.
The change removes the custom `NSSearchField` bridge, expansion state, split
width tracking, search-only metrics, and responsive toolbar tests.

## Test verdict

The first hosted test expected the native SwiftUI `TextField` to appear as an
`NSSearchField` in the SwiftPM AppKit tree. The host does not expose that node.
The test assumption was wrong.

The hosted suite now checks behavior that AppKit exposes. It checks that search
is absent from the toolbar and that navigator controls and rows remain usable
at minimum width. Value suites check the prompt, query matching, whitespace
handling, reorder guard, search text composition, and hidden-selection rules.

## Verification

- Changed-file language-server diagnostics passed.
- The focused application run passed 44 tests in two suites.
- `make build` built and signed the application.
- `make test` passed 4,288 tests in 465 suites.
- `git diff --check` passed before the final review.

The known SwiftPM warning about 12 extractor fixture files remains unrelated.
