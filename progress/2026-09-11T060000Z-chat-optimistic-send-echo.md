---
timestamp: 2026-09-11T060000Z
title: Chat sends show an immediate local echo
branch: bugfix/chat-optimistic-echo
status: complete
---

# Chat sends show an immediate local echo

## Progress

Pressing return in the chat composer waited for the full XPC submit reply
before anything appeared. For a draft (new chat) the reply comes only after
daemon agent bootstrap (spawn, ACP initialize, session/new), so the message
took seconds to show. For an existing chat the reducer dropped the optimistic
submission whenever the session projection was still nil, so a send issued
before rehydrate showed nothing. Both gaps are app-side.

Sends now append a view-local `PendingOutgoingMessage` synchronously, before
any await. `ChatDetailPresentation.make` projects the echo rows in both
transcript branches. The live branch re-projects from a new
`RemoteChatSession.displayProjectionInput` snapshot (merged items plus the
validated active content block), which replaces the old pre-projected
transcript path. Echo rows retire by `ChatTurnID`: the presentation filters
echoes whose turn appears in `RemoteChatSession.knownTurnIDs` or the persisted
transcript, so the authoritative row replaces the echo at handoff. The
reducer's `optimisticSubmit` still runs for existing chats; its lifecycle side
effects stay load-bearing and the turnID filter hides the duplicate.

A failed send keeps its message visible. The echo status machine moves to
`failed(message:)` and the projection emits one user row plus a typed
`.turnFailure` row with category `.transportError`, the same vocabulary failed
agent turns use, so `ChatWebView` needed no production change. The controller
restores the composer only from an atomic snapshot (trimmed text plus
attachment IDs) and only when the composer is untouched, so a failure never
overwrites content the user added while the send was in flight. Failed rows
stay until the view remounts. Retry is edit-and-resend.

Queued sends carry the same payload and restore rule. `PendingQueuedMessage`
gains `draftText` and `attachments`, and three pure functions
(`makePendingQueuedMessage`, `outgoingPayload(from:)`,
`restoreQueuedMessage`) pin the queue transforms. `ChatOutgoingMessagesController`
owns the send lifecycle with all effects injected as closures, which keeps the
lifecycle testable without a daemon. While a draft submit is in flight,
`canSend` is false and the caption reads "Starting chat..."; persisted chats
are never blocked by this guard.

Follow-ups recorded on the issue: reply to `submitChatTurn` before bootstrap,
tap-to-retry on failed rows, and the pre-existing web-view remount flash on
retarget.

## Verification

- `make build` passed.
- `make test` passed (4289 tests, 465 suites, includes
  `ChatClientSyncReducerTests`).
- `WIKIFS_APP_TESTS=1 swift test --filter 'ChatOutgoingMessagesControllerTests|ChatDetailPresentationTests|ChatTranscriptHostedTests|ChatPresentationAPIManifestTests|RemoteChatSessionTests|ChatViewD2Tests|ChatViewPreflightBannerTests|Issue235IngestExtractionLockTests|ChatDaemonCoordinatorTests'`
  passed (118 tests). `ChatPresentationAPIManifestTests` confirms no
  event-array contracts returned.
- `ChatViewD2Tests/persistedChatResolvesByIDWhenSummaryCacheIsStale` flakes
  with time-of-day fractional seconds in a `ChatSummary` store round trip.
  It fails on `main` the same way at the same times. Unrelated to this
  branch.
- Manual checks remain for the full view: run the app, send in a new chat
  (bubble appears while bootstrap runs), stop the daemon and send (failed row
  plus banner, composer holds text and attachments), queue during a live
  answer and let it fire.
