# Chat File Provider projection + `[[chat:…]]` wikilinks

**Status:** plan / design of record. Chats exist in the store (schema v25:
`chats` + `chat_messages`, shipped #119) and the UI (sidebar, `ConversationView`)
but project **nothing** to the File Provider mount and are **not linkable** from
page/source bodies. This doc covers both: a `chats/` tree in the mount and
`[[chat:Title]]` / `[[chat:<ULID>]]` wikilinks.

## Goal

1. **Projection** — chats appear as a flat `chats/` tree (by-id + by-name),
   each chat rendered as a readable `.md` transcript file. A `chats.jsonl`
   index, manifest count, and `WIKI-STRUCTURE.md` entry follow the established
   pattern (pages/sources/bookmarks).
2. **Wikilinks** — `[[chat:Title]]` parses, renders as a clickable
   `wiki://chat?title=…` link, resolves (ghost vs live), and navigates to the
   chat. Canonical ULID form (`[[chat:<ULID>|alias]]`) is supported.

## What exists today (grounded)

- **Chat storage** — `chats` (id, kind, title, created_at, updated_at) +
  `chat_messages` (id, chat_id, seq, role, event_json, text, created_at).
  Store methods: `createChat`, `appendChatMessages`, `listChats` (ordered by
  `updated_at DESC`), `chatMessages`, `renameChat`, `deleteChat`.
- **No emission** — chat mutators use `lock.lock(); defer { lock.unlock() }`
  directly; they do NOT route through `mutate()` and emit no
  `ResourceChangeEvent`. The File Provider signaler never hears about chat
  changes.
- **No change-token fold** — `ResourceKind` has no `.chat` case; the
  `tokenContributors` registry has no chat contributor. A chat create/delete/
  rename/append does NOT advance the token.
- **No projection** — `Projection.swift` has no chat Identity, no
  `chatsProjection`, no chat container IDs. The `flatProjections` array is
  `[pagesProjection, sourcesProjection]`.
- **No wikilink support** — `WikiLinkParser.ParsedLink.LinkType` is
  `{ page, source }`. `classify` peels `page:` and `source:` only.
  `WikiLinkMarkdown` emits `wiki://page` / `wiki://source` / `wiki://missing`.
  `WikiLinkRoute` has `.page` / `.source` / `.samePageAnchor` / `.inert`.
- **`ChatSummary`** already notes the ULID is "the stable resource identity
  every follow-up surface (`[[chat:…]]` links, `chats.jsonl`, the File Provider
  `chats/` tree) hangs off" — this is the planned realization.
- **`WikiSelection.chat(PageID)`** already exists — a persisted chat is
  a first-class selection (tabs, history, drag/drop).

## Design decisions

### D1 — Flat projection, not nested

Chats are flat (like pages/sources), not nested (like bookmarks). A
`FlatResourceProjection` with `by-id` + `by-name` views is the natural fit.
Each chat is one `.md` file; no subfolders.

### D2 — Transcript rendered as markdown

Each chat projects as a readable markdown file — not raw JSON. The
`AgentEvent.plainText` projection already exists; a `ChatTranscriptRenderer`
wraps it with role headers and metadata. This makes `cat chats/by-id/<ulid>.md`
useful for agents and humans browsing the mount.

### D3 — `chat:` prefix, parallel to `source:`

`[[chat:Title]]` follows the exact pattern of `[[source:Name]]`: a reserved
prefix peeled by `classify`, a `wiki://chat?title=…` URL, a `.chat` route case.
No embeds (`![[chat:…]]` is not valid — chats are not inline media).

### D4 — Canonical ULID form supported

Like pages (Phase 5) and sources, `[[chat:<ULID>|alias]]` resolves by id and
self-heals the display name at render time. The `WikiLinkRewriter.canonicalize`
path promotes resolvable `[[chat:Title]]` to `[[chat:<ULID>|alias]]` at the
`PageUpsert` seam — same as pages/sources.

### D5 — Token fold: chat count + message count

`ChatTokenContributor` appends `chatCount:chatMessageCount` to the token
(13th field, after bookmarks). A chat create/delete bumps the count; a message
append bumps the message count. Both advance the token so the FP re-enumerates.

### D6 — Store emission: route through `mutate()`

Every chat mutator (`createChat`, `appendChatMessages`, `renameChat`,
`deleteChat`) routes through `mutate()` and emits a `ResourceChangeEvent` with
`kind: .chat`. This satisfies the load-bearing invariant
(`StoreEmissionExhaustivenessTests`).

## Implementation

### Part 1 — Core foundation (WikiFSCore)

| File | Change |
| --- | --- |
| `Resource.swift` | Add `.chat` to `ResourceKind` |
| `WikiFSContainerID.swift` | `chats`, `chatsByID`, `chatsByName`, `chatByIDPrefix`, `chatByNamePrefix`, `indexChatsJSONL` |
| `SQLiteWikiStore.swift` | `ChatTokenContributor` + `chatCount()`/`chatMessageCount()` helpers; route chat mutators through `mutate()`; `listAllChatsOrderedByID()`; `resolveChatByTitle(_:)` |
| `WikiStore.swift` | Protocol: add `listAllChatsOrderedByID()`, `resolveChatByTitle(_:)` if not already present |
| `ChatTranscriptRenderer.swift` (new) | Pure: renders `ChatSummary` + `[ChatMessage]` → markdown string |

### Part 2 — File Provider projection (WikiFSFileProvider)

| File | Change |
| --- | --- |
| `Projection.swift` | `Identity.chats` / `chatsByID` / `chatsByName` + prefix helpers; `chatsProjection` `FlatResourceProjection`; `chatFileNode(for:chat:)` builder; wire into `flatProjections`; add `Identity.chats` to structural folder switch; update `readmeBytes` |
| `IndexGenerators.swift` | `chatsJSONL(chats:)` generator + path constant |
| `WikiTreeRenderer.swift` | Add `chats/` to the layout map + chat count |

### Part 3 — Wikilinks (WikiFSCore + WikiFS)

| File | Change |
| --- | --- |
| `WikiLinkParser.swift` | `LinkType.chat`; `classify` peels `chat:`; `isEmptyPrefix` checks `chat:` |
| `WikiLinkMarkdown.swift` | `"chat"` host in `target`/`resolvedKind`/`markdownLink`; chat link rendering |
| `WikiReaderView.swift` | `WikiLinkRoute.chat(title:id:)`; `linkRoute` routes `.chat`; `onWikiLinkHandler` navigates to chat |
| `MarkdownHTMLRenderer.swift` | `visitLink` tooltip for `chat:` prefix |
| `WikiStoreModel.swift` | `selectChat(byID:)`, `selectChat(byTitle:)` |
| `WikiRenderContext.swift` | Chat existence/display sets for ghost-link resolution |
| `WikiLinkRewriter.swift` | `canonicalize` handles `.chat` kind (promote title → ULID) |

### Part 4 — Tests

| Area | Tests |
| --- | --- |
| Token | `ChangeTokenContributorTests` — `.chat` contributes; update literal assertions |
| Emission | `StoreEmissionExhaustivenessTests` — chat mutators in `emit` set; `StoreEmissionTests` — chat events |
| Projection | `ProjectionTreeTests` — root children, by-id/by-name, file content, working set, empty folder |
| Wikilinks | `WikiLinkParserTests` — `[[chat:…]]` parses; `WikiLinkMarkdownTests` — renders `wiki://chat` |
| Renderer | `ChatTranscriptRendererTests` — pure rendering |
| Tree | `WikiTreeRendererTests` — chat count in layout |

## Phasing

1. **Core foundation** (Part 1) — must land first; projection + wikilinks
   depend on it.
2. **Projection + wikilinks** (Parts 2 + 3) — parallelizable after Part 1.
3. **Tests** (Part 4) — after Parts 1–3; but test-first for the pure pieces
   (renderer, parser) is fine within each part.

## Non-goals (deferred)

- `[[chat:…#"quote"]]` quote anchors into chat messages (the `chat_messages.text`
  column is the future FTS substrate, but quote-anchor matching is not built).
- Chat-to-chat links (`[[chat:A]]` inside a chat message body) — the transcript
  is rendered JSON, not authored markdown; linkification applies only to
  page/source bodies.
- `chats/by-name/` disambiguation for duplicate titles (same ULID-suffix
  escaping as pages — handled by `FilenameEscaping`).
