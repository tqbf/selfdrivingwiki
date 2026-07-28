---
timestamp: 2026-07-09T133753Z
title: "2026-07-09 — Chat File Provider projection + `[[chat:…]]` wikilinks"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-07-09 — Chat File Provider projection + `[[chat:…]]` wikilinks

## Progress


Chats (store v25 `chats` + `chat_messages`, shipped #119) now project to the
File Provider mount and are linkable from page/source bodies. Design of record:
`plans/chat-projection.md`.

**What shipped:**

### Part 1 — Core foundation (WikiFSCore)
- **`ResourceKind.chat`** added to the `ResourceKind` enum — the single
  declaration point the bus, the `changeToken` contributor registry, and the
  projection descriptor registry all reference.
- **`WikiFSContainerID`** — chat container IDs: `chats`, `chatsByID`,
  `chatsByName`, `indexChatsJSONL`, `chatByIDPrefix`, `chatByNamePrefix`.
- **`ChatTokenContributor`** — appends `chatCount:chatMessageCount` as the
  13th token fold (after bookmarks). A chat create/delete bumps the count;
  a message append bumps the message count. Both advance the token so the FP
  re-enumerates `chats/`.
- **Store emission routing** — all four chat mutators (`createChat`,
  `appendChatMessages`, `renameChat`, `deleteChat`) now route through
  `mutate()` and emit `ResourceChangeEvent(kind: .chat, …)`. Previously they
  used `lock.lock(); defer { lock.unlock() }` directly and emitted nothing —
  the File Provider signaler never heard about chat changes.
  `StoreEmissionExhaustivenessTests` updated (chat mutators in `emit` set).
- **Read methods** — `listAllChatsOrderedByID()` (ULID/creation order, for
  the projection) and `resolveChatByTitle(_:)` (case-insensitive, lowest
  ULID wins — for wikilink resolution).
- **`ChatTranscriptRenderer`** (new, pure) — renders `ChatSummary` +
  `[ChatMessage]` as a readable markdown transcript (title H1, metadata
  blockquote, `## Role` sections per event using `AgentEvent` case dispatch).

### Part 2 — File Provider projection (WikiFSFileProvider)
- **`chatsProjection`** `FlatResourceProjection` — mirrors `pagesProjection`/
  `sourcesProjection`. `by-id` + `by-name` views, each chat as one `.md` file.
  `chatFileNode` sizes from rendered transcript bytes; versioned by
  `updated_at` so any message append re-fetches.
- **Dispatch wiring** — `chatsProjection` added to `flatProjections`; the
  structural folder switch in `node(for:)` handles `chats`/`chatsByID`/
  `chatsByName`. Root enumeration, by-container children, working set, and
  content dispatch are all registry-driven (no per-kind switch arms).
- **`chats.jsonl`** index — `IndexGenerators.chatsJSONL(chats:)` + a
  `chatsJSONLIndex` `GeneratedIndex` descriptor under `indexes/`.
- **Manifest** — extended with `chat_count` + `chats_by_id`/`chat_index` paths.
- **`WIKI-STRUCTURE.md`** — `WikiTreeRenderer.render` now takes `chatCount`;
  the prompt template (`prompts/wiki-tree-render.md`) lists `chats/` in the
  layout. `make prompts` regenerated `GeneratedPrompts.swift`.
- **README bytes** — `chats/by-id/`, `chats/by-name/`, `indexes/chats.jsonl`
  added to the useful-paths list.
- **Token literal assertions** — all 22 hardcoded `changeToken()` assertions
  across `SQLiteWikiStoreTests`/`LogIndexTests`/`SystemPromptTests` updated
  (appended `:0:0` for the chat fold).

### Part 3 — Wikilinks (WikiFSCore + WikiFS)
- **`WikiLinkParser`** — `.chat` added to `LinkType`; `classify` peels `chat:`
  (after `source:`); `isEmptyPrefix` checks `chat:`; embed-skip extended
  (`![[chat:…]]` is invalid — embeds are source-only).
- **`WikiLinkMarkdown`** — `chatHost = "chat"` constant; `target`/`id`/
  `fragment`/`resolvedKind` accept the chat host; `markdownLink` routes
  `.chat` → `wiki://chat?title=…`.
- **`WikiLinkRoute`** — `.chat(title:id:)` case; `linkRoute(for:)` routes;
  `onWikiLinkHandler` navigates to the chat via `selectChat(byID/byTitle)`.
- **`WikiStoreModel`** — `selectChat(byID:)` / `selectChat(byTitle:)` /
  `chatID(forTitle:)`.
- **`WikiRenderContext`** — `chatTitles` set + `chatIDToName` map for
  ghost-link resolution and canonical-ULID display-name self-healing.
- **`WikiLinkRewriter`** — `canonicalize` handles `.chat` (promotes
  `[[chat:Title]]` → `[[chat:<ULID>|alias]]` at the `PageUpsert` seam).
- **`MarkdownHTMLRenderer`** — `visitLink` tooltip for `chat:` prefix.
- **Downstream switches** — `WikiLinkMenuNSItems`, `WikiLinkMenuBuilder`,
  `BookmarksOutlineView`, `SQLiteWikiStore.replaceLinks`/
  `resolveCanonicalLink` updated for `.chat` exhaustiveness.

**Gate:** `swift build` clean; `swift test` — 2030 tests in 162 suites pass.
`make check-prompts` green.

### Part 4 — Agent surface (wikictl + system prompt)
- **`wikictl chat list`** — lists all chats as TSV (`id`, title, kind,
  message_count) or `--json` (same `chats.jsonl` format as the mount index).
- **`wikictl chat get (--id X | --title T)`** — prints a chat's transcript as
  rendered markdown (via `ChatTranscriptRenderer` — the same bytes the File
  Provider projects at `chats/by-id/<ULID>.md`).
- **System prompt** — `prompts/system-prompt-default.md` documents
  `[[chat:Title]]` wikilink syntax: how to link, how to find titles
  (`wikictl chat list`), how to read transcripts (`wikictl chat get`), the
  canonical ULID form, and the no-embed constraint. Regenerated via
  `make prompts`.
- **FP signal list** — `chats`, `chatsByID`, `chatsByName` added to
  `FileProviderSpike.signalChange(forWikiID:)` so the #111 deletion-diff path
  proactively refreshes chat containers (not just the working set).

## Verification

Historical verification remains in the progress record above.
