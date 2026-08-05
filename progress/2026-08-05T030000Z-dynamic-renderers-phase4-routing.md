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
logical and exact stored preferences, restores Source/Rendered/Split per source
through the wiki store, and records short redacted fallback diagnostics. An
unextracted PDF defaults to its matching rendered pane so PDF quote anchors
remain reachable; presentable markdown, plain-text, and transcript sources
default to Source. Renderer controls are inside
the rendered pane, use non-conflicting keyboard shortcuts, carry VoiceOver
labels, and keep both split panes usable at the minimum detail width. Format
checks remain at extraction, transcription, editor, or outline decision seams;
the architecture audit guards against renderer-specific routing in the view.

Phase 5 WebView security, Phase 6 Excalidraw/JSON Canvas, and Phase 7 settings
UI remain untouched. The retained per-PR symbol/path test inventory is
`tmp/orchestration/dynamic-renderers-phase4/test-inventory-pr4.json`.

The presentation owner now clears its state before source navigation. It resolves
the default only after it loads source bytes, markdown, and origin. A later
source change resolves the default again, so a newly extracted PDF or transcript
returns from its automatic Rendered default to Source. Split uses a pinned
renderer only when that renderer remains in the current descriptor set.

## Verification

- Final implementation commit: `7c96e919030772c41ec5551457e15cf9718559a0`.
- Base: `feature/dynamic-renderers-03-persistence` at
  `41c96e17051e2f131b279fbd34d243136cff2dd5`.
- `make build`: passed.
- `make test`: passed, 3,115 tests in 265 suites.
- Focused renderer suites: passed, 30 Swift Testing tests in 2 suites;
  store/API regressions passed, 11 Swift Testing tests in 2 suites.
- Commit hooks: SwiftLint strict passed with 0 violations; bare `try?` guard
  passed; `git diff --check` passed.

## Remediation verification

- Focused renderer suites: passed, 39 Swift Testing tests in 3 suites.
- `make build`: passed.
- `make test`: passed.
- An independent Claude/Opus review found routing and persistence gaps at the
  earlier routing head. This commit addresses the default, fallback, stale-pin,
  layout, and store-backed presentation findings. A fresh exact-head review is
  required before publication.
