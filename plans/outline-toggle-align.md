# Plan: Fix #735 — Toggle Outline button alignment in detail view toolbar

## Problem
In `PageDetailView.swift`, the toolbar HStack (line 78) containing action
buttons + `Spacer()` + outline toggle lacks `.frame(maxWidth: .infinity)`.

It's nested inside two `VStack(alignment: .leading)` containers:
1. The expanded content VStack (line 67)
2. `CollapsibleDetailHeader`'s body VStack (line 31 of CollapsibleDetailHeader.swift)

The parent `.frame(maxWidth: readableContentWidth, alignment: .leading)` (line 167)
caps the header at 760pt but the HStack never explicitly requests full width.

`CollapsibleDetailHeader.titleRow` already has `.frame(maxWidth: .infinity,
alignment: .leading)` — the expanded content HStack needs the same treatment.

Without it, the HStack sizes to its content. The `Spacer()` can't expand, so
the outline toggle sits next to the action buttons instead of at the trailing
edge.

## Fix
Add `.frame(maxWidth: .infinity)` to the action buttons HStack at line 78.

This is the same idiom used by `CollapsibleDetailHeader.titleRow` (line 73) and
is the standard SwiftUI pattern for a toolbar row with leading + trailing
elements.

## Scope
- One line added: `.frame(maxWidth: .infinity)` after the HStack's closing brace
- No behavior change — only layout
- Applies to both editing and reading states (both branches are inside the
  same HStack)

## Validation
- `make build && make test`
- `make run`: verify in both editing and reading states that the outline toggle
  is at the trailing edge and action buttons at the leading edge
