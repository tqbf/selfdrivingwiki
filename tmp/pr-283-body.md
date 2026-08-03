## Chat-surface cleanup: rename `conversation`→`chat`, #284, render unification

Resolves #283, #284.

Aligns the chat surface's naming and structure with the canonical "chat" term
from the data model (`chats` table, `ChatSummary`, `[[chat:…]]`, `chats/`
projection). Naming + one prompt deletion + one structural refactor — **no
feature removal, no schema/data migration, no security-surface change.**

### What shipped (3 logical commits + docs)

**#284 — single prompt body for Ask + Edit.** Deleted
`prompts/query-conversation-readonly.md`. Both the read-only (Ask) and read-write
(Edit) chat variants now source `chat.md` (`GeneratedPrompts.chat`), differing
only by the operational write-rule block (`IngestWriteRule.writes`), which the
read-only arm omits. The seatbelt sandbox + `--allowed-tools` remain the
authoritative write gate for Ask. Pinned by a new prompt-content test;
`make check-prompts` is green.

**#283 — rename sweep.** Whole-identifier, case-sensitive rename across
Sources/Tests/tools (`ConversationView`→`ChatView`,
`QueryTranscriptView`→`ChatTranscriptView`,
`AgentTranscriptSidebar`→`AgentActivitySidebar`, `queryConversation`→`queryChat`,
`startNewConversation`→`startNewChat`, …). Four files `git mv`'d to match. User-facing
UI strings updated (Conversation→Chat). Scoped comment cleanup on chat-surface
files only — "conversational" in `SQLiteWikiStore` and the podcast-transcript
plumbing (`TTMLTranscript`, `PodcastTranscript*`, `AgentLauncher` persistence
internals) are deliberately untouched.

`@AppStorage` key migration: `conversation.zoom`→`chat.zoom` via a pure,
injectable, `public` `AppStorageMigration.migrateZoomKey(from:to:in:)` in
WikiFSCore, called from `WikiFSApp.init()` with `.standard`. Idempotent (copies
only when the new key is unset and the old key is set — no-op for fresh
installs). Covered by `AppStorageMigrationTests`.

**Render-path unification.** `ChatTranscriptView` generalized to take
`events:[AgentEvent]` + parameterized `emptyStateMessage`/`isRunning` (no longer
binds a launcher). `ChatView` now renders one `ChatTranscriptView(events:
displayMessages, …)` from a single call site, where `displayMessages` is a pure
static selector `(isLiveChat ? launcher.events : persistedEvents).transcriptVisible`
(unit-tested without a view-tree harness). One composer is placed once as a
VStack sibling (the live placement), replacing the persisted-only
`.safeAreaInset` footer; the persisted "another chat is responding" caption is
retained. Removed the dead `liveChat`/`persistedChat`/`persistedTranscript`/
`persistedComposerFooter`/`liveComposer`/`hasVisibleChat`.

### Deferred (operator-confirmed)

Removing `.ask`/`.edit` (read-only Ask mode), the accept-edits review gate
(#287), and the yolo toggle (#286) are deferred to the #286/#287 mode-rework PR.
`.ask`/`.edit` is persisted (`WikiSelection.ask`, `EditorTab`, `ChatKind`
decoded from the DB `kind` column) and threaded through ~15 files; removing it
cleanly needs a `kind`/tab migration and is mode-rework, not cleanup. This PR
keeps `.ask`/`.edit` intact — only the standalone read-only *prompt* is deleted
per #284.

### Gate evidence

- `swift build` clean
- full `swift test` green locally — **2057 tests / 165 suites**
- `make check-prompts` green (no codegen drift)
- Implementation review (`general-purpose` subagent): **0 CRITICAL, 0 MEDIUM**;
  2 LOW (both intentional per plan: the UI string renames and the deliberate
  persisted-composer placement change)

### One intentional minor change

The persisted chat's composer moves from `.safeAreaInset(edge:.bottom)` to an
in-flow VStack sibling below the transcript (matching the live path). Behavior is
otherwise preserved: editing banner, `startNewChat` clearing `activeChatID`,
send branching, the D2 source-of-truth flip, and the distinct live
"Waiting for the Agent…" vs persisted "No messages were persisted…" empty states.
