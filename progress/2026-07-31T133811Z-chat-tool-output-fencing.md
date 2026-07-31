---
timestamp: 2026-07-31T133811Z
title: "2026-07-31 — Chat tool output fencing follow-up"
branch: fix/chat-tool-output-fencing
status: complete
timestamp_source: local-clock-america-los-angeles
---

# 2026-07-31 — Chat tool output fencing follow-up

## Progress

ACP tool results can contain Markdown-fenced output. The completed chat row
previously replaced its tool descriptor with that output. The collapsed row
could then show a fence marker instead of the command.

The typed transcript now stores a stable tool descriptor and a separate raw
tool-output value. Completion keeps the descriptor and stores the output.
The renderer uses the descriptor for the collapsed row and the output for the
escaped expanded body.

The renderer also skips Markdown fence markers when it renders older rows
that have output only. It does not change stored output. The Core compatibility
projection still uses terminal output for its existing persistence writes.

## Verification

- The focused ACP permission, runtime, and transcript presentation tests
  passed. The run covered 60 tests in three suites.
- The focused Codable compatibility and typed-domain manifest tests passed.
- `ChatTranscriptHostedTests` passed two hosted AppKit tests.
- `make build` passed.
- `make test` passed 2,716 tests in 219 suites.
- The aggregate app-test run used a 60-second watchdog. It made progress but
  did not produce an aggregate result. The watchdog stopped the helper. This
  gate is inconclusive.
- The concurrent SwiftUI log capture found no matching update-cycle warning
  during the focused hosted run.
- `make lint` and `git diff --check` passed.
- Mutation testing was not run.
