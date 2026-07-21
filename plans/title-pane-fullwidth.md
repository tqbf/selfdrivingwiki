# Title Pane Full-Width Fix (DRY)

## Problem
The `CollapsibleDetailHeader` (title pane) in detail views is capped at
`readableContentWidth` (760pt), so the `.hoverRowBackground()` pill only
stretches to ~736pt instead of the full window width. The 760pt cap should
apply ONLY to the expanded body content (metadata, action buttons, provenance),
not the title row.

## Root Cause
At each call site (`PageDetailView.swift` L168, `SourceDetailView.swift` L747,
`ChatView.swift` L668), the entire `CollapsibleDetailHeader` was wrapped in
`.frame(maxWidth: readableContentWidth)`, capping both the title row and the
expanded content at 760pt.

## Fix (DRY)
Move the `readableContentWidth` cap INTO `CollapsibleDetailHeader` itself, so
the layout contract is owned in one place:

1. **`CollapsibleDetailHeader.swift`** — Apply
   `.frame(maxWidth: readableContentWidth, alignment: .leading)` to the
   `expandedContent()` call inside the body. The title row keeps
   `.frame(maxWidth: .infinity)` so it stretches full width.

2. **Call sites** (PageDetailView, SourceDetailView, ChatView) — Remove the
   `.frame(maxWidth: readableContentWidth)` that was capping the whole header.
   Keep `.padding(.horizontal, contentInset)` on the header for the title row's
   12pt inset from the window edge.

### Layout contract
- **Title row**: full width of the padded container (window − 24pt), hover pill
  stretches edge-to-edge.
- **Expanded content**: capped at 760pt, aligned leading, same left edge as the
  title text.
- **Body** (editor/reader/provenance below the header): unchanged, still capped
  at `readableContentWidth` + `contentInset` padding.

## Guardrails
- Do NOT change `readableContentWidth` (760) or `contentInset` (12) values.
- No `print` (DebugLog only); no bare `try?`.
