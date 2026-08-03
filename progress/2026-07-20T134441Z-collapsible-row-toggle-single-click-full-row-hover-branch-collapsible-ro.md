---
timestamp: 2026-07-20T134441Z
title: "2026-07-20 — Collapsible row toggle: single-click + full-row + hover (branch `collapsible-row-toggle`)"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-07-20 — Collapsible row toggle: single-click + full-row + hover (branch `collapsible-row-toggle`)

## Progress


**Problem.** The chat title-pane section would not toggle on click — only the
title text responded (and only to a double-click, which entered rename). Page
*appeared* to work but only because its titles are short; Source had the same
latent bug. Root cause was gesture competition + unreachable empty space:
`CollapsibleDetailHeader.titleRow` used `.onTapGesture(count: 2)` for the toggle
and `EditableTitle`'s `Text` *also* used `.onTapGesture(count: 2)` for rename —
so double-clicks on the text always renamed, never toggled. The row toggle was
only reachable by double-clicking empty space right of the title; but chat
titles are `titleLineLimit: 1` and long, filling the 760pt `readableContentWidth`
row, leaving no reachable empty space. All three call sites apply the 760pt cap
identically, so Source had the same latent bug.

**Fix.** Switched the shared `CollapsibleDetailHeader.titleRow` toggle from
`count: 2` to a single tap (`.onTapGesture { … }`) on the full-row
`contentShape(Rectangle())`. A single click anywhere on the row now toggles
regardless of title length or remaining empty space; `EditableTitle` rename
stays on `count: 2`, so an actual double-click of the text still renames. The
chevron `Button` is kept as a complementary disclosure affordance (consumes its
own tap, no double-fire). Applied to all three title panes (Page / Chat /
Source) at once via the shared component — no call-site change needed.

**Hover bubble.** New `Sources/WikiFS/Editor/HoverRowBackground.swift` — a
reusable `ViewModifier` (`Color.primary.opacity(0.07)` in a
`RoundedRectangle(cornerRadius: 6, style: .continuous)`, driven by `.onHover`,
animated with `.animation(.easeInOut(duration: 0.15), value: isHovered)`).
Adapts to light/dark automatically via `Color.primary`. Applied to
`CollapsibleDetailHeader.titleRow` so the bubble spans the whole hit area.

**Provenance.** Kept native `DisclosureGroup` in `PageDetailView.provenanceSection`
(semantics/accessibility + `.task(id:)` lazy-load gating preserved); extended
its label to a full-width `HStack { Label + Spacer(minLength: 0) }` with
`.frame(maxWidth: .infinity)` + `.contentShape(Rectangle())` + `.hoverRowBackground()`
so the whole row is hit-testable and gets the hover affordance.

Plan: `plans/collapsible-row-toggle-v2.md`.

### Changed files

- **NEW** `Sources/WikiFS/Editor/HoverRowBackground.swift` — reusable hover modifier.
- `Sources/WikiFS/Editor/CollapsibleDetailHeader.swift` — `count: 2` → single
  tap (`:74`); `.hoverRowBackground()` on `titleRow`; DebugLog msg updated;
  chevron + contentShape + frame preserved.
- `Sources/WikiFS/Pages/PageDetailView.swift` — provenance label wrapped to
  full row + hover (`:426–436`).
- No call-site change in `ChatView.swift` / `SourceDetailView.swift` /
- `PageDetailView.swift` header call site — all inherit the fix from the shared
  component.

### Validation

- `make build` ✓ (also regenerates GeneratedPrompts/Version).
- `make test` ✓ — 3131 tests in 264 suites pass.
- App launches cleanly (no new `.ips` crash report).
- **Live gesture validation is NOT unit-testable** (per
  `reproducing-live-ui-bugs` skill) and requires a human at the keyboard. The
  toggle seam is logged via `DebugLog.tabs("CollapsibleDetailHeader: header
  tapped — wasExpanded=…")`; a reviewer can `log show --predicate
  'subsystem == "com.selfdrivingwiki.debug"' --last 1m` while clicking to
  confirm exactly what fires. See plan §7 for the full manual checklist (single
  on text toggles, double on text still renames, hover shows in light + dark,
  chevron single-fires, provenance full-row toggles). **Fallback if a single
  click on the chat title text does not toggle:** switch the row to
  `.simultaneousGesture(TapGesture().onEnded { … })` (plan §10 Gotcha #1).

---

## Verification

Historical verification remains in the progress record above.
