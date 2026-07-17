## Summary

Remove ~28 redundant per-mutator `reload*()` calls from `WikiStoreModel.swift`. After the #129 event-bus landed (Phase E), the model subscribes to ALL `ResourceChangeEvent`s via `subscribeToChanges()`, which calls `reloadFromStore()` on every event. The bus delivers async (`Task { @MainActor in ... }`), so the manual reload doesn't replace the bus-driven one — it **doubles** it: 8 table scans + 2 history-prune passes per save where 4 suffice.

## Changes

### Production code (`WikiStoreModel.swift`)

Removed `reloadSummaries()`, `reloadSources()`, `reloadBookmarkNodes()`, and `reloadChats()` calls from:
- **Page mutators:** `save()`, `newPage()`, `newPageInNewTab()`, `rename()`, `delete()`, `preflightLint()`
- **Source mutators:** `addFiles()`, `addURL()` (all paths), `addSource()`, `ingestFromZotero()`, `importFromMarkdownFolder()`, `renameSource()`, `deleteSource()`, `performRefresh()`
- **Bookmark mutators:** `createFolder()`, `addPageRef()`, `addSourceRef()`, `addChatRef()`, `renameBookmarkNode()`, `deleteBookmarkNode()`, `moveBookmarkNode()`
- **Chat mutators:** `startChat()`, `rollbackChatCreation()`, `appendChatEvents()`, `renameChat()`, `updateChatSummary()`, `deleteChat()`

### Exceptions kept

- **`agentRunEnded()`** (line ~1603): still calls `reloadFromStore()` — legit exception, updates run counts and is not driven by store events.
- **`pageSortOrder.didSet`** and **`init`**: not mutators — sort change and initial load.
- **`startChat()`**: instead of `reloadChats()`, inserts the single new row directly via `chats.insert(chat, at: 0)` — the immediate caller (`retargetActiveTabToChat → retargetTab → tabTitle`) reads `chats` synchronously.
- **Mutators that `openTab(...)` the just-created row** (8 sites): the bus reload is async, but `tabTitle(for:)` reads the `summaries`/`sources` arrays synchronously. Fixed by passing the known title explicitly to `openTab(_:title:)` so `tabTitle` is never called, and capturing `effectiveName` from the returned `SourceSummary` for source-creating mutators.

### Test fixes

Tests without an event bus rely on the (now-removed) synchronous reloads. Fixed by adding explicit `model.reloadFromStore()` (or `model.reloadChats()`/`model.reloadBookmarkNodes()`) after mutations before checking model arrays. The bus itself is tested separately in `WikiChangeBridgeBusTests` / `WikiEventBusTests` with proper async polling.

## Performance impact

Each local mutation that previously triggered:
- 1 synchronous reload (4 table scans + history prune) from the mutator
- 1 async reload (4 table scans + prune + render-context rebuild) from the bus

Now triggers only the async bus-driven reload. **~50% reduction in table scans per mutation.**

## Test plan

- [x] `swift build` passes
- [x] Fast test tier passes (2438 tests, 0 failures):
  ```
  swift test --skip 'EnumeratorDeletionTests|SQLiteWikiStoreTests|StoreEmissionTests|FreshSchemaParityTests|SQLiteStatementLifecycleIntegrationTests|BlobVacuumTests|AgentCASTests|GenerationGateLaneTests|WorkspaceStagingTests|WorkspaceMergeCompletenessTests|IngestIsolationTests|ChatSummaryTests|ProjectionTreeTests'
  ```

Fixes #491
