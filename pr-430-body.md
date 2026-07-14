## Summary

Fixes #430 — chat composer text was lost when switching tabs and back. Also closes the chat outline view on new chats by default (it should not be visible).

## Changes

### Composer draft persistence across tab switches (#430)

The composer text lived in `@State private var draftMessage` on `ChatView`, which is recreated when the tab view is torn down on switch-back — so unsent text was lost. The fix mirrors the existing page-draft stash/restore pattern (`EditorTab.pendingDraftTitle/Body` + `WikiStoreModel.draftTitle/draftBody`):

**`Sources/WikiFSCore/EditorTab.swift`**
- New `pendingChatDraft: String?` — stashes unsent composer text per-tab (like `pendingDraftTitle`/`pendingDraftBody` for pages).

**`Sources/WikiFSCore/WikiStoreModel.swift`**
- New `draftChatMessage: String` — the live chat composer buffer (single source of in-flight text, like `draftTitle`/`draftBody`/`draftSystemPrompt`).
- `setActiveTab(_:)` — stashes the outgoing chat tab's `draftChatMessage` into `pendingChatDraft` before switching.
- `loadDrafts(for:)` — restores the incoming tab's stashed `pendingChatDraft` (or clears it for non-chat tabs).
- New `clearActiveChatDraft()` — clears both the live buffer and the stash after a send (so sent text doesn't reappear on switch-back).
- `confirmCloseTab()` / `discardPendingDraft(tabID:)` — also clear `pendingChatDraft` (mirroring the page-draft clear).

**`Sources/WikiFS/ChatView.swift`**
- Replaced `@State private var draftMessage` with `$store.draftChatMessage` binding.
- `sendMessage()` — reads from `store.draftChatMessage`, calls `store.clearActiveChatDraft()` after extracting the message (instead of `draftMessage = ""`).
- `hasDraftText` / `canSend` — now read `store.draftChatMessage`.
- Omnibox pre-fill — writes to `store.draftChatMessage` instead of the local `@State`.

### Close outline view on new chats by default

- `@AppStorage("isChatOutlineExpanded")` → `@State private var chatOutlineExpanded = false`. The outline toggle was a persisted global — expanding it in one chat made it appear in every chat thereafter. Now each new chat view starts with the outline collapsed; the user can expand it within that view's lifetime.

## Test results

- `make check` — clean
- `swift test --filter 'EditorTabTests|ChatViewD2Tests'` — 68/68 pass
- Fast tier: 2331 tests in 195 suites, all pass
