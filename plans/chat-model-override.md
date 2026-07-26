# Per-chat model override (chat composer picker)

## Why

The chat composer's model picker (`ProviderSelector`) had two resolution tiers:
a per-stage provider pin (`stageProviderIds["chat"]`, Settings → Chat tab) and
the global default provider. Clicking a row in the composer wrote the **global
default** (`RemoteChatSession.setSelectedModelAndDefault`), but the composer's
own displayed selection was computed from `provider(forStage: "chat")`, which
prefers the stage pin over the global default (Decision A,
`plans/agent-settings-tabs.md` §6.5). Net effect: if the chat stage was pinned,
clicking a different model in the composer silently wrote a new global default
that the checkmark never reflected — indistinguishable from the click doing
nothing.

The fix isn't just cosmetic — the user wants the composer to set the model
**for that specific chat**, outranking both the stage pin and the global
default. This is a third, higher-priority resolution tier, persisted per chat.

## Design

**Storage** — `ChatSummary` (`Sources/WikiFSCore/Core/ChatModels.swift`) gains
`modelProviderId: String?` / `modelId: String?`. Persisted as two new nullable
columns on the `chats` table (migration v44→v45,
`Sources/WikiFSCore/Store/GRDBWikiStore.swift`). `nil` = no override, falls
through to the existing stage-pin/global-default resolution unchanged.

**Resolution** — `AgentProvidersConfig.provider(forStage:)` and `.modelId(forStage:)`
(`Sources/WikiFSCore/Core/AgentProvidersConfig.swift`) each gain an optional
`chatOverrideProviderId`/`chatOverrideModelId` parameter (default `nil`, so
every non-chat call site — planner/executor/finalizer/lint — is unaffected).
When set + the provider is enabled, the override outranks the stage pin; a
disabled override provider falls through to the stage pin, same as a disabled
stage pin falls through to the global default. The model resolves *within*
the override (its own model id, else that provider's `selectedModelId`) — the
stage's separate model pin is bypassed once a provider override is active.

**Spawn** — `AgentLauncher.startInteractiveQuery` gains the same two
parameters, threaded from `DaemonChatHost`:
- `startChat` reads them from the client (new `ChatStartRequest.providerId`/
  `.modelId` fields) and seeds `ChatSummary` at creation time.
- `continueChat` reads them off the already-fetched `ChatSummary` row (same
  fetch that already reads `acpSessionId`).

**Client write path** — the client and daemon both hold direct SQLite
connections to the same App-Group `chats` table (confirmed via existing
`renameChat`/`deleteChat` direct-write precedent), so `ProviderSelector`
writes the override straight to the store
(`WikiStoreModel.updateChatModelOverride`, mirroring `updateChatAcpSessionId`)
for a persisted chat. A `.draft` chat (no row yet — `ChatSessionKey.draft`) has
nowhere to write to, so the pick is stashed on `RemoteChatSession.pendingModelOverride`
and threaded through `ChatDaemonCoordinator.startChat`'s new `providerId`/
`modelId` params when the first message creates the chat. No clearing logic is
needed: starting the chat discards the whole draft `RemoteChatSession` (a
fresh one is created for the new `PageID`, since `chatID` is a `let`).

`ProviderSelector` no longer calls `setSelectedModelAndDefault` at all — that
method (on `RemoteChatSession`) was deleted as dead code once this was its
only caller.

## Files touched

- `Sources/WikiFSCore/Core/ChatModels.swift` — `ChatSummary` fields.
- `Sources/WikiFSCore/Store/GRDBWikiStore.swift` — schema (both the migration
  ladder step and the fresh-schema block), `createChat` overload,
  `updateChatModelOverride` mutator (routes through `mutate()`, emits `.chat
  .updated`), `getChat`/`listChats`/`listAllChatsOrderedByID` column reads.
- `Sources/WikiFSCore/Store/WikiStore.swift` / `WikiStoreModel.swift` —
  protocol + client wrapper.
- `Sources/WikiFSCore/Core/AgentProvidersConfig.swift` — the resolution tier.
- `Sources/WikiFSEngine/AgentLauncher.swift` — spawn-time threading.
- `Sources/WikiFSEngine/ChatXPCRequests.swift` — `ChatStartRequest` fields.
- `Sources/wikid/DaemonChatHost.swift` / `WikiDaemon.swift` — daemon-side
  threading + XPC handler.
- `Sources/WikiFS/Chats/RemoteChatSession.swift` — `pendingModelOverride`.
- `Sources/WikiFS/Chats/ChatDaemonCoordinator.swift` — wire-through.
- `Sources/WikiFS/Chats/ChatDetailView.swift` — passes `store` into
  `ProviderSelector`, threads the pending override into the draft `startChat`
  call.
- `Sources/WikiFS/Settings/ProviderSelector.swift` — `chatModelOverride`,
  chat-scoped `current`/`selectedRowID`/`triggerLabel`/`selectRow`.

## Tests

- `AgentProvidersConfigPerStageModelTests` — override outranks stage pin
  outranks global default; disabled override falls back; empty override
  string behaves like nil; model resolves within the override.
- `ChatStoreTests` — fresh schema has the columns; `createChat` seeds the
  override; round-trip write/read/clear; `listChats` includes it; v44→v45
  migration adds the columns to a hand-built v44 DB with no backfill.
- `StoreEmissionTests` — `updateChatModelOverride` emits `.chat .updated`.
- Existing hardcoded `schemaVersion == 44` assertions
  (`PageVersionTests`, `SystemPromptTests`, `MessageSummaryTests`) updated to
  45 (or made version-relative where the exact number wasn't the point of the
  test).

## Verification

Manual: pin the "Chat" stage to a different provider in Settings, open a
chat, pick a different model in the composer — the checkmark/trigger updates
immediately (previously the checkmark stuck on the pinned provider even
though a write happened). Confirmed against a running app + its debug run
logs that the override correctly outranks the stage pin at spawn time
(`session-setModel-2.json`'s `ACPModelSelectionResolver` decision reflects the
override's resolved model, not the stage-pinned provider's).
