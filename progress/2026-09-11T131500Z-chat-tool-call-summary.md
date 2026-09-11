---
timestamp: 2026-09-11T131500Z
title: Chat tool-call summary rows and known-warning removal
branch: feature/chat-tool-call-summary
status: complete
---

# Chat tool-call summary rows and known-warning removal

## Progress

Normal chat transcripts are concise by default. Each contiguous same-turn run
of tool calls now collapses into one expandable **Tool activity** row, and the
known ACP skill-description budget warning no longer appears in human-facing
chat output.

What changed:

- **Typed preference.** `ChatToolCallDisplayMode` (`summary` / `detailed` /
  `hidden`) lives under the single key `chat.toolCallDisplayMode`. Missing and
  invalid raw values resolve to `summary`. A one-shot, idempotent migration
  (`ChatToolCallDisplayPreference.migrate(in:)`, called from `WikiFSApp.init()`)
  maps the legacy `chat.hideToolCalls` Boolean to `hidden`/`summary` and
  preserves any existing new-key value; the legacy key is orphaned. The old
  Hide toggle left the Activity menu (live diagnostics only).
- **Settings.** Settings → Appearance gained a Chat section with a radio
  picker — Summary, Detailed, Hidden — whose footer explains that Summary
  keeps details available on expansion. `AppearanceSettingsView` takes an
  injectable `UserDefaults` so hosted tests drive the real controls against
  an isolated suite.
- **Grouping.** `ChatTranscriptPresentationProjection` is a pure app-only
  projection over the canonical `ChatDisplayProjection` output: it removes the
  known warning from assistant rows (streaming-aware while streaming,
  complete-only once final), applies the display mode, and rebuilds section
  identities from surviving rows. Group identity is
  `ChatToolCallGroupID(hostedBy:)` — the run's first tool-call ID — so a live
  run grows by replacement, never identity churn. Child calls keep their full
  payloads in a typed `ChatDisplayToolCall`; grouped children render with the
  same formatting helpers as single rows and carry `data-tool-call-id`, never
  the root `data-row-id` protocol.
- **Summary row.** One `<details>` row with the stable label "Tool activity",
  a deterministic output-blind category phrase in fixed order (files edited,
  edits, commands, files read, reads, searches, other calls), explicit
  singular/plural labels, a symbol+text state cue (`◌ Running`, `✓ Completed`,
  `⚠ N failed`, including failures inside active groups), and an accessibility
  label with total, failure, and state counts. Classification uses normalized
  known tool names plus a mechanically decidable single-path grammar with a
  fixed case-insensitive final-extension allowlist; grammar-approved paths
  deduplicate by exact normalized string, ambiguous or missing descriptors
  count once per call, and tool output is never read.
- **Warning removal.** The shared typed helper
  `AgentPresentationPreamble.visibleText(_:policy:)` in WikiFSCore has
  `streamingPrefixAware` (hides proper prefixes of the known warning while an
  assistant row streams) and `completeOnly` (removes only the complete
  warning) policies. It is wired into the normal-chat projection, the
  File Provider / `wikictl chat get` Markdown renderer, `MessageSummarizer`
  (which lost its over-broad leading-`Warning:` strip), and cached outline
  summaries with fallback to the cleaned row text.
- **Rendering.** `ChatWebView` gained group markup, semantic-variable group
  styles (light/dark, reduced motion preserved), a 400px scroll-bounded
  detail area, and `replaceChatRow` preservation of `<details>` open state so
  a growing live group never collapses. Keyboard disclosure: the summary is a
  native focus target and Return toggles both ways; macOS WebKit reserves
  bare Space for page scrolling, so Space is documented as the scroll
  shortcut rather than a disclosure key.
- **Diagnostics unchanged.** Activity windows, Show Full Activity, canonical
  transcripts, redacted diagnostics, and full debug traces keep every tool
  call and every warning byte (`ActivityTranscriptPresentation.keepsCanonicalDetailedRows`,
  `ChatDiagnosticsTests.fullDiagnosticTraceRetainsKnownSkillWarning`).

Key decisions:

- Grouping and warning cleanup are presentation-only; durable rows, SQLite,
  the XPC contract, and canonical diagnostics are untouched.
- Reasoning rows are not warning-filtered: the known family is assistant
  prose, and filtering thinking rows risks dropping real content.
- The 28-command run shape from the cited local chat is covered by a
  synthetic fixture; private wiki data never enters the repository.

## Verification

- `swift build` — clean.
- `WIKIFS_APP_TESTS=1 swift test --filter` over the chat suites: 116 tests in
  12 suites passed (preference/migration, group summary + grammar
  parameterized cases, presentation projection, detail presentation, render
  planner, API manifest, HTML presentation, display projection, linkify).
- Hosted (one worker): `ChatTranscriptHostedTests` (semantic rows, group
  survival across live replacement, keyboard disclosure, bounded scrolling),
  `AppearanceSettingsHostedTests.exposesAndPersistsAllToolCallDisplayModes`
  (real radio clicks in an isolated suite, remount persistence),
  `ActivityWindowTypedTranscriptTests` (canonical detailed rows) — passed.
- `WikiFSTests`: `AgentPresentationPreambleTests`,
  `ChatTranscriptRendererTests`, `MessageSummaryTests` — passed (61 tests in
  the combined filter run).
- Full gates `make build`, `make test`, bare `swift build`, bare `swift test`,
  and `git diff --check` were run on the feature branch before the PR; the
  manual signed-app check used the cited local chat (Summary default, mode
  switch, expansion, live growth, relaunch persistence, absent warning,
  detailed Full Activity).
