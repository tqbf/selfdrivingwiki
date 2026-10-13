---
timestamp: 2026-10-13T165438Z
title: ACP failed tool calls kept no cause; exec-kernel sandbox denial was invisible
branch: bugfix/exec-kernel-sandbox-failure-detail
status: complete
---

# ACP failed tool calls kept no cause; exec-kernel sandbox denial was invisible (#1417)

Issue: tqbf/selfdrivingwiki#1417.

## Progress

### Symptom

In an agent chat, an ACP agent's exec tooling spawned a `node_repl` kernel.
The kernel applies its own nested `sandbox-exec` sandbox; macOS denied the
nested `sandbox_apply` (EPERM) and the kernel died at startup (exit 71). The
app received the failure as a `session/update` → `tool_call_update` with
status `failed`, and the update carried the full diagnostics in
`rawOutput.result.content[].text`:

```
node_repl kernel exited unexpectedly

node_repl diagnostics: {"kernel_pid":85011,"kernel_status":"exited(code=71)","kernel_stderr_tail":"sandbox-exec: sandbox_apply: Operation not permitted","reason":"stdout_eof","stream_error":null}
```

The persisted transcript row showed `toolName: Bash, status: failed,
detail: ""`. The cause was dropped, so the agent misdiagnosed the failures as
a workspace-sandbox policy denial and burned retries.

### Root cause

Two drops composed:

1. `ACPEventTranslator.toolOutput` (`Sources/WikiFSEngine/ACPPermissions.swift`)
   extracts output text from rendered `content`, then from `rawOutput` as a
   plain string or a structured dict with `formatted_output` / `output` /
   `metadata.output` keys. The captured payload used none of those shapes: the
   agent tunneled an MCP `tools/call` result envelope through `rawOutput`
   (`{"result": {"content": [{"type": "text", "text": …}]}}`). The extraction
   candidate list had no case for it, so the text was dropped and `summary`
   was nil for both failed and completed calls.
2. With `summary` nil, `AgentEventTranscriptTranslator` built the transcript
   row with `output: nil` and `detail: <input summary>`. The ACP agent had sent
   no `rawInput` or locations, so the input summary was empty — the row carried
   nothing at all.

### Fix 1 — persist the cause

- `ACPEventTranslator.toolOutput` now also extracts the text blocks of an MCP
  result envelope nested in structured `rawOutput` (new `mcpResultText`).
- For **failed** calls, the extracted text is carried into the persisted row:
  `ACPToolFailureClassification.annotatedDetail` bounds the text and prefixes a
  classified reason when one matches. Empty text stays empty; no annotation is
  invented for absent diagnostics.
- `AgentEventTranscriptTranslator` falls back to the bounded failure text for
  the row `detail` when a failed call has no input descriptor. When an input
  descriptor exists (a Bash command, a path), it stays the row detail and the
  cause rides in `output` — `detail` remains the tool-input descriptor per the
  `ChatTranscriptToolCallItem` contract.
- Completed calls keep their previous behavior: unannotated output, input
  descriptor as detail. (The extraction fix does mean a completed call whose
  `rawOutput` uses the MCP envelope now keeps its output text instead of
  dropping it — the same drop, fixed once. Known follow-up: the completed-call
  envelope extraction is unbounded; see the PR discussion.)

### Fix 2 — classify and make the failure actionable (scoping decision)

The tool loop lives inside the ACP agent subprocess. The app's client role
(`ClientDelegate`) can answer fs/terminal/permission/elicitation requests only,
and `session/update` notifications are one-way agent → client; the swift-acp
protocol surface has no way to inject a tool result into the agent's own loop.
Faking one would corrupt the agent's turn state, so we did not try.

Instead the strongest truthful surface is the transcript row itself:

- New `ACPToolFailureClassification` (`Sources/WikiFSEngine/`) recognizes the
  kernel-sandbox startup signature (`sandbox-exec: sandbox_apply` matched as a
  substring, so kernel pids, exit codes, and stderr tails do not affect
  recognition) and produces `.execKernelSandboxDenied` with an
  `actionableReason` worded for both audiences: the exec kernel could not
  start its sandbox, this is not a workspace-permission denial, retrying the
  same tool reproduces it, and the terminal-exec path may still work.
- The classified reason prefixes the persisted failure text (`output`, and
  `detail` when the detail fell back), so the UI, the legacy flat
  `chat_messages` projection, export, and search all carry it.

### Tests

- `Tests/WikiFSAppTests/ACPBackendTests.swift` (+8): the captured payload is
  decoded from the real wire JSON (MCP envelope, failed status) and must yield
  the annotated diagnostics; completed calls with the same envelope stay
  unannotated; unrelated error text stays verbatim; failed calls with no
  output emit nil; the signature is positive on the payload and negative on
  bare exit codes, unrelated text, and empty text; the 2 KiB bound truncates
  with an explicit marker and passes short/empty text through.
- `Tests/WikiFSTests/AgentEventTranscriptTranslatorTests.swift` (+3): a failed
  result with no input descriptor produces a transcript row whose `detail`
  contains the captured cause text; oversized causes are truncated at the
  named bound; empty causes leave `detail` empty and a described call keeps
  its input descriptor.

### Notes

- The failed-call `detail` fallback lives in the generic
  `AgentEventTranscriptTranslator`, so the CLI backend gets the same
  cause-in-detail behavior for failed tool rows without an input descriptor.
  That is deliberate: same bug class, one fix.
- The bound is character-based (`maxCauseTextLength = 2_048`), not byte-based;
  JSON-escaped multi-byte text can exceed 2 KiB on disk, which is acceptable
  for a display field.
- The classifier matches a quoted signature too (a failed log-grep that merely
  quotes `sandbox-exec: sandbox_apply` would get the prefix). Mitigated: the
  raw cause is preserved beneath the annotation, and classification only ever
  prefixes.
- The FIFO fallback row for an unmatched result shares the next tool's
  ordinal, so a bare failed result immediately followed by a new `.toolUse`
  replaces it (pre-existing behavior, pinned by
  `emptyOrDescribedFailedCauseKeepsExistingDetailBehavior` using one
  translator per turn).

## Verification

- `make build` — ✓ built + signed `build/Self Driving Wiki.app`.
- `make test` — ✓ exit 0, "✓ tests pass"; headline bundle 4603 tests /
  473 suites. **Correction record:** the first committed run of `make test`
  on this branch failed deterministically because this progress file itself
  violated `progressEntriesFollowTemplate` (missing YAML front matter and
  required headings; `DocumentationContractTests.swift:320,325`). The failure
  was initially misattributed to flaky parallel-run noise with a zero-
  diagnostic log; the independent review's targeted run identified the real
  cause, this entry now follows `progress/TEMPLATE.md`, and `make test` is
  green with the file in tree. (A separate environmental silent-failure
  signature — "WikiFSCoreTests reported failures" with zero diagnostics —
  exists on unrelated branches; see `tmp/wiki-strategy-final-bare-test.log`.
  It is not this branch's failure.)
- `swift test --filter AgentEventTranscriptTranslatorTests` — 19 tests passed
  (16 existing + 3 new).
- `WIKIFS_APP_TESTS=1 swift test --filter ACPBackendTests` — 82 tests passed
  (74 existing + 8 new).
- `WIKIFS_APP_TESTS=1 make test` — ✓ exit 0, "✓ tests pass"; app-target
  suites included (`ACPBackendTests`, `AgentEventTranscriptTranslatorTests`
  both passed in-run).
