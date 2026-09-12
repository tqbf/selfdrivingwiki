---
timestamp: 2026-09-12T180000Z
title: Chat list rows — summary-or-question title, created-date subtitle
branch: feature/chat-list-date-title
status: complete
---

# Chat list rows — summary-or-question title, created-date subtitle

## Progress

Several chats carried the persisted title "Warning: Skill descriptions were
shortened to fit the 2% skills context budget." The known agent preamble
(`AgentPresentationPreamble.knownWarningSentence`) reaches title derivation
inside the first user message text, so the warning — not the question — became
the chat title, while the transcript kept the real first message (verified via
`wikictl chat get`: the real first message sat behind a
warning-titled row).

Row design (operator-directed, refined once from date-only titles):

- **Title**: (SUPERSEDED — see Follow-up 3 and Follow-up 5 below) the summary-model summary when one exists (`chat.summary`,
  produced when the summarizer is configured and has run), otherwise the
  stored title — the user's question — with the known preamble warning
  stripped at display. A title that cleans to nothing (warning-only rows
  created before the fix) falls back to "New Chat".
- **Subtitle**: the creation date (abbreviated date, shortened time, user
  locale), replacing `summary ?? relative-updated`.

Root fix: `ChatSummary.title(fromFirstMessage:)` now strips the known
preamble (`AgentPresentationPreamble.visibleText(.completeOnly)`) before its
existing attachment-ref strip / first-line / elide logic. Every title writer
shares this seam: the daemon's provisional and createChat writes
(`DaemonChatHost`) and the app's `applyProvisionalChatTitle` / `startChat`.
Only the exact known warning family is removed — an unrelated "Warning:"
line stays content. Future chats derive their title from the real question;
pre-existing warning-titled rows keep their stored title (rename or delete to
clean those; the list now renders them as "New Chat" until then).

Seams: `ChatsCellView.rowTitle(for:)` / `rowSubtitle(for:)` (pure, tested
without AppKit hosting). Tab titles, the address bar, and `wikictl` still use
the stored title.

## Follow-up 2: right-sidebar outline (same day)

The chat detail's right-sidebar outline rendered blank. Diagnosed with
os_log instrumentation on the live app: the registration pipeline was healthy
(the trace showed `entries=1` registered for the reported chat), but the
sidebar renders the outline as a captured snapshot and only re-renders when a
NEW registration arrives. Session rehydration transiently empties
`displayProjectionInput` (daemon attaching, history not yet mirrored), the
sidebar froze that empty frame, and no later trigger ever re-rendered it.

Fix: ChatDetailView re-registers on `.onChange(of:
remoteSession.displayProjectionInput)` (Equatable), so the sidebar can never
freeze a stale frame across the rehydrate window — and outline entries track
live turn growth.

Rows made selectable: entry texts use `.textSelection(.enabled)`, the row
action is a tap gesture instead of a Button (a Button's press gesture swallows
the selection drag), and a context menu offers Copy Question / Copy Response
via the shared `MetadataActionRouter.systemClipboardCopy`. Accessibility
keeps button traits and a default action.

## Follow-up 3: sidebar row title mirrors the stored title (same day)

The row title initially preferred `chats.summary` (the summary-model output).
The operator corrected the contract: the sidebar must match the chat's main
title. `chats.title` already IS "the user's question, or a summary-model
title when the summarizer stage is configured" — so `rowTitle` is now the
stored title (preamble-stripped, "New Chat" fallback); `chats.summary` no
longer appears in the row.

## Follow-up 4: verification round for the outline fix (same day)

The instrumented builds traced the outline through registration (entries=1
for the reported chat), the sidebar host render (first render 2.3s after the
chat opened, during the rehydrate window), and the outline view body
(entries=0 at that render). After the re-registration fix, the operator
confirmed the outline renders, text is selectable, and row clicks still jump.
Diagnostic logging removed after verification; the throwaway repro harness
was never committed.

