# Silent ACP chat failure — plan (#613)

## Summary
When the SSW app's Ask/Edit chat cannot start an agent (no model configured,
agent binary missing, or `backend.start` throws), the chat tab shows
**nothing**. The error is captured in `AgentLauncher.preflightError` but that
field is rendered **only** in `AgentQueueView` (the ingest activity window) —
never in `ChatView` (the Ask/Edit chat surface). The chat is silently rolled
back to the empty draft composer.

**GitHub issue:** #613 — https://github.com/tqbf/selfdrivingwiki/issues/613

## Failure scenarios the fix must cover

### Scenario A — no model selected
- `SpawnModelGuard.validate` (`Sources/WikiFSEngine/SpawnModelGuard.swift:22`)
  fires in `AgentLauncher.startInteractiveQuery` (line 2123) setting
  `preflightError` and returning early.
- `AgentOperationRunner.startChat` (line 114) detects the non-nil
  `preflightError`, rolls back the freshly-created chat row
  (`rollbackChatCreation`), and reverts the tab to the draft composer.
- The user's typed message was pre-displayed but is cleared; the chat tab
  returns to the empty composer with **no error message**.

### Scenario B — backend.start throws (process launch / init / auth / exit failure)
- `ACPBackend.startProcess` can throw `noAgentConfigured` (line 308),
  `authenticationFailed` (line 366), or the `client.launch`/
  `client.initialize` call can throw (opencode exits, pipe broken, etc.).
- `startInteractiveQuery`'s `catch` (line 2292) sets
  `preflightError = "Failed to launch claude: …"` and returns.
- Same rollback path as Scenario A — chat silently reverts to draft.

## Root cause (file:line)
`AgentLauncher.preflightError` is set in:
- `Sources/WikiFSEngine/AgentLauncher.swift:2124` (SpawnModelGuard)
- `Sources/WikiFSEngine/AgentLauncher.swift:2294` (backend.start catch)
- `Sources/WikiFSEngine/AgentOperationRunner.swift:55` (ingest-blocked)

But it is rendered ONLY in:
- `Sources/WikiFS/Queue/AgentQueueView.swift:28` (`preflightBanner(error)`)

It is referenced NOWHERE in the chat UI:
- `Sources/WikiFS/Chats/ChatView.swift` (0 hits)
- `Sources/WikiFS/Chats/ChatWebView.swift` (0 hits)
- `Sources/WikiFS/Chats/ChatTranscriptView.swift` (0 hits)

So the chat panel's `content` view (`ChatView.swift:305`) renders one of three
branches — `AgentQueueView` (only when `showsInternals + isRunning + query`),
`ContentUnavailableView` (missing chat), or `chatSurface` — none of which surface
`preflightError`.

## Recommended fix — surface `preflightError` in ChatView

The error is ALREADY captured at the right choke-point
(`startInteractiveQuery` / `backend.start` catch). The gap is purely UI:
`ChatView` never reads `preflightError`.

### Implementation
1. Add a preflight-error banner to `ChatView`'s `content` / `chatSurface` branch,
   mirroring `AgentQueueView.preflightBanner(error)` (`Sources/WikiFS/Queue/AgentQueueView.swift:28`).
2. Show the banner when `launcher.preflightError != nil` AND the chat is in the
   draft / pre-send state (`isLiveChat == false || chatID == nil`).
3. Keep the existing rollback (don't leave a dead chat row) — but show the
   message in the draft composer state so the user knows WHY it reverted.
4. Reuse the existing visual pattern for failure banners:
   `.turnFailed → turnFailedBannerHTML` at `ChatWebView.swift:625`.
   Match that styling so the chat preflight banner looks consistent with
   the chat turn-failed banner.

### Files to modify
- `Sources/WikiFS/Chats/ChatView.swift` — add the banner read of
  `launcher.preflightError` + a `@ViewBuilder` preflight banner view.
- Possibly `Sources/WikiFS/Chats/ChatWebView.swift` — if the banner needs to
  route through the web view (the `turnFailedBannerHTML` pattern), add a
  `preflightBannerHTML` sibling. Otherwise a native SwiftUI banner overlay on
  `chatSurface` is fine — pick whichever is cleaner and matches the existing
  turn-failed visual.

### Files to READ (do not modify unless the banner demands it)
- `Sources/WikiFS/Queue/AgentQueueView.swift` — the existing `preflightBanner`
  you're mirroring. Read its styling, its conditions, and how it reads
  `preflightError`.
- `Sources/WikiFSEngine/AgentOperationRunner.swift:40-119` — the `startChat`
  flow + rollback. Understand where `preflightError` gets set, then where the
  rollback happens. Don't change the rollback; just surface the message.
- `Sources/WikiFSEngine/AgentLauncher.swift:2059-2310` — `startInteractiveQuery`
  + the two `preflightError` set sites. DON'T modify these — the capture is
  correct; the fix is at the rendering.

## Acceptance criteria (the PR must satisfy these)
1. When `launcher.preflightError != nil`, the chat tab shows the error message
   in a banner — NOT an empty draft composer.
2. When `launcher.preflightError == nil`, the chat tab renders normally (no
   banner) — zero behavioral change for the success path.
3. The rollback behavior is preserved (the dead chat row still gets rolled
   back) — the banner just explains why the draft is visible.
4. The banner styling matches the existing `turnFailedBannerHTML` visual.
5. New Swift Testing tests cover: preflightError set → banner shown;
   preflightError nil → no banner; banner text matches preflightError content;
   rollback still happens.
6. Both Swift CI jobs (`swift` fast tier + `swift-integration`) pass.
7. Does NOT touch `ACPBackend.swift`, `ACPPermissions.swift`, or
   `AgentLauncher.swift` — parallel-safe with #606+#607 (zero file overlap).

## Cross-cutting concerns
- This change is purely additive UI rendering. No SQLite changes, no
  concurrency / Sendable / AsyncStream changes, no main-actor isolation changes.
- The `preflightError` field is already `@MainActor`-isolated (it lives on the
  main-actor model); reading it in `ChatView` (also `@MainActor`) needs no
  hopping.
- No new `DebugLog` channels needed — the failure is already captured; the fix
  surfaces it visually. (You may add a `DebugLog.agent` line when the banner
  fires if you want, but it's optional.)

## NOT in scope
- `ACPBackend.send` empty-turn detection (defense-in-depth for a different
  class of agent — not the reported symptom; opencode doesn't produce empty
  turns).
- Process-exit early-detection — already partially covered by the existing
  `backend.start` catch (Scenario B) and the completion watchdog.
- nudging users off free models (#612 — different layer, documentation).
- the #606+#607 ACPBackend permission timeout / policy split work — that's its
  own PR (`feature/acp-permissions`); this fix has zero file overlap.

## House rules
- Feature branch `feature/preflight-error-chat` only. Never commit/push/merge
  to `main`.
- Never use bare `try?` to swallow errors — `do { try … } catch { DebugLog.store(…) }`.
- Never use `print` for diagnostics — `DebugLog` (subsystem
  `com.selfdrivingwiki.debug`).
- Prefer Swift Testing over XCTest for new tests. Follow
  `docs/skills/swift-testing-pro/SKILL.md`.
- Read `CLAUDE.md` and `SWIFTUI-RULES.md`. Use `macos-design` +
  `typography-designer` skills for the banner visual — match existing
  turn-failed banner styling (`turnFailedBannerHTML`).
- Never commit or push directly to `main`. Always work on a feature branch,
  push the branch, and open a PR. You may push PR branches but MUST NOT merge
  them to `main` yourself.
