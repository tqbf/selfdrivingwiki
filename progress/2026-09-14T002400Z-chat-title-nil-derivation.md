---
timestamp: 2026-09-14T002400Z
title: chat title derivation returns nil on failure (#1265)
branch: bugfix/chat-title-nil-on-derivation-failure
status: complete
---

# chat title derivation returns nil on failure (#1265)

## Progress

`ChatSummary.title(fromFirstMessage:)` returned the literal `"New Chat"` when
the first message yielded no usable title (whitespace-only, warning-only, or
preamble-only input). `setChatTitleIfEmpty` persisted that sentinel as a real
title. Two later automatic title writes then missed forever:

- `applyProvisionalChatTitle` writes only when the stored title is empty.
- The daemon Model-mode title upgrade treats any other non-empty title as a
  manual rename.

A chat whose first message was only the skills-budget warning kept the name
`"New Chat"`, and on screen it looked exactly like a genuinely untitled chat.
This was follow-up F4 from the 2026-09-12 chat-list-date-title pass, and the
sentinel-string rule in `AGENTS.md` named the smell.

The fix makes the derivation honest about failure:

- `title(fromFirstMessage:)` returns `String?`. It gives `nil` when nothing
  usable remains after the preamble strip and the attachment-ref strip.
- The `DaemonChatHost` provisional path and `WikiStoreModel
  .applyProvisionalChatTitle` skip the title write on `nil`. The row stays
  empty, and the next send retries the title.
- The `DaemonChatHost` create path and `WikiStoreModel.startChat` create the
  row untitled on `nil`.
- `refreshChatTitle` handles the optional provisional: with no provisional,
  only empty rows get the Model-mode write (`setChatTitleIfEmpty`). The
  `setChatTitleIf` rename guard still needs a provisional text to compare.
- The v54 migration rewrites an unrecoverable warning-only title to `""`,
  not `"New Chat"`. Migrated rows render through the display fallback and
  stay retriable.
- `ChatsCellView.rowTitle` keeps the `"New Chat"` display fallback. It is now
  the only source of that string, so `"New Chat"` on screen always means
  "no title yet".

Seams:

- `Sources/WikiFSCore/Core/ChatModels.swift` — the derivation.
- `Sources/wikid/DaemonChatHost.swift` — provisional path, create path,
  `refreshChatTitle`.
- `Sources/WikiFSCore/Store/WikiStoreModel.swift` —
  `applyProvisionalChatTitle`, `startChat`.
- `Sources/WikiFSCore/Store/GRDBWikiStore.swift` — the v54 migration title
  rewrite (step 3b).
- `Sources/WikiFS/Chats/ChatsListView.swift` — `rowTitle` doc comment only.

## Verification

- `make build` and `make test` pass (4378 tests in 469 suites).
- `ChatTitleTests` now expects `nil` for whitespace-only, empty, and
  warning-only messages.
- New `NewChatSidebarProjectionTests.derivationFailureLeavesRowUntitledAndRetriable`
  pins the no-write plus retriability contract.
- `SchemaMigrationLadderTests` asserts `chat-d` (warning-only title, no
  recoverable question) migrates to an empty title.
