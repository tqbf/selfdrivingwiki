---
timestamp: 2026-07-16T154305Z
title: "2026-07-16 — \"Worked for Xs\" footer with hover-swap (branch `social-dugong`)"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-07-16 — "Worked for Xs" footer with hover-swap (branch `social-dugong`)

## Progress


**Implemented.** Added a "Worked for Xs" duration footer under assistant
responses that swaps to the completion timestamp on hover — matching
Paseo's `AssistantTurnFooter` pattern.

- **Why:** Paseo renders a metadata line after each assistant turn showing
  how long the agent took ("Worked for 4s"); hovering swaps it to the
  completion time ("2:34 PM"). WikiFS had no such metadata.
- **Challenge:** `AgentEvent` has no timestamp fields — events are pure
  data (`.assistantText(String)`, etc.). The timing was tracked only at the
  launcher level (`runStartedAt`) for the whole session, not per-event.
- **What changed:**
  1. **`AgentEvent`** — moved `isInternalTranscriptEvent` from `WikiFS` to `WikiFSCore`; added `isVisibleInTranscript(in:)` + `hasAssistantText` helper.
  2. **`AgentLauncher`** — added `eventTimestamps: [Date]` parallel to `events`, tracked in lockstep across all append/replace/reset paths.
  3. **`[AgentEvent]` extension** — refactored `transcriptVisible` to use `transcriptVisibleIndices` for parallel-array filtering.
  4. **`ChatView`** — computes `displayTimestamps` from launcher (live) or `ChatMessage.createdAt` (persisted).
  5. **`ChatTranscriptView`** — `timestamps` param, `hideToolCalls` mirror filter.
  6. **`ChatWebView`** — threads timestamps through rendering; `formatDuration`/`formatTimestamp`/`workDuration`; footer HTML + CSS hover-swap.

- **Build:** `swift build` clean. **Tests:** all 2385 pass (fast tier).

## Verification

Historical verification remains in the progress record above.
