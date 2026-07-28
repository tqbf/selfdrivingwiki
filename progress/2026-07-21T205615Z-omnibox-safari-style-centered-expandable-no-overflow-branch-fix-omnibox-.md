---
timestamp: 2026-07-21T205615Z
title: "2026-07-21 — Omnibox: Safari-style centered, expandable, no overflow (branch `fix/omnibox-centered-no-overflow`)"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-07-21 — Omnibox: Safari-style centered, expandable, no overflow (branch `fix/omnibox-centered-no-overflow`)

## Progress


**Problem.** The toolbar omnibox rendered full-width flush-left and
*consistently* dropped into the `»` overflow. Root cause: `OmniboxLayout`
tried to *predict* NSToolbar's internal layout with hand-tuned constants
(`closedLeadingChrome` 214, `openLeadingChrome` 70, `trailingMargin` 30,
`homeButtonExtra` 26, an overflow spacer) and sized the field to ~100% of the
detail region. NSToolbar's overflow is all-or-nothing, so any error in those
guesses dumped the whole group to `»`. Unit tests passed throughout because
they exercised the arithmetic, not whether the constants matched NSToolbar.

**Fix — cooperate with NSToolbar instead of predicting it.**
- Split into two toolbar items: `OmniboxNavButtons` (Back/Forward/Home) in
  `.navigation` (flush-left, Safari-style) and the field in `.principal`, which
  NSToolbar centers for us. Deleted all the leading-chrome / overflow-spacer /
  position-prediction math (~300 lines net removed).
- The field is sized to the detail region minus a side margin on each side,
  clamped to `[minWidth 240, maxWidth 820]`. It never approaches 100% of the
  region, so the overflow trigger can't fire; NSToolbar centers the pill.
- **Sidebar-aware margin** (`sideMarginOpen` 150 / `sideMarginClosed` 290): with
  the sidebar hidden the field centers across the whole window and its left
  margin must clear traffic-lights + toggle + nav (~250pt); with it shown, only
  the ~102pt nav cluster is in the region. Symmetric centering can't give the
  left more than the right, so both margins take the larger value when hidden.
- **macOS 26 (Tahoe) glass bubble:** the auto-grouped nav capsule clipped the
  wide `house` glyph against its edge — added `navBubbleInset` (10pt) so the
  capsule leaves breathing room around the icons.

**Changed files.** `Sources/WikiFS/Editor/OmniboxLayout.swift` (rewritten to a
centered-pill width fn), `Sources/WikiFS/Editor/AddressBarView.swift` (field-only
principal view + new `OmniboxNavButtons`), `Sources/WikiFS/Window/ContentView.swift`
(two toolbar items), `Sources/WikiFS/Window/SidebarView.swift` (WikiSwitcher moved
to the sidebar's bottom bar, freeing the toolbar), and both omnibox test files
rewritten for the new model.

**Verified live** (screenshots + accessibility frame reads): centered to <0.5pt in
both sidebar states; no overflow on fresh launch or incremental drag-resize
720↔1200; home icon clears the bubble. `swift build` clean, 11/11 omnibox tests
pass.

**Build:** `swift build && swift test`.

## Verification

Historical verification remains in the progress record above.