## Follow-up 5: `chats.summary` removed (schema v53, same day)

Operator decision: the chat-level one-line answer summary should not exist.
Removed end to end:

- Schema v52→v53 (`dropChatSummaryColumnsV53`): drops `chats.summary` +
  `chats.summary_at`; both fresh-schema CREATEs no longer define them.
  Per-message `chat_messages.summary*` columns are kept — they feed the
  outline's response text.
- `ChatSummary.summary`/`.summaryAt` removed from the model and every
  construction site; store SELECTs (`listChats`, `listAllChatsOrderedByID`,
  `getChat`, chat search) no longer read the columns.
- `updateChatSummary` removed from the `WikiStore` protocol, `GRDBWikiStore`,
  and `WikiStoreModel`; both summarizer hosts (daemon `DaemonChatHost` and
  app `AgentOperationRunner`) no longer mirror a message summary into the
  chat row. Per-message `updateMessageSummary` writes are unchanged.
- `MessageSummarizer.chatSummaryMessageID(in:)` removed (its only purpose was
  picking the mirror source).
- Sidebar row-diff snapshot no longer mixes the summary into its identity
  string.

Version asserts updated (52→53) across ChatStore/ChatTurnMetadata/PageVersion/
BookmarkNode/SourceVersionIDPersistence suites, and two stale entries removed
from the `ChatAPISignatures.txt` manifest. New migration coverage in
`SchemaV52MigrationTests` (fresh DB at 53; a hand-built v52 DB with the
columns migrates to 53 with both columns dropped).

## Follow-up 6: conceptual drift review remediation (same day)

A Paseo-hosted Claude Opus agent ran a read-only conceptual drift review of
the chat design (`tmp/chat-conceptual-drift-review.md`, 13 findings). In-scope
remediation implemented on this branch:

- **F7/F8** — `AGENTS.md` schema pointer corrected (`GRDBWikiStore.swift`,
  three-table split); `plans/chat-summary.md` chat-level row marked Removed
  (v53); superseded "Row design" bullet annotated; two test comments rewritten
  to the current contract.
- **F9** — dead `ChatDetailPresentation.chatInspectorAvailable`,
  `RemoteState.runStartedAt`, `RemoteState.exitStatus`, and the no-op
  `hasChatID`/`hasMount` parameters deleted (call sites in
  Issue235/ChatViewD2 suites updated).
- **F10** — row-diff snapshot keys on `id|title` only; `updatedAt` dropped (it
  forced a full table reload per message append for zero visible change).
- **F2** — all nine test files now reference
  `AgentPresentationPreamble.knownWarningSentence` instead of re-typing the
  vendor banner; near-miss canary added to `visibleText` (a reworded banner
  logs via `DebugLog.chatLive` instead of failing silently).
- **F5** — both app-side `applyProvisionalChatTitle` calls now pass the wire
  message, so the app and daemon title writers converge byte-for-byte instead
  of relying on `stripAttachmentRefs` inverting `buildWireMessage`.
- **F11/F12b** — schema-version asserts read `GRDBWikiStore.schemaVersion`
  where suites mean "current"; `SchemaV52MigrationTests` renamed to
  `SchemaMigrationLadderTests`; the v52→v53 migration test now seeds chat +
  message rows and asserts survival.

Filed as follow-up issues (v54-scale or own-PR): F1 sidebar registration
carries data, F4 `title(fromFirstMessage:)` returns `String?`, F6/F3-B
summary-column move + legacy backfill.

## Verification

- `WIKIFS_APP_TESTS=1 swift test --filter 'ChatsListRowDisplayTests|ChatTitleTests'`
  — 13 tests pass: summary-as-title, question fallback, warning-title cleanup
  fallback, created-date subtitle; derivation strips the preamble, falls back
  for warning-only messages, and preserves unrelated Warning lines.
- `make build` and `make test` pass (4381 tests in 469 suites).
