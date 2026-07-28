---
timestamp: 2026-07-25T181956Z
title: "fix: Stuck \"responding…\" badge — `isRunning` is not \"is answering\""
branch: null
status: historical
timestamp_source: git-commit
---

# fix: Stuck "responding…" badge — `isRunning` is not "is answering"

## Progress


**Goal:** the sidebar badge latched on and never cleared after a chat replied.

**Root cause:** the app misread a correct daemon signal. Six `os_log` seams
across the pipeline (daemon push → XPC route → coordinator set → sidebar body →
representable update → row reconfigure) showed every stage firing in ~0ms and in
the right order, which cleared the UI layer and pointed upstream. The trace:

```
10:42:41.116  1.daemon.push running=true gen=true
10:42:41.116  2.app.route   running=true gen=true
10:42:47.214  6.sidebar.reload live=[01KYD5YE…] reconfigured=5/5   ← badge ON, correct
10:43:05.616  1.daemon.push running=true gen=false                 ← turn ends, session warm
   …no further pushes: nothing changed, so the fingerprint didn't change.
```

For an **interactive** chat, `AgentLauncher.isRunning` means "the agent process
is alive ACROSS TURNS" (its own comment: "SPAWN COMMIT: process is alive.
isRunning = true (process alive across turns)"), so it stays true while the
session idles waiting for the next message. `isGenerating` is the per-turn flag,
and `AgentLauncher` states the contract outright: "Every UI spinner / Stop
affordance keys off this rather than the raw `isRunning`."

`ChatDaemonCoordinator` did `setChatRunning(chatID, running: update.isRunning ||
update.isGenerating)` — where the `isRunning` disjunct dominates — so the badge
keyed on *process liveness* rather than *answering*, pinning it on for the life
of the session. The `gen=false` push at 10:43:05 was the signal that should have
cleared it, OR'd away.

**What changed:** the badge keys off `isGenerating` alone, and the names no
longer invite the misreading — `runningChatIDs` → `generatingChatIDs`,
`isChatRunning` → `isChatGenerating`, `anyChatRunning` → `anyChatGenerating`,
and the session fallback `s.isRunning || s.isGenerating` → `s.isGenerating`.
Four existing tests failed, all four having encoded the bug (`isRunning: true,
isGenerating: false` expecting the badge on); they now assert the real contract,
plus two new regression tests replaying the exact log sequence.

**Behavior note:** `anyChatGenerating` also gates the ⌘Q confirmation, so
quitting with a warm-but-idle chat session no longer prompts. That reads correct
(daemon work deliberately survives app quit — see the comment directly below the
call site), but it is a change beyond the badge.

**Worth naming:** this is the `ChatRunState` FSM problem one layer up.
`isRunning` carries two meanings — "process alive" and "work in flight" — so no
mapping of `(isRunning, isGenerating, isAwaitingSlot)` can separate them, and the
FSM inherited the ambiguity: `.thinking` means both "processing before the first
token" and "idle between turns". Distinguishing them properly needs a new signal
from the daemon, not a better mapping.

## Verification

Historical verification remains in the progress record above.
