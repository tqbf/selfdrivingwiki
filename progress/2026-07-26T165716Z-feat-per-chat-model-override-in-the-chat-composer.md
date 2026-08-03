---
timestamp: 2026-07-26T165716Z
title: "feat: per-chat model override in the chat composer"
branch: null
status: historical
timestamp_source: git-commit
---

# feat: per-chat model override in the chat composer

## Progress


**Why.** The composer's `ProviderSelector` had two resolution tiers — the
"chat" stage pin (Settings) and the global default provider — and clicking a
row always wrote the global default. If the chat stage was pinned, the
composer's own checkmark (computed from `provider(forStage: "chat")`, which
prefers the stage pin) never moved, so a click looked like it did nothing even
though it silently changed the global default underneath. The user wanted the
composer to set the model **for that one chat**, outranking both tiers.

**The fix.** A third, higher-priority resolution tier, persisted per chat:
`ChatSummary.modelProviderId`/`.modelId` (new nullable `chats` columns,
migration v44→v45). `AgentProvidersConfig.provider(forStage:)`/`.modelId(forStage:)`
take an optional override id (default nil — every non-chat call site
unaffected); when set + enabled it outranks the stage pin, same fallback
posture as a disabled stage pin falling back to the global default. Threaded
through `AgentLauncher.startInteractiveQuery` → `DaemonChatHost.startChat`/
`continueChat`, seeded at chat creation via a new `ChatStartRequest.providerId`/
`.modelId` (the only case needing a wire-protocol change — a `.draft` chat has
no row yet). `ProviderSelector` now writes straight to the chat's row
(`WikiStoreModel.updateChatModelOverride`, mirroring the existing
`renameChat`/`deleteChat` direct-write pattern) instead of the global default;
`setSelectedModelAndDefault` was deleted as dead code once this was its only
caller.

**Tests.** `AgentProvidersConfigPerStageModelTests` (override > stage pin >
global default, disabled-override fallback), `ChatStoreTests` (schema,
create/round-trip/list, v44→v45 migration with no backfill), `StoreEmissionTests`
(new mutator emits `.chat .updated`). Targeted filters green (185 tests across
the touched suites); full suite is CI's job.

**Migration.** v44→v45 adds `model_provider_id`/`model_id` (nullable) to
`chats`. `GRDBWikiStore.schemaVersion` bumped to 45; three pre-existing tests
hardcoding `== 44` updated.

**Plan:** [`plans/chat-model-override.md`](plans/chat-model-override.md).

## Verification

Historical verification remains in the progress record above.
