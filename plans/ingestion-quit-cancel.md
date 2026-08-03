# Fix #765: ingestion quit/cancel lifecycle bugs

## Problem
Two related lifecycle bugs:

1. **Quit dialog says 'will be cancelled' but the quit path never cancels in-flight items**, so restart re-queues them (crash recovery treats user-quit like a crash).
2. **Turn-ceiling cancellation (602s) orphans queue items in `.running`**.

## Decision: Option A (cancel on quit) — interim until background daemon (#754)
The operator chose cancel-on-quit. The long-term solution is a background daemon (#754) where the ingestion keeps running when the GUI app quits — but until that exists, canceling on quit is correct.

## Bug 1 fix: cancel in-flight items in the quit path
`Sources/WikiFS/Window/WikiFSApp.swift:729-749` — when the user clicks Quit in the alert callback (`response == .alertFirstButtonReturn`), BEFORE calling `NSApp.reply(toApplicationShouldTerminate: true)`, cancel running queue items:
- Call `queueEngine.halt(.ingestion)` and `queueEngine.halt(.extraction)` — these pause the queue + cancel all in-flight items (transition to `.cancelled`).
- This is ASYNC (halt is async) — await it before replying to terminate. Use a Task with a semaphore or restructure to await, OR if halt can't complete cleanly in the quit window, at minimum transition the running items to `.cancelled` via the store (store.cancelItem or a bulk cancel) so crash recovery on restart skips them.
- Verify: `resetRunningToQueued` (QueueEngine.swift:104-106) only touches `.running` items — a `.cancelled` item stays cancelled on restart. So cancel-before-quit makes crash recovery a no-op for user-initiated quits while genuine crashes still re-queue.
- The dialog text ('will be cancelled') is now honest.

## Bug 2 fix: propagate turn-ceiling cancellation to queue state
The ACP turn-ceiling (602s, in ACPBackend.swift) kills the agent turn but the queue item stays `.running`. Fix: ensure the turn-ceiling cancellation propagates through `QueueWorker` → `QueueEngine.handleWorkerFinished` (~L310-330) → terminal `.failed` event with the 'turn ceiling exceeded' reason.
- Read QueueWorker.swift to find where the worker observes completion/cancellation of its ACP session/task.
- Read ACPBackend.swift to find the turn-ceiling enforcement and how it signals cancellation.
- The worker's Task should observe the cancellation (via task.cancel() or the ACP error) and call `handleWorkerFinished` with a `.failure` result, which transitions the item to `.failed`.

## Guardrails
- Do NOT break crash recovery (`resetRunningToQueued` for genuine crashes must still work — only `.cancelled` items should skip it, and they already do).
- Do NOT add true resume / checkpointing — that's a future feature (daemon #754).
- No bare `try?` (use do/catch with DebugLog); no print (DebugLog only).
- Verify the quit path doesn't hang — if halt is async and the app needs to exit, there may be a timing issue. If halt can't complete, fall back to a synchronous store-level cancel of running items.

## First commit
Copy this plan into `plans/ingestion-quit-cancel.md` in the worktree, then implement.

## Build/test
Run `make build && make test`. Validate in `make run`: start an ingestion → quit while running (dialog says 'will be cancelled') → click Quit → restart → the job is GONE (cancelled, not re-queued). Push the branch, open a PR with 'Closes #765'. Do NOT merge to main. Scratch in `tmp/` in the worktree.
