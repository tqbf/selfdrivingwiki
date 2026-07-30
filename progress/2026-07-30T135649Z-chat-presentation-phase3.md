---
timestamp: 2026-07-30T13:56:49Z
title: Chat presentation Phase 3 typed app projection
branch: chat-presentation-diagnostics-phase3
status: complete
---

# Chat presentation Phase 3 typed app projection

## Progress

Added app-only typed display rows, sections, turns, unattributed sections, and
namespaced row identities. `ChatDisplayProjection` consumes reconciled typed
transcript items and validated active-block metadata. It preserves input order
and row identities, keeps paged turns promptless, reports duplicate and
noncontiguous-turn anomalies only after another turn intervenes, and rejects
malformed or orphaned active blocks.

Migrated the app chat surface from `AgentEvent` and parallel timestamps to the
typed display transcript. The WebKit renderer is now an adapter from typed rows
at the final rendering boundary. Queue/activity-feed compatibility remains
separate from chat presentation.

Replaced RemoteChatSession launcher-era presentation booleans with
`ChatRunState` at app call sites. Outline entries now use durable turn and row
identities. Permission callbacks carry `ChatPermissionResolutionIntent` and
`PermissionOptionID`; raw option text and approval Boolean are constructed only
for the XPC request.

## Audit corrections

The exact-head audit found that the final renderer adapter discarded tool-call
status and converted system notices to filtered raw events. The adapter now
mirrors the existing compatibility projection: pending/running calls use
tool-use events; completed calls use non-error tool results; failed/cancelled
calls use error tool results. Consequently, a failed read-only `Read`/`Bash`/
`Glob`/`Grep` call reaches the renderer with error semantics while successful
terminal calls remain suppressed by the established transcript filter. Notices
remain typed unattributed sections and cross the renderer boundary as visible
assistant text.

Persisted model summaries are again preferred for outline responses. The detail
view derives a `ChatMessageID`-keyed lookup from persisted `ChatMessage.summary`
metadata and passes it only to the non-live presentation path; outline fallback
continues to use `ChatSummary.summaryExtract` when the cache is absent.

The noncontiguous-turn anomaly now compares a reopened turn against the most
recently closed turn, so a notice splitting one turn is not anomalous, while a
turn that reappears after a different turn still is. Direct renderer-boundary
tests cover failed read-only, completed, cancelled, pending/running tool calls
and visible notices. The API manifest explicitly permits `AgentEvent` only in
the final `ChatTranscriptRenderingInput` compatibility adapter.

## Verification

Passed `WIKIFS_APP_TESTS=1 swift test --filter
'ChatDisplayProjectionTests|ChatTranscriptRenderingInputTests|ChatDetailPresentationTests|ChatPresentationAPIManifestTests|ChatTranscriptFilterTests'`:
44 tests in 5 suites. Log:
`tmp/phase3-corrective-focused.log`.

Ran the required full hosted command, `WIKIFS_APP_TESTS=1 swift test`, with
`HostedAppKitTestGate` enabled. It passed multiple hosted suites, including
`PageDetailViewHostedTests` and `YouTubeEmbedWebViewTests`, then stopped making
progress after starting `QuoteHighlightWebViewTests.coordinatorAppliesQuoteHighlightOnceLoaded`.
After more than 90 seconds with the Swift test helper still live and no new log
output, the locally started test process was terminated. This is a concrete
hosted-environment limitation, not an inapplicability claim. Full-run log:
`tmp/phase3-corrective-hosted-app-gate.log`.

Passed the targeted hosted gate command, `WIKIFS_APP_TESTS=1 swift test --filter
PageDetailViewHostedTests`: 2 tests in 1 suite. It mounts real AppKit/WebKit
views under `HostedAppKitTestGate`. Log:
`tmp/phase3-corrective-hosted-gate-targeted.log`.

Passed `make test`: 2,712 tests in 218 suites.

Passed `make build` after the final source edits; it produced a signed local
`Self Driving Wiki.app` with the File Provider enabled.

`git diff --check` passed before the final documentation update and is rerun
immediately before commit.
