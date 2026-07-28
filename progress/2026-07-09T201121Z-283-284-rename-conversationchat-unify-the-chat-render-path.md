---
timestamp: 2026-07-09T201121Z
title: "2026-07-09 — #283/#284: rename conversation→chat, unify the chat render path"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-07-09 — #283/#284: rename conversation→chat, unify the chat render path

## Progress


The chat surface's naming now matches the canonical "chat" term from the data
model (`chats` table, `ChatSummary`, `[[chat:…]]`, `chats/` projection). Three
commits on `refactor/283-conversation-to-chat`; no feature removal, no
schema/data migration.

**#284 — single prompt body for Ask + Edit.** Deleted
`prompts/query-conversation-readonly.md` (and its promptgen entry); both the
read-only (Ask) and read-write (Edit) chat variants now source `chat.md`
(`GeneratedPrompts.chat`), differing only by the operational write-rule block
(`IngestWriteRule.writes`), which the read-only arm omits. The seatbelt sandbox
+ `--allowed-tools` remain the authoritative write gate. New
`chatBothModesShareChatBodyReadOnlyOmitsWriteRule` test pins it; `make
check-prompts` green.

**#283 — rename sweep.** Whole-identifier, case-sensitive rename across
Sources/Tests/tools: `ConversationView`→`ChatView`,
`QueryTranscriptView`→`ChatTranscriptView`,
`AgentTranscriptSidebar`→`AgentActivitySidebar`, `queryConversation`→`queryChat`
(enum case + `queryChatPrompt`/`queryChatAllowsEdits`; the read-write helper
folded into one body), `startNewConversation`→`startNewChat`, etc. Four files
git-mv'd to match. UI strings updated (Conversation→Chat). Scoped comment cleanup
on chat-surface files only — "conversational" in `SQLiteWikiStore` and the
podcast-transcript plumbing (`TTMLTranscript`, `PodcastTranscript*`,
`AgentLauncher` persistence internals) are untouched.

**@AppStorage key migration.** `conversation.zoom`→`chat.zoom` via a pure,
injectable `AppStorageMigration.migrateZoomKey(from:to:in:)` in WikiFSCore
(`public`, idempotent: copies only when the new key is unset and the old key is
set — no-op for fresh installs), called from `WikiFSApp.init()` with `.standard`.
Covered by `AppStorageMigrationTests`.

**Render-path unification.** `ChatTranscriptView` generalized to take
`events:[AgentEvent]` + parameterized `emptyStateMessage`/`isRunning` (no longer
binds a launcher). `ChatView` now renders one `ChatTranscriptView(events:
displayMessages, …)` from a single call site, where `displayMessages` is a pure
static selector `(isLiveChat ? launcher.events : persistedEvents).transcriptVisible`.
One composer is placed once as a VStack sibling (the live placement), replacing
the persisted-only `.safeAreaInset` footer; the "another chat is responding"
caption is retained. Removed the dead `liveChat`/`persistedChat`/
`persistedTranscript`/`persistedComposerFooter`/`liveComposer`/`hasVisibleChat`.
New `ChatDisplayMessagesTests` cover source selection + the transcriptVisible filter.

**Deferred** to the #286/#287 mode-rework PR (operator-confirmed): removing
`.ask`/`.edit` (read-only Ask mode) — it's persisted (`WikiSelection.ask`,
`EditorTab`, `ChatKind` decoded from the DB `kind` column) and threaded through
~15 files; its removal is a kind/tab migration, not cleanup.

Gate evidence: `swift build` clean; full `swift test` green locally (2057 tests /
165 suites); `make check-prompts` green.

## Verification

Historical verification remains in the progress record above.
