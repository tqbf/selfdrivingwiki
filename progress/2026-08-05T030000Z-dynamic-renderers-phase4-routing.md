---
timestamp: 2026-08-05T030000Z
title: Dynamic renderers Phase 4 PR 4 generic presentation routing
issue: 1026
branch: feature/dynamic-renderers-04-routing
status: complete
---

# Dynamic renderers Phase 4 PR 4 generic presentation routing

## Progress

PR 4 routes `SourceDetailView` through the generic
`RendererPresentationState` → `SourceRendererPresentationPlanner` →
`RendererHostView` seam. `Source` remains the permanent fallback. PDF, HTML,
Mermaid, and media construction is owned by the built-in factory map, while
the planner preserves quote anchors, HTML-without-markdown behavior, Mermaid
standalone/fenced inputs, media transcript state, and editor/outline inputs.

The rendered pane pins an exact renderer reference for its lifetime, resolves
logical and exact stored preferences, restores Source/Rendered/Split per source,
and records short redacted fallback diagnostics. Renderer controls are inside
the rendered pane, use non-conflicting keyboard shortcuts, carry VoiceOver
labels, and keep both split panes usable at the minimum detail width. Format
checks remain at extraction, transcription, editor, or outline decision seams;
the architecture audit guards against renderer-specific routing in the view.

Phase 5 WebView security, Phase 6 Excalidraw/JSON Canvas, and Phase 7 settings
UI remain untouched. The retained per-PR symbol/path test inventory is
`tmp/orchestration/dynamic-renderers-phase4/test-inventory-pr4.json`.

## Verification

- Final implementation head: `832efb00fb126a4e7382d3287678291765854167`.
- Base: `feature/dynamic-renderers-03-persistence` at
  `41c96e17051e2f131b279fbd34d243136cff2dd5`.
- `make build`: passed.
- `make test`: passed, 3,110 tests in 264 suites.
- Focused renderer suites: passed, 33 Swift Testing tests in 4 suites.
- Commit hooks: SwiftLint strict passed with 0 violations; bare `try?` guard
  passed; `git diff --check` passed.
- An independent Claude/Opus review found wiring gaps at the earlier routing
  head; Terra fixes and owner integration commits addressed those findings.
  A fresh exact-head review is required before publication.
