# Daemon-Only Data Access

Status: in progress (P0 merged artifacts recorded here as they land). Owner
plan: the approved daemon-only migration (plan revision 2). Authoring model
family: OpenAI (codex/gpt-6.1-sol); implementation-phase reviewers must honor
the model-diversity policy at dispatch time.

The `wikid` daemon becomes the single authority for database, queue,
extraction, chat, and search state. The app, the shipping `wikictl`, and the
File Provider extension are thin clients over typed wire operations. A daemon
that is down or unhealthy produces an explicit unavailable state in every
client — never a silent local revival of a second writer.

## Transport table

| Client | Transport | Ops surface |
|---|---|---|
| App (wiki store family, P2+) | XPC (`WikiDaemonProtocol`), one `storeOperation(request:reply:)` selector | typed store ops + events sink |
| App (registry, P3) | existing XPC wiki lifecycle ops | create/delete/rename + registry events |
| App (search/chat/queue, P4–P5) | existing XPC families (`SearchRPCWire`, chat, queue RPC) | daemon-hosted search, chat turns, queue engine |
| `wikictl` (shipping) | App Group domain socket (`DaemonDomainSocketDispatcher`, `SearchSocketWire` framing) | CLI domain commands (already daemon-only) |
| File Provider (P6) | App Group domain socket, read-only `projection` family | container listing, node lookup, content fetch, tokens, manifests |

