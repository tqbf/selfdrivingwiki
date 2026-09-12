---
timestamp: 2026-09-12T170000Z
title: Focus the composer when a new chat is created
branch: bugfix/new-chat-composer-focus
status: complete
---

# Focus the composer when a new chat is created

## Progress

Creating a chat ("Add Chat" button, omnibox new-chat, agent-tools ask) left
keyboard focus wherever it was; the user had to click into the composer before
typing. The autofocus that existed (`ComposerTextView.autoFocus`, wired in
`ChatDetailView` as `autoFocus: chatID == nil`) only covered the legacy
`.newChat` draft surface. Since #1223's successor, `beginNewChat()` persists a
durable row and opens `.chat(id)` — `chatID != nil`, so the draft autofocus
never fired for the chats users actually create.

The fix is a one-shot focus request, because every chat has its own view
identity (`.id(chatID)` in `WikiDetailView.chatSurface`): navigating away from
and back to a chat rebuilds the composer and re-runs `makeNSView`, so any
persistently-true flag would steal focus on every tab revisit.

- `WikiStoreModel.pendingComposerFocusChatID` (private(set),
  `@Observable`-tracked): set by `beginNewChat` after the store write
  succeeds, alongside `pendingChatQuestion`. A failed creation sets nothing.
- `WikiStoreModel.consumeComposerFocusRequest(for:)`: clears the marker only
  when it still points at the given chat; `nil` (the legacy draft) never
  consumes.
- `ComposerTextView.onAutoFocused`: fired from the existing `makeNSView`
  autofocus hop, only once the text view is inside a window and first-responder
  status was claimed (already-focused also counts — the goal is achieved). A
  composer not yet in a window leaves the request pending. The callback is
  captured by value in the `@Sendable` hop; the store write happens outside
  any SwiftUI update pass, so no state-during-view-update hazard.
- `ChatDetailView` passes `autoFocus: chatID == nil || chatID ==
  store.pendingComposerFocusChatID` and an `onAutoFocused` closure that
  consumes the request for its own chatID.

`startChat(kind:firstMessage:)` intentionally does not set the request: that
path sends a message immediately, so there is no composer interaction to
focus.

## Verification

- `make build` — clean.
- `swift test --filter NewChatSidebarProjectionTests` — 17 tests pass,
  including 4 new ones (request set on create; consumed once, by its own chat
  only; retargeted by a second create; failed create leaves nothing pending).
- `make test` — full suite, 4378 tests in 469 suites, all pass.

Not verified: keyboard focus in the running app (no UI automation in this
repo). The AppKit mechanism is the same one the legacy draft surface already
used; the store-side contract is pinned by the new tests.
