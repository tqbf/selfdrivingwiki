---
timestamp: 2026-07-25T181956Z
title: "refactor: ChatRunState as a real FSM; ChatSessionKey replaces the string chat id"
branch: null
status: historical
timestamp_source: git-commit
---

# refactor: ChatRunState as a real FSM; ChatSessionKey replaces the string chat id

## Progress


**Goal:** the stuck-badge bug was a symptom — `isRunning` vs `isGenerating` is
still a flag cluster, and the chat id was still a bare `String` with a sentinel
for the draft. Both are the modeling rules in AGENTS.md applied to the code that
motivated them.

**ChatRunState — what was wrong.** The first version was a *lossy* mapping,
which is how an FSM reintroduces the bug it was meant to prevent:

* `.thinking` was defined as `isRunning && !isGenerating`. `setGenerating(true)`
  fires at **turn start** (`sendInteractiveMessage: turn start`), not at first
  token — so `isGenerating` already covers the thinking phase, and
  `isRunning && !isGenerating` for an interactive chat *only ever* means "warm,
  between turns". The case was misnamed for its sole reachable input, and that
  misnomer is what taught the sidebar to badge a warm session as "responding…".
* `if isRunning` was tested **before** `isAwaitingSlot`. A turn queued on the
  generation gate has both flags set, so `.queued` was swallowed and reported as
  `.thinking` — `isAwaitingGenerationSlot` read false exactly when it was true.

**What changed:** cases are now `idle` / `queued` / `warm` / `answering`, with
precedence `answering → queued → warm → idle` (narrowest claim wins), and two
derived predicates that keep the two questions apart at the source: `isLive`
("render the streaming mirror, not the persisted rows") and `isAnswering`
("every spinner, badge, and Stop affordance"). All eight boolean combinations
are pinned by test rather than sampled, the two regressions above named
explicitly.

**Behavior changes (deliberate, both tested):**
1. `.queued` is now **live**. It previously reported `isRunning == false` /
   `activeChatID == nil`, which sent the chat surface to the persisted rows
   mid-conversation while a turn waited on the gate.
2. `ChatDetailView.transcriptIsRunning` keys off `isAnswering`, not `isRunning`.
   With the corrected shims `isRunning` means "session alive", so leaving it
   would have shown "Waiting for the Agent…" on a warm idle chat — trading one
   conflation for another.

**ChatSessionKey.** `RemoteChatSession.chatID` was a `String`, and the draft
composer was spelled `"__wiki_draft_chat__"` — a sentinel sharing a namespace
with real chat ULIDs, so "is this the draft?" was a comparison against a magic
constant every call site had to remember. It is now
`ChatSessionKey.draft` / `.chat(PageID)`; `activeChatID` is `PageID?`; the
coordinator's registry, generating-set, and public API all take `PageID`. The
`.draft` case carries no `PageID`, so a draft **cannot** satisfy the
`activeChatID == chatID` liveness rule even by accident — previously it could in
principle, since `activeChatID` returned the sentinel.

**The wire stays `String`.** `QueueEventEnvelope` and the XPC request DTOs are
unchanged; conversion happens at exactly two boundaries (`ChatDaemonCoordinator.route`,
`RemoteChatSession.ingest`). The compiler enforced that line repeatedly while
the tests were being migrated — every place the app-side type leaked onto the
wire failed to build.

## Verification

Historical verification remains in the progress record above.
