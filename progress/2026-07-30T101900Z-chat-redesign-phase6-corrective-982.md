---
timestamp: 2026-07-30T101900Z
title: "2026-07-30 — Chat redesign Phase 6 corrective work (#982)"
branch: chat-redesign-phase6-corrective
status: verification-limited
---

# 2026-07-30 — Chat redesign Phase 6 corrective work (#982)

Local date: July 30, 2026 (America/Los_Angeles).

## Progress

The corrective scope gives each daemon runtime close a single owner. A nested
`stopSession` or transport-close event observes that owner but cannot clear its
close state, rotate a second generation, or start a queued turn before the
original close completes. The close owner recovers durable work submitted while
its awaited runtime close released the actor. Focused pause-gate tests cover
interleaved stop and transport-close paths, plus a submitted turn during
`stopSession`.

The controller registry now clears a fired timer before it invokes host
eviction, re-arms rejected idle reservations, and schedules both fresh and
warm controller acquisitions. A typed reservation result makes missing and
already-reserved entries explicit. The host accepts an injected idle delay for
deterministic production-timer coverage; the regression suite also checks
direct reservation revocation and that a cold controller has exactly one timer.
If a draft rollback deletes its chat row while eviction refuses, the host
re-arms cleanup instead of retaining a deleted-chat controller indefinitely.

The chat composer reads an observable `RemoteChatSession` cache of
`AgentProvidersConfig`, initialized once per session and refreshed after the
atomic Settings save notification. It therefore no longer decodes the sidecar
from `ChatDetailView.body`. Invalid resolved provider/model configuration
disables input and send, prevents queueing a new follow-up, preserves an
already queued follow-up, and checks again immediately before submission.

Phase documentation retains the live `LauncherChatAgentRuntime` polling
compatibility path and targeted badge diagnostics in its claims. The
`DebugLog.chatLive` description names `generatingChatIDs`. Per `AGENTS.md`,
this bug-fix record is not indexed in `PLAN.md`; it is cross-linked from the
Phase 6 completion note in `plans/chat-architecture-redesign.md` instead.

## Verification

`make prompts` and `make build` passed after the corrective changes. Focused
daemon-controller (25), daemon-host (24, including the injected production
timer), presentation (8), configuration-cache (1), coordinator badge (1), and
chat API-manifest (1) tests passed. The focused host and controller runs used
`WIKIFS_APP_TESTS=1` because the app target is opt-in to the default SwiftPM
test graph.

The July 30 `make test` command must **not** be counted as passing. It reached
the broad suite but made no material progress for ten minutes in the unrelated
`QuotaFallbackIntegrationTests.testTransientZaiErrorNoFallback` path:
`QuotaFallbackCoordinator.loadQuotaState()` was blocked in `Data(contentsOf:)`.
The run was terminated at the documented threshold; its sample is retained at
`tmp/make-test-hang-sample.txt`. The host had 5.8–5.9 GiB free at that point,
so this is distinct from the earlier `IdentifierBoundaryTypecheckTests`
disk-full limitation. Full hosted coverage and mutation testing remain
unavailable locally and are not claimed as passed; fresh PR CI is the pending
full-gate evidence.
