# Plan: Fix outline toggle alignment in PageDetailView + SourceDetailView

## Goal
The chat detail view (ChatView) has the outline toggle button correctly pinned to the view's right edge. The page and source detail views have the toggle sitting at the readable-content-width edge, not the view edge. Fix both to match the chat layout by moving the action toolbar row out of `CollapsibleDetailHeader`'s content closure (which is constrained to readable content width) and making it a sibling row.

## Root cause

### ChatView (CORRECT — the reference pattern)
`Sources/WikiFS/Chats/ChatView.swift:680-775`:
- The action toolbar HStack (Show in List / Share / Reveal in Finder / Reveal Debug Folder + outline toggle) is a **SIBLING** of `CollapsibleDetailHeader`, rendered outside its content closure.
- Both rows (title header + action toolbar) are gated on `isHeaderExpanded` for collapse behavior.
- Result: outline toggle sits at the view's right edge. ✅

### PageDetailView (INCORRECT)
`Sources/WikiFS/Pages/PageDetailView.swift:60-175`:
- The action toolbar HStack (Save/Cancel + Edit + Lint + Show in List + Share + Reveal in Finder + outline toggle) is **INSIDE** `CollapsibleDetailHeader`'s content closure.
- `CollapsibleDetailHeader` constrains its expanded content to readable content width internally.
- The `Spacer()` only reaches the readable content edge, not the view edge.

### SourceDetailView (INCORRECT — same pattern)
`Sources/WikiFS/Sources/SourceDetailView.swift:505+`:
- Same structure: action toolbar HStack is inside `CollapsibleDetailHeader`'s content closure.

## The fix

Mirror the ChatView pattern: wrap `CollapsibleDetailHeader` and the action toolbar together in a `VStack`, keeping only metadata inside the header's content closure and moving the action toolbar HStack to be a sibling row gated on `isHeaderExpanded`.

### PageDetailView changes (`Sources/WikiFS/Pages/PageDetailView.swift`)
1. Extract the action toolbar HStack (Save/Cancel/Edit/Lint/Show in List/Share/Reveal/Spacer/outline toggle) from inside `CollapsibleDetailHeader`'s content closure into a new `pageActionBar` property.
2. Move it to be a sibling VStack row AFTER `CollapsibleDetailHeader`, gated on `isHeaderExpanded`, with `.frame(maxWidth: .infinity)` and `.transition(.opacity)` (matching ChatView).
3. Keep the date row + provenance section inside the header content (those are fine at content width).

### SourceDetailView changes (`Sources/WikiFS/Sources/SourceDetailView.swift`)
Same extraction: the editing Save/Cancel/outline HStack and the reading branch's utility HStack (Edit/Show in List/Share/Finder/outline) both move to a `sourceActionBar` sibling row.

## Files modified
| File | Change |
|---|---|
| `Sources/WikiFS/Pages/PageDetailView.swift` | Extract action toolbar to `pageActionBar` sibling row |
| `Sources/WikiFS/Sources/SourceDetailView.swift` | Same extraction to `sourceActionBar` sibling row |

## Acceptance criteria
- [ ] PageDetailView's outline toggle sits at the view's right edge (same as ChatView).
- [ ] SourceDetailView's outline toggle sits at the view's right edge.
- [ ] Action buttons (Edit, Save, Cancel, Lint, Show in List, Share, Reveal in Finder) still work.
- [ ] Header collapse/expand still hides/shows the action toolbar.
- [ ] No layout regression on date row / provenance (they stay at content width).
- [ ] `make build && make test` passes.
- [ ] No `print` (DebugLog only); no bare `try?`.

## Reference
ChatView header section: `Sources/WikiFS/Chats/ChatView.swift:670-775`.
