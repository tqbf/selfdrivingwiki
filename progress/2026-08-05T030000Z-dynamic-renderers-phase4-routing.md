---
timestamp: 2026-08-05T030000Z
title: Dynamic renderers Phase 4 PR 4 generic presentation routing
issue: 1026
branch: feature/dynamic-renderers-04-routing
status: in_review
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

- Final implementation/fix commit: `bd71665fd9a13d9eb4d988e3ab0b6d15765a27b9`.
- Base: `feature/dynamic-renderers-03-persistence` at
  `41c96e17051e2f131b279fbd34d243136cff2dd5`.
- Exact-head `make build`: passed; signed app assembled.
- Exact-head `make test`: passed, 3,116 tests in 264 suites.
- Exact-head focused renderer/app/resolution/persistence suites: passed, 116
  Swift Testing tests in 7 suites, including `RendererPhase3PortableTests`.
- Exact-head `make lint`: passed with 0 violations; bare `try?` guard passed;
  `git diff --check` passed.

## Remediation verification

- The exact-head remediation fixes live Source fallback persistence, Source
  preference retention, delayed-fallback source identity, persisted settings
  payload versioning with legacy v1 decode compatibility, and lifecycle source
  identity resolution. The retained inventory is updated for all changed
  production symbols. A fresh independent Claude/Opus exact-head review is
  required before publication.
