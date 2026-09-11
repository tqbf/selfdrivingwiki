---
timestamp: 2026-09-11T135500Z
title: Interim notes and folded reasoning in chat Summary mode
branch: feature/chat-tool-call-summary
status: complete
---

# Interim notes and folded reasoning in chat Summary mode

## Progress

Operator feedback after the tool-call summary shipped: a long running turn
still showed a full page of content before the final answer. The remaining
bulk was the assistant's interim text blocks (full markdown emitted between
tool runs) and the per-run reasoning lines. In Summary mode, a turn now reads
as: question, one compact row per work run, the final answer.

- **Interim notes.** Within a turn, only the LAST assistant block — the
  answer — stays expanded. Earlier assistant blocks become one-line
  expandable disclosures ("Note" + first-line preview). Nothing is deleted;
  an interim note keeps its durable message ID (`assistantInterim` row case),
  so live updates replace it in place and expanding shows the full markdown.
- **Folded reasoning.** Reasoning adjacent to a tool run joins that run: the
  group row now carries typed `ChatDisplayReasoningEntry` values rendered in
  the expanded body (dim, italic, `data-reasoning-id`, never the root
  `data-row-id`). Reasoning never affects category counts or state. Reasoning
  with no adjacent tools keeps its own collapsed row; messages, notices, and
  failures still end runs.
- **Outline.** The chat outline excerpts the turn's final answer (last
  assistant block) rather than the first block, so an interim note cannot
  become the response excerpt.
- **Scope.** Presentation-only in the Summary path; Detailed mode keeps every
  block fully expanded, Hidden mode hides only tool rows, and canonical data,
  Activity views, and diagnostics are untouched.

## Verification

- `swift build` clean; `make build` passed; `make test` passed; bare
  `swift test` passed (4328 tests in 467 suites).
- Focused chat suites (`WIKIFS_APP_TESTS=1`): 124 tests in 13 suites passed,
  including new coverage — interim collapse with the final answer preserved,
  reasoning folding into runs, orphan reasoning kept standalone, streaming
  answer stays expanded, outline excerpts the final answer, interim HTML
  markup, folded-reasoning group markup, and the extended documentation
  contract.
- Hosted (one worker): `ChatTranscriptHostedTests`,
  `AppearanceSettingsHostedTests`, `ActivityWindowTypedTranscriptTests` —
  16 tests passed.
- `git diff --check` clean.
