---
timestamp: 2026-07-21T143927Z
title: "#759 — chat-queue rendering + auto-send fix"
branch: null
status: historical
timestamp_source: git-commit
---

# #759 — chat-queue rendering + auto-send fix

## Progress


**Regression of #740 (PR #751):** the feature shipped but two things were
broken. `Sources/WikiFS/Chats/ChatView.swift` only.

**LAYOUT** — the queued-message list rendered BELOW the composer (it was
placed after `composer(enabled:)` in the `chatComposer` VStack). Moved it
ABOVE the composer so stacked "up next" items read as a playlist feeding
into the input (macos-design: muted, above the affordance they feed).

**AUTO-SEND** — the turn-completion observer was wired to
`.onChange(of: launcher.isRunning)`, but an interactive session keeps
`isRunning == true` across turns (the claude process stays alive). The real
per-turn "done, ready for next input" signal is `launcher.isGenerating`
going false (set in `setGenerating(false)` at the `endsGeneration` event, or
in `finish()` on process death). Added `.onChange(of: launcher.isGenerating)`
that fires the first queued message one-per-turn via the same `submitMessage`
path a manual Send uses. The original `isRunning` observer stays as the
session-end-between-turns fallback; both are safe to co-fire because
`firePendingQueuedMessage` drains exactly one item and then the queue is
empty (the second observer's guard no-ops). #740 multi-queue was already an
array (`[PendingQueuedMessage]`) with `removeFirst()` playlist semantics —
no change needed there.

**EDIT affordance** — added a per-row pencil button that pulls a specific
queued message back into the composer draft for editing (removes it from its
slot; remaining items shift down). Guarded by `.disabled(hasDraftText)` so a
half-typed draft is never overwritten (write rules: never lose the user's
in-flight text). The user re-queues the edited text via Send/Queue as normal.
Cancel (✕) already existed.

**No bare `try?`** in the queue/fire path — `submitMessage` uses
`sendInteractiveMessage` (sync void) or spawns `Task { await ... }` for the
async `continueChat`/`startChat` paths, which log via `DebugLog` internally.
No `print`. DebugLog only.

**Result:** `swift build` clean. 270 suites / 3257 tests pass.

**Build:** `swift build && swift test`.

## Verification

Historical verification remains in the progress record above.
