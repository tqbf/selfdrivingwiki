---
timestamp: 2026-09-13T173000Z
title: Centralize the right-inspector outline pipeline
branch: bugfix/chat-outline-switch
status: complete
---

# Centralize the right-inspector outline pipeline

## Progress

The Outline pane opened blank for pages and sources even though registration
logs proved content was present. The root cause was structural: three
per-surface pipelines built outline rows into view-local `@State` and handed
the shell a captured closure to render them. This change replaces all three
pipelines with one value-driven pipeline; the bug class has nowhere to live.

What changed:

- `Sources/WikiFS/Detail/InspectorOutline.swift` — `OutlineHeading`,
  `InspectorOutlinePayload` (Equatable value with a two-case content enum and
  `highlightedItemID`), `InspectorOutlineSelection`, and the single
  `InspectorOutlineView` renderer with an explicit empty state.
- `Sources/WikiFS/Detail/OutlineParser.swift` — pure `headings(in:)` and
  `activeHeadingID(caretUTF16Offset:headings:)`, moved verbatim from the
  former `PageOutlineView`. The parser emits no logs.
- `RightSidebarRegistration` carries `outline: InspectorOutlinePayload` and
  one typed `onOutlineSelect` handler. The `outline: () -> AnyView` closure is
  gone; `DetailInspectorView` lost its generic `Outline` parameter.
- Page, source, and chat producers derive their payload in the body and share
  the generalized `SidebarRegistrationRefresh` (`Detail/`), keyed on the
  payload. The chat-only `projectionInput` trigger is gone. Caret tracking and
  auto-scroll survive through `OutlineParser.activeHeadingID` and the
  renderer's scroll-on-highlight-change.
- `PageOutlineView`, `ChatInspectorOutlineView`, and the five stopgap outline
  log lines from the investigation are deleted. Exactly two outline-content
  seams remain: payload acceptance in the controller and redraw in the
  renderer. `InspectorOutlineLoggingContractTests` enforces the exact set.
- Tests: `OutlineParserTests` (new), payload assertions and cross-type swap
  journey (chat → page, page → source, source → chat) plus page-editor and
  source-editor caret-move tests in `InspectorOutlineHostedTests`, a first-
  payload value oracle in `ChatOutlineRehydrationHostedTests`, and value-API
  fixtures in `InspectorTabTests` / `MetadataPanelHostedTests`.
- Design doc: `plans/inspector-outline-centralization.md`.

A checkpoint commit landed first so this refactor is one bisectable diff:
`fe9a6aee fix(inspector): defer chat outline registration and remount
inspector per subject`.

## Implementation review

A `general-purpose` reviewer audited the refactor commit against the plan
(verdict: request changes). Dispositions:

- Fixed (churn): page and source still had direct re-registration calls
  (`draftBody`, `currentMarkdownContent`, `sourcesVersion`, `headVersion`,
  `isEditing`, `showsSourceOutlineTab`) that bypassed the payload equality
  gate and republished per keystroke. Removed; the payload observer is the
  invalidation path for outline content. One deliberate exception stays:
  `sourceInspectorTabs` changes must republish because `availableTabs` lives
  in the registration but not in the payload, and a flip with zero parsed
  headings leaves the payload equal.
- Rebutted (API shape): the plan sketched the content enum as a nested
  `InspectorOutlinePayload.Content`; the implementation uses a top-level
  `InspectorOutlineContent` with the same two cases. Behavior, equality, and
  test coverage are identical; the top-level name keeps use sites readable.
- Rebutted (coverage wording): the cross-type journey runs in cyclic order
  page → source → chat → page, which contains all three directed boundaries
  the plan lists.

Out of scope, flagged for a follow-up plan: the operator's live wiki misses
the `renderer_source_preferences` table and logs a SQLite error at every
source registration. The missing-table hosted test proves this is unrelated to
the outline.

## Verification

- `make test` — 4376 tests, 469 suites, zero failures.
- `WIKIFS_APP_TESTS=1 swift test` — full opt-in app-tests target, zero
  failures (includes the hosted suites below).
- `WIKIFS_APP_TESTS=1 swift test --filter 'ChatOutlineRehydrationHostedTests|InspectorOutlineHostedTests|ChatDetailPresentationTests|RemoteChatSessionTests'`
  — 42 tests pass.
- `swift test --filter OutlineParserTests` — 19 tests pass, including the
  95K-character single-heading transcript under 50 ms.
- `swift test --filter InspectorOutlineLoggingContractTests` — the allowed
  seam set is exactly `Inspector outline payload accepted` and
  `Inspector outline redraw`, one site each; no legacy strings.
- AC.8 (operator live check in the installed signed app: pane populated on
  open for a page, the `iZ_hhezC1mA` source, and a chat, with
  `payload accepted … rows>0` in the unified log) — **confirmed by the
  operator in the running app on 2026-09-13** ("it works").
