# Daemon Phase C — Move Chat / ACP to the `wikid` Daemon

> **Status:** Design plan (implementation-ready).  
> **Builds on:** Phase 0 (#831), Phase A+B (#857, MERGED), #830/#849, #826/#851, #825/#853, #850, #838.  
> **Umbrella issue:** #5 ("move chat onto ACP session lifecycle completely"). Phase C IS #5.  
> **Goal:** After Phase C, the daemon owns interactive chat sessions end-to-end and can run
> headless. The app (`ChatDetailView`), `wikictl`, and a future MCP adapter are thin clients.

## §11 Plan-Review Corrections (AUTHORITATIVE)

See the full plan in the PR description. Key corrections:
- **RC1:** sendChatMessage detects dead session, re-routes to continueChat.
- **RC2:** Use `GRDBWikiStore.getSystemPrompt()` — NOT defaultBody.
- **RC3:** Single shared GenerationGate across all chat launchers.
- **RC4:** continueTakeoverDecision — only .refused retained; .betweenTurns/.idle proceed.
- **RC5:** summarizePendingMessages refactor is explicit C2 task.
- **RC6:** AC.4a automated XPC round-trip; AC.4b manual wikictl chat.
