# Plan: Queue a chat message while the agent is working (#740)

## Goal
Let the user type and queue their next message while the agent is still generating the current turn, instead of disabling the composer and making them wait. Two tiers:
- **Minimum:** stop disabling the text field (`canType`) so the user can draft during generation.
- **Full:** Send during a running turn queues the message; it auto-delivers as the next turn's input when the current turn completes (not lost, not dropped).

## Current state
`Sources/WikiFS/Chats/ChatView.swift`:
- `canType` (~L1122) returns `false` whenever `launcher.isRunning` (and not interactive) → can't even type during generation.
- `canSendPredicate` (~L1144) requires `!isGenerating && !isAwaitingSlot` → Send disabled until current turn finishes.
- `sendButtonTitle` (~L1157) literally says "Wait for the response before sending the next message."
- `isComposerEnabled` (~L1090), `canSend`/`canSendPredicate` (~L1129-1155).
- `composerCaption` doc (~L1110-1113) mentions there's already a generation-gate queue for the "another chat is responding" case (D3) — `launcher.isGenerating` / `launcher.isAwaitingGenerationSlot`. That existing queue pattern may extend to "same chat, next message" queuing; READ it before designing.

## Fix design (read the code first to confirm names/state)
1. **Typing during generation (minimum):** Change `canType` so it returns `true` during generation (allow drafting). Keep it `false` only when the field genuinely can't accept input (e.g. no chat selected).
2. **Queueing on Send during generation (full):** When the user sends while `isGenerating`/`isAwaitingSlot`:
   - Stash the message in a `@State pendingMessage: String?` (or a small queue `[String]` if multi-queue is desired — start with single, one queued message).
   - Show a "Queued: <message>" affordance in the composer area (reuse the existing caption/status pattern; keep it unobtrusive — macos-design discipline: muted, `.secondary`, clear).
   - On turn-completion (observe `launcher.isRunning` going false / a published "turn ended" event), if `pendingMessage` is non-empty, auto-submit it as the next turn's input and clear `pendingMessage`.
   - Allow Cancel-edit of the queued message (user can clear `pendingMessage` before it fires).
3. **Button states:** `sendButtonTitle` during generation → "Queue" (or a send-with-queue icon) when a draft is present; during queue → "Queued ✓" or a cancel. `canSendPredicate` allows send during generation when there's text (it queues rather than sends immediately).

## Guardrails
- **Read the existing D3 generation-gate queue first** (`launcher.isAwaitingGenerationSlot`, `composerCaption`) — extend it rather than building a parallel queue. If the existing queue pattern doesn't fit "same chat, next message," add a small dedicated `pendingMessage` state with a comment explaining why it's separate.
- **Concurrency:** the turn-completion observation must be on the main actor (ChatView is `@MainActor`); the queue fires via the existing send path, not a new background task. Follow `swift-concurrency-pro` (no structured tasks for this — observe the published `isRunning`).
- **Do not drop the message** if the turn ends while the user is mid-edit — only auto-fire what was explicitly queued via Send; a half-typed draft stays as draft text.
- **No bare `try?`**; **no `print`** (DebugLog if any diagnostic).
- Consult `docs/skills/macos-design/SKILL.md` for the queued-message affordance so it feels native (badge/muted caption, not a modal).

## Files
- `Sources/WikiFS/Chats/ChatView.swift` — `canType`, `canSendPredicate`, `sendButtonTitle`; add `pendingMessage` state + turn-completion observer + queue affordance.

## Build/test / validation
`make build && make test`. Validate in the running app (`make run`): start a chat turn; while generating, type a message (text field is editable); press Send → message is queued (visible affordance); when the turn completes, the queued message auto-sends as the next turn; clear the queue before it fires (cancel). Push the branch, open a PR with `Closes #740`. **Do NOT merge to main.** Scratch in `tmp/` inside your own worktree.