Frame budget: the 4 MiB cap (`SearchSocketWire.maxFrameSize`) applies to the
FINAL OUTER encoded envelope. The store family wraps its payloads in a nested
envelope (chunk `Data` inside the per-op DTO JSON, DTO JSON inside the store
reply's `result` Data for the structured typed-error contract, store reply
JSON inside the domain envelope's `payload` Data) — THREE base64 layers, not
the two this section originally estimated. Measured: a 1 MiB raw chunk is
≈ 1.33 MiB after the first layer, ≈ 1.83 MiB after the second, and 2.37 MiB
FINAL OUTER — inside the cap with ≈ 1.65 MiB headroom
(`DaemonStoreFrameSizing.outerEncodedBound` is the shared conservative
pre-flight bound). Tests assert the final outer size, never an inner DTO
size.

## Degradation model

- Store ops throw the typed `daemonUnavailable` / `outcomeUnknown` errors;
  nothing queues locally and no local fallback exists.
- Wiki windows show a reconnecting banner (`DaemonTransportAppCoordinator`,
  `DaemonHealthMonitor` states).
- The queue controller reports only daemon-active / unavailable / disposing
  from P4; `localReady` is unreachable.
- File Provider enumeration/content map daemon-down to File Provider errors
  Finder renders as unavailable (standing operator decision).
- The `allowLocalStore` flag: `true` = LOCAL access, `false` = daemon. P2 dev
  runs `true`; from P3 the default is `false` everywhere, the override is
  `#if DEBUG`-only, fixed at launch, never selected by daemon failure, and it
  is deleted at the P5 close. `StoreModeConfigurationTests` pins polarity.

## Permitted-access table (authoritative, per phase)

| Local access | P0 | P1 | P2 | P3 | P4 | P5 | P6 | P7 |
|---|---|---|---|---|---|---|---|---|
| App: wiki DB (store + model) | waiver | waiver | local default | remote default; DEBUG override | remote default; DEBUG override | override removed | none | **none** |
| App: local Tantivy index build | waiver (dead-path audit) | waiver | waiver | waiver | waiver | **none** | none | **none** |
| App: `WikiReadService` pool | waiver | waiver | waiver | waiver | waiver | **none** | none | none |
| App: local `QueueEngine` + `queue.sqlite` | waiver | waiver | waiver | waiver | **none** | none | none | none |
| App: import/manual extraction | waiver | waiver | waiver | waiver | **none** | none | none | none |
| App: semantic-search embedding reads | waiver | waiver | waiver | waiver | waiver | **none** | none | none |
| App: first-run legacy v0 DB import | waiver | waiver | waiver | daemon | none | none | none | **none** |
| File Provider: read-only wiki DB | waiver | waiver | waiver | waiver | waiver | waiver | **none** | **none** |
| `wikictl` shipping target | none | none | none | none | none | none | none | none |
| `wikictl-fixture` | allowed (documented carve-out) | | | | | | | |

## Open-seam harness (Phase 0 infrastructure)

`WikiOpenSeamRecorder` (`Sources/WikiFSCore/Store/WikiOpenSeamRecorder.swift`)
records opens at the four client-reachable seams — wiki store, read-only
pool, queue store, Tantivy writer. Attribution is BY INJECTION: the harness
boots the app composition with recording factories
(`AppPluginCatalogFactories.storeOpenFactories`, recording
`SearchRuntimeFactory.Factory`, recording `QueueRuntimeFactory.makeQueueStore`
/ `AppQueueExtractionProvider` queue factory); daemon and CLI compositions
keep plain factories, so a recorded open is by construction a CLIENT open.

`ClientLocalOpenBoundaryTests`:
- Positive control — local path enabled records every seam (a disconnected
  seam cannot fake a zero). The Tantivy writer is a DEAD PATH at app session
  boot today, so the control drives the search runtime factory directly.
- P0 column — real entry points (navigation, source import, search + index
  upgrade, queue enqueue) across multiple sessions/wikis open only the waived
  seams, labels never mix, unopened wikis record nothing.
- Failing seam — a throwing store factory surfaces the failure out of session
  boot (no half-booted session, no silent revival).
- Later phases tighten the expected counts to the table; P7 asserts zero with
  the daemon up and down.

## Source-level freedom guards (Phase 0)

- `AppStoreFreedomContractTests` — `Sources/WikiFS` + the four app-reachable
  engine composition files. Waivers pin exact counts; every entry names its
  clearing phase (P3 store cutover, P4 queue removal, P5 read-pool removal).
- `FileProviderStoreFreedomContractTests` — `Sources/WikiFSFileProvider`
  (waivers cleared at P6).
- `WikiCtlStoreFreedomContractTests` — `Sources/WikiCtlCore` +
  `Sources/wikictl`, ZERO waivers from day one; `wikictl-fixture` excluded as
  the documented build-only carve-out.
- Guard engine: `StoreFreedomGuardSupport` — most-specific-first token
  matching with overlap subtraction, exact-count waivers (new violations,
  stale waivers, and count drift all fail).

## Store operation manifest (P2.0)

See the plan §Phase 2.1 for the classification rules. This table lists every
`WikiStore` protocol requirement with exactly one classification:
**rpc** (structured wire op), **client** (client-local metadata), or
**removed** (no production consumer after cutover).

Counts (P2.0 baseline): 175 function requirements across 169 unique names
(`createPage` and `createChat` have 3 overloads each; `addSource`,
`claimNextPersistedChatTurn`, `finishPersistedChatTurn`, `markFetchComplete`,
and `sourceContent` have 2 each). Overload names share one classification,
but `RemoteWikiStore` implements every overload signature as its own wire op.
**rpc 151** — small 37, list 25, blob 39, event-producer 50 — **client 3**,
**removed 15**. Event-producer means the daemon executor must preserve
exactly-one-event-per-commit (`mutate`/`mutateBatch`/renderer-settings seam
discipline); conditional emitters and annotated no-emit rows are marked in
Notes.

| Requirement | Class | Notes |
|---|---|---|
| `abandonWorkspace` | rpc | event-producer; emits one event per commit (workspace dropped) |
| `activeContentVersion` | rpc | small |
| `activeExtractionProvenance` | rpc | small |
| `addBytelessSource` | rpc | event-producer; emits one event per commit |
| `addSnapshotImage` | rpc | blob; image bytes up (staged handle); commit emits one event |
| `addSource` | rpc | blob; source bytes up (staged handle); row + event published in ONE transaction (composed atomic — single remote op, never the sequential default) |
| `appendChatMessages` | rpc | blob; message array up (staged handle); commit emits one event |
| `appendChatTranscriptItems` | rpc | blob; transcript items up (staged handle); commit emits one event |
| `appendContentVersion` | rpc | blob; bytes up (staged handle); commit emits one event |
| `appendDerivedMarkdown` | rpc | blob; markdown up (staged handle); commit emits one event (routes via internal mutator) |
| `appendFetchMarkdown` | rpc | blob; markdown up (staged handle); commit emits one event |
| `appendHostSpeechTranscript` | rpc | blob; transcript up (staged handle); commit emits one event |
| `appendInstalledPackageMarkdown` | rpc | blob; markdown up (staged handle); commit emits one event |
| `appendLog` | rpc | event-producer; emits one event per commit |
| `appendPageVersion` | rpc | blob; body up (staged handle); CAS on expected head; commit emits one event |
| `appendProcessedMarkdown` | rpc | blob; markdown up (staged handle); commit emits one event |
| `appendUserProcessedMarkdown` | rpc | blob; markdown up (staged handle); commit emits one event |
| `attachAcquiredBytes` | rpc | blob; bytes up (staged handle); single-transaction publish emits one event |
| `cancelUnclaimedPersistedChatTurn` | rpc | event-producer; emits one event on claim flip; reply carries the turn when present (handle read if oversized) |
| `chatAttachments` | rpc | small |
| `chatMessages` | rpc | list; full transcript for one chat (cursor) |
| `chatTranscriptCheckpoint` | rpc | small |
| `chatTurnUsage` | removed | no production consumer; ChatUsageReadTests / SchemaV48MigrationTests / ChatTurnMetadataStoreTests only |
| `chatUsageSummary` | rpc | small |
| `checkpointStreamingMessage` | rpc | blob; draft text up (staged handle); commit emits one event |
| `claimNextPersistedChatTurn` | rpc | blob; event-producing claim; reply carries the full turn (handle read if oversized) |
| `correctPageOKFVerification` | rpc | event-producer; emits one event per commit (private mutate helper) |
| `correctSourceMarkdownOKFVerification` | rpc | event-producer; emits one event per commit (private mutate helper) |
| `createBookmarkNode` | rpc | event-producer; emits one event per commit |
| `createChat` | rpc | event-producer; emits one event per commit; composed attachment overload shares the family |
| `createPage` | rpc | blob; composed overloads carry body (staged handle); commit emits one event |
| `createWorkspace` | rpc | event-producer; emits one event per commit |
| `deleteBookmarkNode` | rpc | event-producer; emits one event per commit |
| `deleteChat` | rpc | event-producer; emits one event per commit |
| `deletePage` | removed | superseded: clients delete via deleteResources (model deleteSources); test-only callers |
| `deleteResources` | rpc | event-producer; batch mutator (mutateBatch: impact recheck, provenance gate, cleanup, delete); one transaction, post-commit events |
| `deleteSource` | removed | superseded: model deleteSources routes through deleteResources; never called on the protocol |
| `deletionImpact` | rpc | list; fan-out report, byte-budgeted (cursor / handle read for oversized items) |
| `editPersistedChatTurn` | removed | no production consumer; ChatPhase2PersistenceTests / StoreEmissionTests only |
| `embedDescriptors` | rpc | list; all-source descriptor scan (cursor) |
| `enqueuePersistedChatTurn` | rpc | blob; submission up (staged handle); commit emits one event |
| `ensureFetchActivity` | rpc | event-producer; emits one event per commit; returns activity id |
| `eventBus` | client | client-local bus fed by sink events (2c); model reload + File Provider signaler subscribe |
| `extractionProvenance` | removed | no production consumer; extraction-writer contract tests only |
| `fetchState` | rpc | small |
| `finalizeStaleDrafts` | rpc | event-producer; emits one event per commit |
| `finishPersistedChatTurn` | rpc | blob; completion events up (staged handle); commit emits one event |
| `getChat` | rpc | small |
| `getMetadata` | rpc | small |
| `getPage` | rpc | blob; bodyMarkdown down; oversized page served by handle read |
| `getWikiIndex` | rpc | blob; index.md body down (handle read when oversized) |
| `getWikiStrategy` | rpc | blob; instructions body down (staged handle read) |
| `getWikiStrategyState` | rpc | small |
| `hasImageSiblings` | rpc | small |
| `hasProcessedMarkdown` | rpc | small |
| `initialContentVersion` | rpc | small |
| `latestChatTurnUsage` | removed | no production consumer; ChatUsageReadTests only |
| `listAllChatsOrderedByID` | rpc | list; cursor |
| `listBookmarkNodes` | rpc | list; cursor (bookmark tree) |
| `listChats` | rpc | list; cursor |
| `listPages` | rpc | list; cursor (summaries, no bodies) |
| `listPersistedChatTurns` | rpc | list; cursor (per chat) |
| `listRendererSourcePreferences` | removed | no production consumer; test fake (ModelDelayedWikiStore) only; per-source reads use rendererSourcePreference |
| `listSources` | rpc | list; cursor (summaries, no bytes) |
| `markedSourceIDs` | rpc | list; ingested-marker set scan (cursor) |
| `markFetchComplete` | rpc | event-producer; emits one event per commit; variant overload returns conditional Bool |
| `markPersistedChatTurnProviderSubmitted` | rpc | event-producer; emits one event per commit |
| `markSourceIngested` | rpc | event-producer; emits one event per commit |
| `missingChatEmbeddingWork` | rpc | blob; text batch down (handle read when oversized) |
| `missingPageEmbeddingWork` | rpc | blob; text batch down (handle read when oversized) |
| `missingSourceEmbeddingWork` | rpc | blob; text batch down (handle read when oversized) |
| `moveBookmarkNode` | rpc | event-producer; emits one event per commit |
| `pageEditHistory` | rpc | list; cursor (per page) |
| `pageHeadSources` | rpc | small |
| `pageHeadVersionID` | rpc | small |
| `pageLinkingPages` | removed | no production consumer; tests only |
| `pageOKFMetadata` | rpc | small |
| `pageOrigin` | rpc | small |
| `pagesCitingSources` | rpc | list; limit-bounded; cursor for large citation sets |
| `pageVersionBody` | rpc | blob; body down (staged handle read) |
| `pageVersionHistory` | rpc | list; cursor (per page) |
| `pageVersionSources` | rpc | small |
| `processedMarkdownAgentNames` | rpc | list; per-source version-name map (cursor) |
| `processedMarkdownAlternatives` | rpc | list; per-source alternatives (cursor) |
| `processedMarkdownHead` | rpc | blob; head markdown down (staged handle read) |
| `processedMarkdownHistory` | rpc | list; cursor (per source) |
| `processedMarkdownVersion` | rpc | blob; full version content down (staged handle read) |
| `readChatTranscriptPage` | rpc | list; cursor-paged transcript |
| `reapStaleWorkspaces` | rpc | event-producer; bulk abandon; emits events per commit |
| `recentLogEntries` | rpc | list; log tail (cursor) |
| `recordMarkdownExtraction` | rpc | blob; content up (staged handle); commit emits one event (delegates to appendDerivedMarkdown) |
| `recordPageOKFVerification` | rpc | event-producer; emits one event per commit (private mutate helper) |
| `recordSourceMarkdownOKFVerification` | rpc | event-producer; emits one event per commit (private mutate helper) |
| `registeredExtractionInputs` | client | daemon-authoritative value in session bootstrap (2e); model reads it for import routing; settable locally |
| `registeredRendererSourceTypes` | client | daemon-authoritative value in session bootstrap (2e); reader/renderer wiring reads it |
| `removePersistedQueuedChatTurn` | removed | no production consumer; tests only |
| `removeRendererSourcePresentation` | rpc | event-producer; renderer settings seam (mutateRendererSettings) emits |
| `renameBookmarkFolder` | rpc | event-producer; emits one event per commit |
| `renameChat` | rpc | event-producer; emits one event per commit |
| `renameSource` | rpc | event-producer; emits one event per commit |
| `rendererInputByteCount` | rpc | small |
| `rendererSettingsJournalRecords` | removed | no production consumer; tests only |
| `rendererSourcePreference` | rpc | small |
| `rendererSourcePresentation` | rpc | small |
| `repairMIME` | rpc | event-producer; mutateBatch; report reply |
| `replaceLinks` | rpc | event-producer; links bounded per page; commit emits one event |
| `resolveChatByTitle` | rpc | small |
| `resolveSourceByName` | rpc | small |
| `resolveTitleToID` | rpc | small |
| `restorePage` | rpc | event-producer; emits one event per commit |
| `retargetBookmarkNode` | rpc | event-producer; emits one event per commit |
| `revertPage` | rpc | event-producer; emits one event per commit |
| `revertProcessedMarkdown` | removed | no caller; doc-comment mention in SourceVersioning.swift only |
| `saveWikiStrategy` | rpc | blob; instructions up (staged handle); CAS on expected revision; unchanged save emits nothing |
| `searchSimilar` | rpc | small; limit-bounded reply |
| `searchSimilarChats` | rpc | small; limit-bounded reply |
| `searchSimilarSources` | rpc | small; limit-bounded reply |
| `setAcquisitionProvenance` | removed | no production consumer; FetcherQueuePipelineTests only |
| `setActiveMarkdown` | rpc | event-producer; pointer flip; commit emits one event |
| `setChatAttachments` | rpc | event-producer; emits one event per commit |
| `setChatTitleIf` | rpc | event-producer; conditional: true emits one .chat .updated; false emits nothing |
| `setChatTitleIfEmpty` | rpc | event-producer; conditional: first-send write emits; already-titled emits nothing |
| `setMetadata` | rpc | small; annotated NO-EMIT (flags do not change projected content) |
| `setPageOKFFreshness` | rpc | event-producer; emits one .page .updated per commit |
| `setPageOKFStatus` | rpc | event-producer; emits one .page .updated per commit |
| `setRendererSourcePreference` | rpc | event-producer; renderer settings seam (mutateRendererSettings) emits |
| `setRendererSourcePresentation` | rpc | event-producer; renderer settings seam (mutateRendererSettings) emits |
| `setSourceDisplayName` | rpc | event-producer; emits one event per commit |
| `setSourceMarkdownOKFFreshness` | rpc | event-producer; emits one .source .updated per commit |
| `setSourceMarkdownOKFStatus` | rpc | event-producer; emits one .source .updated per commit |
| `setWorkspaceIndexBody` | rpc | blob; index body up (staged handle); commit emits one event |
| `siblingImageResolvers` | rpc | list; all-source resolver map (cursor) |
| `sourceContent` | rpc | blob; bytes down (staged handle read); id and versionID overloads share the family |
| `sourceDerivedChains` | rpc | list; all-source chain map (cursor) |
| `sourceEditHistory` | rpc | list; cursor (per source) |
| `sourceLinkingPages` | removed | no production consumer; tests only |
| `sourceMarkdownOKFMetadata` | rpc | small |
| `sourceMatchingURLIdentity` | rpc | small |
| `sourceOrigin` | rpc | small |
| `sourceOriginsBySource` | rpc | list; all-source origin map (cursor) |
| `sourceProvenanceBlockers` | removed | no production consumer; blockers surface via deletionImpact / deletionRestricted |
| `sourceReferencingPageVersions` | removed | no production consumer; tests only |
| `sourcesWithPendingFormatJobs` | rpc | list; recovery scan (cursor) |
| `sourceVersion` | rpc | small |
| `storeChatChunks` | rpc | blob; chunk array up (staged handle); commit emits one event |
| `storePageChunks` | rpc | blob; chunk array up (staged handle); commit emits one event |
| `storeSourceChunks` | rpc | blob; chunk array up (staged handle); commit emits one event |
| `updateChatAcpSessionId` | rpc | event-producer; emits one event per commit |
| `updateChatModelAndThinkingSelection` | rpc | event-producer; emits one event per commit |
| `updateChatModelOverride` | rpc | event-producer; emits one event per commit |
| `updateMessageSummary` | rpc | event-producer; emits one event per commit |
| `updatePage` | rpc | blob; body up (staged handle); commit emits one event |
| `updatePersistedChatTurnUsage` | rpc | event-producer; emits one event per commit |
| `updateWikiIndex` | rpc | blob; index body up (staged handle); commit emits one event |
| `upsertPage` | rpc | blob; rawBody up (staged handle); composed atomic — single remote op, never the sequential default; commit emits one event |
| `vacuumActivities` | rpc | small; no-emit maintenance write (dbWriter.write); report reply |
| `vacuumBlobs` | rpc | small; no-emit maintenance write (dbWriter.write); report reply |
| `vacuumPageVersions` | rpc | small; no-emit maintenance write (dbWriter.write); report reply |
| `wikiStrategyRevision` | rpc | small |
| `workspaceConflicts` | rpc | list; conflict set after divergent merge (cursor) |
| `workspaceMerge` | rpc | event-producer; merge commits inside one transaction (emits); merge-log reply scales like a list |
| `workspacePageBody` | rpc | blob; body down (staged handle read) |
| `workspacePageVersion` | rpc | small |
| `workspaceRefresh` | rpc | event-producer; emits one event per commit |
| `workspaceRefs` | rpc | list; cursor (workspace-scale ref set) |
| `workspaceResolveConflict` | rpc | event-producer; emits one event per commit |
| `workspaceRetryMerge` | rpc | event-producer; emits one event per commit |
| `workspaceSummary` | rpc | small |
| `workspaceWritePage` | rpc | blob; body up (staged handle); commit emits one event |

## Error mapping (P2.0)

`WikiStoreError` case → wire case → reconstruction, with associated values
intact (`duplicateContent`/`duplicateURL` carry `SourceSummary`,
`deletionRestricted` carries blockers, typed not-found IDs preserved, CAS
family carried via `DaemonConflictDetail`). Transport-level
`daemonUnavailable`/`outcomeUnknown` covers connection loss. Deliberate
collapses: NONE (documented here if any appear).

Case inventory verified against `WikiStoreError` at P2.0: `open`,
`sqlite(code:message:)` (transport-opaque — reconstruct code + message, no
more specific meaning), `notFound(PageID)` (typed not-found family),
`chatNotFound`, `sourceNotFound`, `sourceVersionNotFound`,
`sourceMarkdownVersionNotFound`, `noProcessedMarkdown`, `deletionRestricted`,
`invalidBookmarkRow`, `invalidRendererEventID`, `unexpected`,
`duplicateContent`, `duplicateURL` — plus the CAS family (`PageConflictError`,
`PageCreateConflictError`, `PageExpectedTargetMissingError`,
`WikiStrategyConflictError`, `SourceMarkdownConflictError`).

## Event contract (filled at P2–P3)

- Acknowledged `sinkHandshake` returns `{daemonEpoch, perWiki: [{wikiID,
  changeToken, lastSequence}]}`; handshake completion is the readiness
  barrier; pre-handshake events buffer.
- Every event carries `{epoch, wikiID, sequence, changeToken, batch}`;
  watermarks keyed by `(epoch, wikiID)`; daemon restart → new epoch, so
  sequence restart is never a duplicate.
- Reconnect: re-register → handshake → watermark diff → change-token check →
  ONE reconciliation reload. No automatic mutation retry, ever.

## Chunking rules (filled at P2)

Staged payload handles: `payloadBegin` (size + SHA-256) → `payloadChunk`
(ordered, hash-checked) → `payloadCommit` (returns handle). Handles expire on
TTL/disconnect; partial handles never execute; the real op executes through
its own method-atomic store entry point. Byte-budgeted replies bound
ACCUMULATED ENCODED BYTES with cursor pagination; an oversized single item is
served by a handle read. Ratified limits (`DaemonStoreLimits`, one place):
1 MiB raw chunk, 256 MiB staged-upload cap, 900 s upload TTL, 600 s
committed-handle TTL, 1 MiB encoded list-reply budget, 64-entry per-wiki
outcome cache, 1 MiB direct XPC payload.

## Baseline artifacts (Phase 0)

- Golden master:
  `Tests/WikiFSTests/Fixtures/GoldenMasterStoreState/baseline.txt` — the
  recorded fixture script's exporter output (state + script notes pinning
  typed errors like `PageConflictError`/`.duplicateContent` + the full
  `ResourceChangeEvent` sequence, ULIDs normalized to `u<n>`, timestamps to
  `t*`). Compared by `GoldenMasterStoreStateTests`; regenerate intentionally
  with `GOLDEN_MASTER_REGENERATE=1` and review the diff.
- Performance baseline (`SESSION_OPEN_BENCHMARK=1 swift test --filter
  SessionOpenLatencyBudgetTests`, opt-in; P0 local-store numbers, macOS
  dev machine, debug build):
  - session open (cold, real `bootWikiSession` path): min 4.0ms,
    median 4.3ms, p90 27.2ms (first run pays composition warm-up)
  - page open (20-page navigation): median 0.2ms
  - sidebar search (model search path): median ~0ms, p90 0.2ms
  - queue enqueue→terminal round trip: median 0.2ms
  - P7 budget: session open, page open, search, ingestion completion
    ≤ 1.25× these numbers on the same machine class.

## Waiver history

Shrinking record of the freedom-guard waiver lists (initial P0 lists live in
the test files):

- P0: app 8 waiver entries, File Provider 1, CLI 0.
- (later phases append "removed X at Pn" lines here)
