---
timestamp: 2026-09-10T220000Z
title: Queue sidebar controls
branch: feature/integrated-queue-workspace
status: complete
---

# Queue sidebar controls

Date: 2026-09-10. Branch: `feature/integrated-queue-workspace`.

## Problem

The activity windows placed Pause, Resume, and Stop All in one Queue Actions
menu in the toolbar. These queue controls were separate concepts and required
an extra menu interaction.

## Progress

The All Jobs or Filtered Jobs header now has separate Pause or Resume and Stop
icon buttons. The controls appear before Filter in the left sidebar.

Pause and Resume share one position and change with the queue state. Stop All
keeps its destructive confirmation. Both buttons keep the existing pending
command guard. Each button has a tooltip and an accessibility label.

The toolbar now contains only the Run Details control. This change supersedes
the Queue Actions toolbar design in design changes 2 and 7.

## Test verdict

The hosted tests that asserted the Queue Actions menu and its popup structure
were wrong for the new design. Those tests asserted the removed presentation,
not queue behavior. The revised tests keep the Stop All confirmation contract
and verify that Queue Actions stays out of the toolbar.

Value tests now verify the Pause and Resume labels, symbols, and help text. The
existing queue client tests continue to verify the command routes.

## Verification

- Changed-file language-server diagnostics passed.
- The focused application run passed 45 tests in two suites.
- `make build` built and signed the application.
- `make test` passed 4,288 tests in 465 suites.
- The documentation template contract passed after the progress heading fix.
- `git diff --check` passed before the full gates.

The hosted Run Details scenario emitted the existing `NSTableView` reentrant
delegate warning. The scenario passed.
