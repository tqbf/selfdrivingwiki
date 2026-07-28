---
timestamp: 2026-07-21T010327Z
title: "2026-07-20 — Queue a chat message while the agent is working (branch `chat-queue`, PR #751)"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-07-20 — Queue a chat message while the agent is working (branch `chat-queue`, PR #751)

## Progress


**Problem.** While the agent was generating a chat turn, the composer was
fully disabled (`canType` / `isComposerEnabled` returned `false` during
`launcher.isRunning`), the Send button was hidden behind the stop button, and
`sendButtonTitle` literally told the user to "wait for the response." You
couldn't even draft the next message, let alone queue one. See
`plans/chat-queue.md`. Closes #740.

**Fix.** Two tiers in `Sources/WikiFS/Chats/ChatView.swift` only:

- **Minimum (typing during generation):** `canType` and `isComposerEnabled`
  now return `true` during generation (live chat + draft state) so the
  composer stays editable while the agent responds. Sending is still gated by
  `canSendPredicate`'s `!isGenerating`, so this only enables *drafting* — it
  never fires mid-turn (the existing #380 guard in `sendMessage` is untouched).
- **Full (queue-on-send):** new `@State pendingMessage: PendingQueuedMessage?`
  (value type: `wireMessage` + `preview`), separate from the D3
  generation-gate queue (`isAwaitingGenerationSlot`, which gates *another*
  chat's send) — this is the *same* chat's "type the next message now" path.
  - `queueMessage()` stashes the draft (+ attachment refs via the extracted
    `buildWireMessage`) and clears the draft/attachments so the user can
    draft a *different* follow-up while the queued one waits.
  - A `queueButton` (sibling of the stop button: filled circle + up-arrow,
    accent/blue) appears during a running query turn when there's a draft and
    nothing is queued; it inherits ⌘↩ (the normal Send button is hidden during
    generation, so no shortcut conflict).
  - On turn completion, the existing `.onChange(of: launcher.isRunning)`
    observer calls `firePendingQueuedMessage()`, which routes through the
    extracted `submitMessage(_:)` (shared with `sendMessage`) — same dispatch
    as a manual send, only the *timing* differs. Crucially it does **not**
    touch the composer draft, so a half-typed follow-up is preserved (#740
    guardrail: only explicitly-queued-via-Queue messages auto-fire).
  - A muted "Queued: …" affordance (clock glyph, truncated preview, ✕) under
    the composer offers cancel before it fires; animated `.snappy`.

**Concurrency:** no new background task — the observer fires on the main
actor (`ChatView` is `@MainActor`); the queue delivers via the existing send
path. Consulted `docs/skills/macos-design/SKILL.md` for the unobtrusive
affordance (muted, `.secondary`, capsule). No bare `try?`; no `print`.

**Tests.** No test changes — `canSendPredicate` / `composerCaptionText`
static tests are unchanged (both still assert send is gated by
`!isGenerating`). `make build` clean; `make test` → 270 suites / 3253 tests
pass. Functional/GUI validation (type-during-generation, queue affordance,
auto-fire, cancel) requires a live agent-generation turn and is left for the
reviewer to confirm in `make run`. **Not merged to `main`.**

## Verification

Historical verification remains in the progress record above.
