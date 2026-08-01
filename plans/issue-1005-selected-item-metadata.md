# Issue #1005: Selected-item metadata — reviewed implementation handoff

Status: Approved full structural scope. All phases in this document are required for issue completion.

Verified baseline: `GRDBWikiStore.currentSchemaVersion` is 47. The next schema version is 48. The app targets macOS 15 and Swift 6.0 through SwiftPM.

## Goal

Replace the version-focused default inspector with a metadata inspector for the selected page, source, or persisted chat.

Keep page versions, source extraction comparison, and history available as secondary tabs or typed actions. Persist the missing chat-turn usage and page-source provenance. Read existing extraction provenance through typed projections. Use one shared inspector model and one shared SwiftUI renderer.

The inspector performs no store I/O. The selected detail surface owns hydration, cancellation, and refresh.

## Implementation Summary

1. Add `.metadata` to `InspectorTab` and replace tab booleans with an ordered `[InspectorTab]`.
2. Add pure tab normalization and legacy `@AppStorage` decoding.
3. Add typed metadata models, projections, values, and action targets under `Sources/WikiFS/Detail/`.
4. Extend the existing `chat_turns` row keyed by `(chat_id, turn_id)`. Do not add a run ID.
5. Keep `DaemonChatController` as the sole chat-turn lifecycle writer.
6. Add the append-only `page_version_sources` relation keyed by typed `PageVersionID`, `SourceID`, and role.
7. Add typed extraction provenance reads over existing `source_markdown_versions`, `activities`, and `agents` data.
8. Canonicalize extraction writes through two typed store seams: generated extraction and derived transcript/tool output.
9. Add schema migration v47 to v48 before the catch-all migration guard.
10. Hydrate metadata through detail-owned cancellable tasks and `WikiReadPool` reads.
11. Refresh durable metadata from `WikiEventBus` and Darwin cross-process notification. Refresh active chat fields from daemon sync updates.
12. Deliver all phases as independently buildable pull requests. All phases are required.

## Implementation Plan

### 1. Domain and presentation types

Add these Foundation-only domain types in `WikiFSTypes` or `WikiFSCore` as appropriate:

```swift
public enum PageVersionSourceRole: String, Codable, CaseIterable, Sendable {
    case primary
    case supporting
    case quoted
}

public struct PageVersionSource: Equatable, Hashable, Sendable {
    public let pageVersionID: PageVersionID
    public let sourceID: SourceID
    public let role: PageVersionSourceRole
}

public struct ChatTurnUsage: Equatable, Sendable {
    public let turnID: ChatTurnID
    public let providerID: ProviderID?
    public let modelID: ModelID?
    public let startedAt: Date?
    public let finishedAt: Date?
    public let state: ChatTurnPersistenceState
    public let inputTokens: Int?
    public let outputTokens: Int?
    public let thoughtTokens: Int?
    public let cacheReadTokens: Int?
    public let cacheWriteTokens: Int?
    public let cost: Decimal?
    public let currency: String?
}

public enum ExtractionProducer: Equatable, Sendable {
    case backend(ExtractionBackend)
    case tool(ExtractionTool)
    case legacy(rawTechnique: String?)
}

public enum ExtractionTool: String, Codable, CaseIterable, Sendable {
    case docling
    case pdf2md
    case html
    case appleTTML
    case youtubeCaptions
    case rssPodcastTranscript
    case vimeoTranscript
    case materializerSidecar
    case bytelessOEmbedSynthetic
    case transcript
}

public struct ExtractionProvenance: Equatable, Sendable {
    public let markdownVersionID: SourceMarkdownVersionID
    public let sourceID: SourceID
    public let origin: SourceMarkdownOrigin
    public let producer: ExtractionProducer
    public let providerID: ProviderID?
    public let modelID: ModelID?
    public let toolVersion: String?
    public let createdAt: Date
    public let sourceVersionID: SourceVersionID?
}
```

`ModelID` must be the existing typed model identifier if one exists at implementation head. If no type exists, add a `RawRepresentable`, `Codable`, `Sendable` wrapper. Do not pass provider or model identity as bare `String` after boundary decoding.

Keep display types in `Sources/WikiFS/Detail/`:

```swift
struct MetadataPanelModel: Equatable, Sendable {
    let subject: MetadataSubject
    let sections: [MetadataSection]
    let emptyState: MetadataEmptyState
}

enum MetadataSubject: Equatable, Sendable {
    case page(PageID)
    case source(SourceID)
    case chat(ChatID)
}

struct MetadataSection: Identifiable, Equatable, Sendable {
    let id: MetadataSectionID
    let title: LocalizedStringKey?
    let rows: [MetadataRow]
}

struct MetadataRow: Identifiable, Equatable, Sendable {
    let id: MetadataFieldID
    let label: LocalizedStringKey
    let value: MetadataValue
    let accessibilityHint: LocalizedStringKey?
}

enum MetadataValue: Equatable, Sendable {
    case text(String)
    case date(Date)
    case byteCount(Int64)
    case integer(Int)
    case tokenCount(Int)
    case duration(Duration)
    case identifier(String)
    case link(label: String, target: MetadataLinkTarget)
    case action(label: String, target: MetadataActionTarget)
}

enum MetadataLinkTarget: Equatable, Sendable {
    case page(PageID)
    case source(SourceID)
    case chat(ChatID)
    case activity(QueueItem.ID)
    case url(URL)
}

enum MetadataActionTarget: Equatable, Sendable {
    case comparePageVersions(PageID)
    case compareSourceExtractions(SourceID)
    case copyIdentifier(String)
}
```

Use closed enums for section and field identities. Keep callbacks outside all `Sendable` values. Route targets through one `@MainActor` action handler in `RightSidebarRegistration`.

Add pure functions:

- `PageMetadataProjection.make(input:) -> MetadataPanelModel`
- `SourceMetadataProjection.make(input:) -> MetadataPanelModel`
- `ChatMetadataProjection.make(input:) -> MetadataPanelModel`
- `MetadataValueRenderer.presentation(for:locale:calendar:) -> MetadataRenderedValue`
- `InspectorTab.normalize(selection:availableTabs:) -> InspectorTab`
- `InspectorTab.decodePersisted(_:) -> InspectorTab`

Each projection accepts one immutable input struct. It performs no I/O and reads no global state.

### 2. Inspector tabs and layout

Change `InspectorTab` to this order:

```swift
enum InspectorTab: String, CaseIterable, Codable {
    case metadata
    case outline
    case history
}
```

Replace `showsOutlineTab` and `showsHistoryTab` in `RightSidebarRegistration` and `DetailInspectorView` with `availableTabs: [InspectorTab]`. The caller supplies a stable ordered list. Remove the boolean matrix and `effectiveInspectorTab` switch.

Use these tab lists:

- Page: `[.metadata, .outline, .history]`.
- Source with outline: `[.metadata, .outline, .history]`.
- Source without outline: `[.metadata, .history]`.
- Persisted chat: `[.metadata, .outline]`.
- A future metadata-only subject: `[.metadata]`.

Split empty-tab handling into two callables. `InspectorTab.normalizedFallback(selection:availableTabs:)` is pure and always returns a value: it keeps an available selection, otherwise chooses `.metadata`, otherwise the first tab, and returns `.metadata` for an empty list. `InspectorTab.normalize(selection:availableTabs:reportProgrammerError:)` wraps the pure function. For an empty list it invokes the injected reporter exactly once, then returns the pure fallback when the reporter returns. Production injects a debug-assertion reporter; tests inject a recording reporter that returns. Do not write one test that expects both a trapping assertion and a returned value.

Legacy decoding accepts `"outline"` and `"history"`. Unknown, empty, or corrupt values decode as `.metadata`. Existing valid legacy values remain selected when available. A detail owner writes the normalized value asynchronously from `.task(id:)` or `.onChange`, never during view construction.

Show the segmented picker only when two or more tabs exist. Generate picker items from `availableTabs` in order. Use text and SF Symbol labels. Give the picker the VoiceOver label “Inspector section.”

`MetadataPanelView` uses a `ScrollView` and compact sections. At effective width below `MetadataMetrics.stackedRowThreshold`, use stacked rows. At or above the threshold, use a two-column grid. Set the threshold as a named metric after hosted layout tests establish the smallest readable width. Keep the inspector clamp at 180 through 500 points.

Use system typography:

- Section title: `.caption`, semibold, secondary style.
- Label: `.caption`, regular, secondary style.
- Value: `.callout`, regular, primary style.
- Identifier: `.caption.monospaced()`, middle truncation, selectable.
- Counts: tabular digits.

Use system colors, spacing, dividers, and materials. Do not add card backgrounds. Let values wrap before labels collapse. All actions use text labels and accessible hints. Respect increased text size and VoiceOver.

### 3. Hydration, ownership, and refresh

Each detail surface owns a `MetadataHydrationState` finite state machine:

```swift
enum MetadataHydrationState: Equatable {
    case idle
    case loading(subject: MetadataSubject)
    case loaded(MetadataPanelModel)
    case failed(subject: MetadataSubject, message: String)
}
```

Do not use independent loading and error booleans.

The page, source, and chat detail views start hydration with `.task(id: MetadataHydrationKey)`. The key includes the typed subject ID and the durable revision or event generation that invalidates the projection. The task checks cancellation before every state write. A subject change cancels the prior task through SwiftUI structured task ownership.

Read file-backed metadata through `WikiReadPool.asyncRead`. Use the main-store fallback for in-memory tests. Return value types only. Do not retain a GRDB `Database`, row, statement, or connection across a call boundary.

`DetailInspectorView` and `MetadataPanelView` receive only presentation state. They perform no store calls, no daemon calls, and no task creation.

Refresh rules:

- Page and source durable changes use `WikiEventBus` after the writer commits.
- Chat durable changes use the chat `ResourceChangeEvent` after the writer commits.
- Live chat status and usage use the existing daemon `ChatSyncProjection` stream.
- Merge live and persisted chat data by `ChatTurnID`. The live value replaces the persisted value for the same active turn. Never sum both.
- Cross-process writes from `wikid` or `wikictl` use the existing Darwin notification and model reload path. The reload advances the hydration key.
- A live daemon update must not cause a store read in the inspector. The detail owner combines its cached durable projection with the live snapshot.

### 4. Durable chat-turn metadata

#### 4.1 Chosen lifecycle

Extend the existing `chat_turns` row. Its durable identity remains `(chat_id, turn_id)`. Do not add `chat_runs` or a new run ID.

`DaemonChatController` remains the sole lifecycle writer. UI code, `RemoteChatSession`, runtimes, providers, and store observers cannot start, update, or finish a turn.

Add nullable columns to `chat_turns`:

```text
provider_id             TEXT
model_id                TEXT
finished_at             REAL
input_tokens            INTEGER
output_tokens           INTEGER
thought_tokens          INTEGER
cache_read_tokens       INTEGER
cache_write_tokens      INTEGER
cost_decimal            TEXT
currency                TEXT
```

Reuse `claimed_at` as `startedAt`. This timestamp is written in the same transaction that changes `.queued` to `.claimed`. This is the exact lifecycle start because the controller has won the durable claim and will attempt runtime work. `submitted_at` remains user submission time. `provider_submitted_at` remains the at-most-once provider boundary.

Snapshot provider and model at claim time. Resolve them from the same `ChatRuntimeStartRequest` configuration used by `DaemonChatController`. Persist typed `ProviderID?` and `ModelID?` raw values in the claim transaction. A warm runtime still uses the provider and model effective for that claimed turn. Later settings changes do not rewrite the snapshot.

#### 4.2 Usage semantics

Provider usage events are cumulative snapshots for the current provider session. Add a controller-owned `ChatTurnUsageAccumulator`. It stores the baseline seen when the turn starts and the latest snapshot for that generation and turn.

For a new runtime session, the baseline is zero. For a warm session, capture the last cumulative session snapshot before submission as the baseline. For each update, compute the turn value with the existing nonnegative cumulative-delta rules used by `SessionUsage.incremental(from:to:)`. A provider final response can contain input, output, and thought totals. A streamed usage update can contain context, cache, or cost data. Merge fields by these rules:

- Token counters use the greatest valid cumulative value observed for that turn.
- A smaller counter means provider reset or malformed data. Reject it and retain the prior value.
- Cost uses the latest cumulative turn delta when currency matches.
- A currency change makes cost unavailable and logs through `DebugLog`.
- Missing fields do not erase prior non-nil values.
- All persisted counters are nonnegative.
- `totalTokens` is computed as input plus output. Do not persist a separate total.

Add `updatePersistedChatTurnUsage(chatID:turnID:claimID:usage:)`. It updates only a `.claimed` or `.providerSubmitted` row with matching claim identity. It emits one chat event after commit. It rejects stale claim IDs and terminal rows.

Change `finishPersistedChatTurn` to accept `finishedAt`, final usage, and terminal outcome in one atomic transaction. The first valid terminal transition from `.claimed` or `.providerSubmitted` wins. Later completion, failure, cancellation, stop, or transport-close signals return the existing terminal row without changing state, time, message, or usage.

#### 4.3 Terminal paths

Use one controller method, `finishTurnIfCurrent(turnID:generation:outcome:at:)`, for all terminal signals. It checks, in order:

1. The event generation equals the controller generation.
2. `currentClaimTurnID` equals the event turn.
3. `currentClaimID` exists.
4. The snapshot turn is not terminal.
5. The store transition with that claim succeeds or reports the existing terminal winner.

Only the winner records the terminal session event and clears the claim. This covers success, runtime failure, explicit cancel, stop while active, transport close, and restart recovery.

A stale generation event does nothing and logs a rejected diagnostic. A stale turn event in the current generation also does nothing. It cannot mutate usage or terminal state.

On daemon restart, `bootstrapSnapshot` finds `.claimed` and `.providerSubmitted` rows. It finishes each as `.failed` with category `.interrupted`, `finishedAt` equal to the bootstrap clock, and its last persisted usage. It does not fabricate provider or token data.

A user retry creates a new `ChatTurnSubmission` with a new `ChatTurnID` and `ChatCommandID`. The old row remains terminal. Retrying never reopens or overwrites a terminal turn. Replayed duplicate submission with the same command ID remains idempotent and returns the existing row.

#### 4.4 Store reads

Add these `WikiStore` APIs:

- `chatTurnUsage(chatID:turnID:) throws -> ChatTurnUsage?`
- `latestChatTurnUsage(chatID:) throws -> ChatTurnUsage?`
- `chatUsageSummary(chatID:) throws -> ChatUsageSummary`
- `updatePersistedChatTurnUsage(chatID:turnID:claimID:usage:) throws -> PersistedChatTurn`
- the extended atomic `finishPersistedChatTurn(...)` signature

`ChatUsageSummary` contains the latest turn and aggregate input, output, thought, cache-read, cache-write, and cost values. Define all three reads explicitly:

- `chatTurnUsage(chatID:turnID:)` returns the exact typed row for the composite identity or `nil` when the chat or turn is missing. Decode every persisted field: turn, provider, model, start, finish, state, five counters, decimal cost, and currency. A legacy row remains a valid `ChatTurnUsage` with nil metadata.
- `latestChatTurnUsage(chatID:)` orders by the durable turn ordinal, not timestamps, and returns `nil` for an empty or missing chat. It returns the highest ordinal even when that row has all legacy usage fields nil.
- `chatUsageSummary(chatID:)` returns a zero-counter, nil-latest, nil-cost summary for an empty or missing chat. Sum each non-nil counter independently; all-nil legacy rows contribute zero. Sum cost only when every contributing non-nil cost has one matching non-nil currency. Return both aggregate cost and currency as nil for mixed currencies or any cost without currency. Rows with nil cost do not create a currency conflict.

Aggregate queries use typed row decoding at the persistence boundary. Use checked integer addition and checked decimal parsing. Overflow or an invalid stored decimal throws the existing typed corruption error; it must not wrap, truncate, or silently omit data.

### 5. Typed page-version-to-source provenance

#### 5.1 Schema and invariants

Add this append-only table in schema v48:

```sql
CREATE TABLE page_version_sources (
    page_version_id TEXT NOT NULL
        REFERENCES page_versions(id) ON DELETE CASCADE,
    source_id TEXT NOT NULL
        REFERENCES sources(id) ON DELETE RESTRICT,
    role TEXT NOT NULL
        CHECK (role IN ('primary', 'supporting', 'quoted')),
    PRIMARY KEY (page_version_id, source_id, role)
) WITHOUT ROWID;

CREATE INDEX page_version_sources_source
    ON page_version_sources(source_id, page_version_id);
```

The primary key provides exact uniqueness. Deleting a page cascades through `page_versions` and deletes edges. Deleting one unreachable page version deletes its edges. Source deletion uses `RESTRICT` because an auditable page version must not retain a dangling source. A restricted source deletion returns typed provenance blocker identity. It must not silently erase provenance. Issue #219 owns the combined deletion-impact UI and policy.

There is no update API and no delete API for individual edges. The relation is append-only. Garbage collection removes edges only through page-version cascade.

Decode `role` with `PageVersionSourceRole(rawValue:)` at the database boundary. An unknown role throws a typed corruption error and logs it. Application code never compares raw role strings or page/source raw IDs.

#### 5.2 Write contract

Add `PageVersionSourceInput` with typed `SourceID` and role. Add `sourceProvenance: [PageVersionSourceInput]` to every API that can create a page version. Default it to `[]` only at compatibility boundaries.

Use one internal transactional helper for every creation seam: `createPageVersionWithProvenance(on:request:)`. Its typed request carries the version row, activity write, mirror/ref/head mutations, and `[PageVersionSourceInput]`. The caller must already be inside the seam’s GRDB transaction; the helper does not open or commit a nested transaction and does not emit. It validates and normalizes all inputs before its first write, writes the version/activity/mirror/ref/head and every edge, and returns the committed-event payload to the outer mutator. The outer mutator emits exactly once only after commit. Every main, CAS, upsert, workspace mint/merge/refresh/resolution, restore, CLI, agent, and editor creation path calls this helper; no seam writes `page_versions` or `page_version_sources` directly.

The duplicate policy is exact: duplicate means the same `(SourceID, PageVersionSourceRole)` appears more than once in one request. Reject the entire request with `PageVersionProvenanceWriteError.duplicateInput`; do not silently deduplicate. The same source with two different roles is valid because roles carry distinct evidence semantics. Sort validated inputs by role raw value then `SourceID` only to make writes deterministic; read ordering remains the display ordering in section 5.4.

Typed callers cannot construct an invalid role. Compatibility boundaries such as CLI/raw JSON decode `PageVersionSourceRole(rawValue:)` before calling the helper. An unknown or empty role returns `PageVersionProvenanceWriteError.invalidRole(rawValue:)`; it does not default to `.supporting` or `[]`. Missing source, duplicate input, invalid role, CAS failure, or any later SQL failure rolls back the page version, activity, mirror, workspace/main ref, head, every edge, blob reference/count effect, and event. Event emission occurs only after the complete commit.

The no-op save path creates no version and no new edges. The amend path must stop amending when the normalized provenance set differs from the head set. If content, title, author, and provenance all match, it can amend timestamps under existing rules. If provenance differs, append a new page version.

#### 5.3 Creation seam matrix

| Seam | Required provenance semantics |
| --- | --- |
| `createPage` empty root | Use `[]`. An empty user-created root has no source evidence. |
| `updatePage` | Pass the current typed edit context. User edits normally use `[]`. An explicit “edit from source” action passes its typed source. |
| `appendPageVersion` CAS | Require caller-provided typed inputs. CAS failure writes no edge. |
| `PageUpsert` | Extend input with `[PageVersionSourceInput]`. The new page’s first content version receives them. |
| Workspace write, existing page | Store edges on the workspace-created `page_versions` row in the same transaction. |
| Workspace write, staged new page | Add `workspace_ref_sources(workspace_id, owner_id, source_id, role)` with typed semantics and matching FKs. Merge copies these rows to the minted root version atomically. |
| Workspace fast-forward | Reuse the workspace version and its existing immutable edges. Do not copy edges to another version. |
| Workspace diff3 merge or refresh | The new merge version gets the set union of source edges from the main and workspace parent versions. Preserve roles independently. |
| Workspace conflict resolution | The new resolution version gets the set union from the conflicted main and workspace versions. |
| `restorePage` | Copy all edges from the target version to the new restore version. |
| Legacy `revertPage` pointer move | Create no version and no edge. The active target already owns its immutable edges. Keep this compatibility command, but the app UI continues to use append-only restore. |
| `wikictl page add` and CAS update | Add repeatable `--source <SourceID>[:role]`. Decode at CLI boundary. Omitted means `[]`. |
| `wikictl page revert` | Keep pointer semantics. It selects a version that already owns provenance. |
| Agent ingest | Build typed inputs from the queue payload’s `sourceIDs`. The primary assigned source is `.primary`; remaining consulted sources are `.supporting`. |
| User editor autosave | Use `[]` unless the editor session has an explicit typed source context. Never infer from wiki links or body text. |

Add `workspace_ref_sources` because a staged new page has no `PageVersionID` before merge:

```sql
CREATE TABLE workspace_ref_sources (
    workspace_id TEXT NOT NULL,
    kind TEXT NOT NULL CHECK (kind = 'page-content'),
    owner_id TEXT NOT NULL,
    source_id TEXT NOT NULL REFERENCES sources(id) ON DELETE RESTRICT,
    role TEXT NOT NULL CHECK (role IN ('primary', 'supporting', 'quoted')),
    PRIMARY KEY (workspace_id, kind, owner_id, source_id, role),
    FOREIGN KEY (workspace_id, kind, owner_id)
      REFERENCES workspace_refs(workspace_id, kind, owner_id) ON DELETE CASCADE
) WITHOUT ROWID;
```

The parent key is exactly `workspace_refs(workspace_id, kind, owner_id)`, so `kind` is required in both the child primary key and composite foreign key. All writes bind the closed value `page-content`; application code does not compare its raw string. The composite parent cascade also removes staged provenance when its workspace ref is removed. The source FK remains `RESTRICT`.

#### 5.4 Reads

Add:

- `pageVersionSources(versionID:) throws -> [PageVersionSource]`
- `pageHeadSources(pageID:) throws -> [PageVersionSource]`
- `sourceReferencingPageVersions(sourceID:) throws -> [PageVersionID]`

Define all three reads explicitly:

- `pageVersionSources(versionID:)` returns `[]` for a missing version, a legacy version, or a version with no edges. It returns typed `PageVersionSource` values.
- `pageHeadSources(pageID:)` resolves the page’s current head first and delegates to the version read. It returns `[]` for a missing page, a page without a head, or a legacy head without edges. It must not return sources from a newer non-head alternative.
- `sourceReferencingPageVersions(sourceID:)` returns every typed referencing `PageVersionID` in ascending page-version ID order. It returns `[]` for a missing or unreferenced source.

Order page source reads by role order `primary`, `supporting`, `quoted`, then case-insensitive source display name, then typed source ID as the stable tie-breaker. Implement role order with a SQL `CASE` isolated at the persistence boundary. Decode every role before returning any result. An unknown role throws the typed corruption error for all affected read methods; it never sorts as an untyped fallback.

### 6. Extraction provenance

`recordMarkdownExtraction` already stores `modelVersion` in `agents.version` and `activities.plan`. Do not add a duplicate model string to `source_markdown_versions`.

Add `extractionProvenance(markdownVersionID:)` and `activeExtractionProvenance(sourceID:)`. Join `source_markdown_versions` to `activities` and `agents`. Decode:

- `technique` into `ExtractionBackend` when it matches a backend.
- Known non-provider techniques into `ExtractionTool`. The closed set includes
  `.docling`, `.pdf2md`, `.html`, `.appleTTML`, `.youtubeCaptions`,
  `.rssPodcastTranscript`, `.vimeoTranscript`, `.materializerSidecar`,
  `.bytelessOEmbedSynthetic`, and `.transcript`.
- `agents.external_ref` or a structured activity field into optional `ProviderID` when present.
- `agents.version` into `ModelID` only for provider/model producers.
- A separate tool version from structured activity plan data for local tools.

Do not label a tool version as a model. For `pdf2md 0.4`, show producer “pdf2md” and tool version “0.4.” For Anthropic or Gemini extraction, show backend, provider, and model.

Replace hand-built JSON interpolation in `recordMarkdownExtraction` with a Codable `ExtractionActivityPlan` and `ExtractionActivityPlanCodec`. The current encoded shape has an explicit version, typed producer, typed origin, optional provider ID, model ID, tool version, source-version ID, and note. The codec must round-trip the current version, decode the legacy backend/model shape, and reject an unsupported explicit version with `ExtractionPlanCodecError.unsupportedVersion`. Malformed JSON returns a codec failure to the projection, which then retains normalized technique, origin, agent, and source-version columns instead of hiding them.

Define the canonical `appendDerivedMarkdown` validation contract before implementation:

1. Reject `.user`, `.source`, and `.revert` origins; those remain on their existing dedicated APIs.
2. Reject a model without a provider-backed producer.
3. Reject a provider ID or model ID for a local-tool producer unless that producer explicitly carries a provider-backed mode.
4. Reject a tool version for a backend producer.
5. Reject a `sourceVersionID` that does not belong to `sourceID`.
6. Reject a derived write whose source does not exist.
7. Accept nil provider, model, tool version, source version, and note when the selected producer permits them.

Use typed `AppendDerivedMarkdownError` cases for these branches. Validate before writing. Persist the markdown version, normalized origin/producer columns, versioned activity plan, optional source-version link, blob/refcount effects, and active-head change in one transaction. Add internal `AppendDerivedMarkdownHooks.afterInitialWrites`, a production no-op checkpoint invoked exactly once after the new derived-version row and activity plan are inserted but before source-version link, blob/refcount, and active-head updates. Tests can throw a typed injected failure. No public API exposes the hook.

On success, the new version becomes active; existing versions remain alternatives. On validation, hook, or persistence failure, roll back the derived version, activity plan, source-version link, prior/new head, blob row/refcount, and event. A retry with the hook disabled succeeds when the request is otherwise valid; IDs must be generated inside the transaction or request semantics must explicitly permit retry without collision. Keep legacy plan decoding and compatibility overloads, but route every compatible derived/transcript writer through `appendDerivedMarkdown`.

Canonicalize writers:

| Writer | Canonical write |
| --- | --- |
| PDF queue extraction | `recordMarkdownExtraction` with backend, provider, model, and source version. |
| PDF seed extraction | Same generated-extraction API. |
| PDF re-extract | Same API with a new immutable markdown version. |
| ACP extraction | Backend `.acp`, typed provider and model snapshot. |
| Anthropic extraction | Backend `.anthropic`, typed provider and model snapshot. |
| Gemini extraction | Backend `.gemini`, typed provider and model snapshot. |
| Docling | Tool `.docling` and optional tool version. No provider/model unless Docling used a provider. |
| Local pdf2md | Tool `.pdf2md` and optional tool version. |
| HTML extraction | Tool `.html` with the selected HTML backend encoded in the activity plan. |
| Materializer sidecars | Tool `.materializerSidecar`; preserve sidecar technique as legacy detail when unknown. |
| Apple, YouTube, RSS, and podcast transcripts | `appendDerivedMarkdown` with origin `.transcript` and a closed transcript tool. |
| Imported Vimeo transcript compatibility input | `appendDerivedMarkdown` with origin `.transcript` and tool `.vimeoTranscript`. This phase does not add a native Vimeo network fetcher. |
| Imported transcript through `wikictl` | Same derived-markdown API with tool `.transcript`. |
| Byteless oEmbed synthetic markdown | Tool `.bytelessOEmbedSynthetic`; it remains distinct from a transcript and round-trips through the activity plan. |
| User markdown edit | `appendProcessedMarkdown` with origin `.user`; extraction projection returns nil. |
| Source-body seed | Origin `.source`; extraction projection returns nil. |
| Revert | Origin `.revert`; projection identifies the revert and can link to the target extraction through existing lineage. |

Add a canonical `appendDerivedMarkdown(sourceID:content:origin:producer:sourceVersionID:note:)`. Keep `appendProcessedMarkdown` as the compatibility boundary and route known call sites to the typed API. Unknown legacy `technique` values decode as `.legacy(rawTechnique:)` and display the raw tool name in Technical. Nil technique and nil activity produce an omitted producer row. Legacy model data in `agents.version` remains visible when the joined activity is an extraction. Corrupt plan JSON does not hide valid technique or agent data.

### 7. Schema v48

Set `GRDBWikiStore.currentSchemaVersion` to 48.

Add an explicit `if version < 48` block immediately after the v47 block and before the catch-all at the current lines near 1319. Before opening `db.inTransaction(.immediate)`, the migration entry point asks the selected `SchemaForeignKeyChecker` to verify that `PRAGMA foreign_keys = 1`. If enforcement is disabled, throw `SchemaV48MigrationError.foreignKeyEnforcementDisabled`; do not enter the transaction, create any v48 object, or change `user_version` from 47. The normal path then runs `db.inTransaction(.immediate)`, calls `migrateV47ToV48(in:)`, stamps `PRAGMA user_version = 48`, and commits. Set local `version = 48` only after commit.

`migrateV47ToV48` must use this idempotent, rebuild-only algorithm:

1. Inspect `chat_turns` columns and normalized table SQL.
2. When the table is still v47, create `chat_turns_v48` with the complete final definition and checks, copy every v47 column plus `NULL` for each new field, verify copied and source row counts match, drop `chat_turns`, rename `chat_turns_v48`, and recreate its indexes.
3. When `chat_turns` already has the complete v48 definition, skip the rebuild. If a stale `chat_turns_v48` exists from an externally interrupted attempt, drop it before starting; ordinary transaction rollback leaves none.
4. If the table has a partial or unknown shape, throw a typed migration error instead of guessing or losing data.
5. Create `page_version_sources`, `workspace_ref_sources`, and their indexes with `IF NOT EXISTS`.
6. Invoke the instance-scoped `SchemaForeignKeyChecker.check(_:)` after the complete final schema exists and before `PRAGMA user_version = 48` or commit. The production default executes real `PRAGMA foreign_key_check` on that same connection and returns typed `[ForeignKeyCheckViolation]` rows.
7. Map a non-empty returned result to `SchemaV48MigrationError.foreignKeyViolation([ForeignKeyCheckViolation])` and roll back.
8. If an injected checker throws, catch it at the migration boundary and throw `SchemaV48MigrationError.foreignKeyCheckerFailed(underlying:)`, preserving the original cause for inspection and logging. This branch is distinct from a successful checker call that returns violations. Roll back every v48 object and retain `user_version = 47`.
9. An empty returned result permits the version stamp and commit.
10. Do not backfill chat usage or page-source edges.
11. Do not rewrite existing extraction rows.

Add internal injectable `SchemaV48MigrationHooks` with only the executable no-op checkpoints `afterShadowCleanup` and `afterChatCopy(sourceCount:copiedCount:)`, in that order. Call each exactly once on the v47 rebuild path. `afterShadowCleanup` runs after stale-shadow removal and before final-table creation. `afterChatCopy` runs after copy and real count calculation but before count comparison; it can override only the observed copied count in tests. Foreign-key verification is not a mutation hook; no migration fixture inserts a referentially invalid row.

Define internal `SchemaForeignKeyChecker` as a `@Sendable` closure wrapper or protocol with `verifyEnforcement(_ db: Database) throws` and `check(_ db: Database) throws -> [ForeignKeyCheckViolation]`. Its production default implements `verifyEnforcement` with real `PRAGMA foreign_keys` and maps zero to `SchemaV48MigrationError.foreignKeyEnforcementDisabled`; it implements `check` with real `PRAGMA foreign_key_check`. Tests inject a checker that returns a non-empty typed result or throws a sentinel cause without changing FK enforcement or inserting invalid data. The migration calls `verifyEnforcement` before the immediate transaction and `check` at the final-schema checkpoint: after every v48 table/index and the `chat_turns` rename exists, before version stamp and commit. The checker is immutable instance state supplied by an internal initializer or fixture factory; each store/fixture gets either its explicit checker or a fresh production default. It is not global, static mutable state, or retained after rollback/reopen.

The disabled-enforcement fixture must open a dedicated migration connection, execute `PRAGMA foreign_keys = OFF`, verify the pragma returns zero, and only then invoke migration. It must not toggle enforcement inside the immediate transaction. The clean retry closes or reconfigures the pre-transaction connection with enforcement enabled before invoking migration again. The throwing-checker retry creates a fresh store/fixture instance with the production checker; it does not mutate checker state mid-transaction.

Construct every migration fixture through `SchemaV48FixtureFactory`, which creates a production v47 schema and then applies a typed `ChatTurnsSchemaClassificationFixture` mutation. The factory must invoke the same production `classifyChatTurnsSchema(columns:normalizedSQL:)` used by migration; tests must not hand-label a fixture as partial, unknown, or final. Pass hooks and checker only through an internal migration initializer marked for `@testable` use; no public store API exposes them. Migration errors include typed `partialChatTurnsShape`, `unknownChatTurnsDefinition`, `copyCountMismatch`, `foreignKeyEnforcementDisabled`, `foreignKeyViolation([ForeignKeyCheckViolation])`, `foreignKeyCheckerFailed(underlying:)`, and `constraintViolation` cases. Disabled enforcement fails before transaction entry with no v48 objects. Any hook throw, returned checker violation, thrown checker cause, or invalid copied row rolls back shadow cleanup, copied/final tables, indexes, provenance tables, and version stamp, retaining `user_version = 47`.

Update `createFreshSchema(on:)` to include the final v48 chat columns and provenance tables directly. Fresh schema and upgraded schema must have identical `sqlite_master` SQL after normalization.

Add checks:

- Chat token columns are null or nonnegative.
- `finished_at` is null or not less than `claimed_at`.
- Currency is null when cost is null.
- Role values use closed checks.
- All provenance FKs are active.

SQLite cannot add table checks to existing `chat_turns` columns with simple `ALTER TABLE`. Therefore, v48 must rebuild `chat_turns` transactionally into `chat_turns_v48`, copy all v47 rows, verify row counts, drop old, and rename new. Recreate all indexes. This replaces the earlier additive-column outline and is the required implementation. The helper remains idempotent by inspecting the final column set and table SQL before rebuild.

Nullable/backfill policy:

- All new chat metadata is nullable for v47 rows.
- Existing terminal turns keep `finished_at = NULL`.
- Existing page versions get no inferred source edges.
- Existing extraction rows remain unchanged and use legacy projection rules.

Read-only compatibility:

- `init(readOnlyURL:)` never migrates.
- New read methods inspect required table or column presence.
- Against v47, they return nil or empty typed projections instead of throwing “no such table/column.”
- The main writer migrates first in normal app startup.

Migration transaction and retry behavior:

- The entire v47 to v48 change and version stamp is one immediate transaction.
- Failure rolls back all v48 objects and leaves `user_version = 47`.
- Reopen retries from 47.
- Reopen at 48 is a no-op.
- A test that rewinds only `user_version` to 47 on an already-v48 schema reruns safely and returns to 48 without data loss.

### 8. Metadata contents and actions

Page metadata shows created, modified, page version, writer, activity, saved date, source chat, and typed originating sources. Show one row per source or a deterministic summarized list with typed links. Put the hash in Technical. Provide `Compare Versions…`.

Source metadata shows content kind, MIME type, size, added, modified, role, provider origin, external identity, active extraction origin, backend or tool, provider, model or tool version, extraction date, source version, extraction version, and alternatives count. Put hashes and legacy technique in Technical. Provide `Compare Extractions…` when at least two alternatives exist.

Chat metadata shows created, updated, message count, latest turn provider, model, started, finished, duration, status, input, output, total, thought, cache read, cache write, and cost when available. Aggregate totals use `chatUsageSummary`. Legacy chats omit unavailable rows. `ChatSummary.createdAt` is only the conversation creation date, never a later turn start fallback.

Action routing rules:

- Page target opens the page in the current wiki.
- Source target opens the source.
- Chat target opens the persisted chat.
- Activity target opens the Activity window and selects the exact queue item.
- URL target uses the existing safe external-open path.
- Compare actions open existing page and source comparison surfaces.
- Copy action writes only the displayed identifier to the pasteboard.

### 9. Independently buildable phases and pull requests

All phases are required for issue completion. Do not merge directly to `main`.

#### Phase 1 / PR 1: Domain and schema v48

Add typed chat usage, extraction provenance, page-source roles, schema v48, migration guards, read-only compatibility, and store APIs. Include `SchemaV48FixtureFactory`, the production schema classifier, both executable migration hooks, and instance-scoped `SchemaForeignKeyChecker` with its real-PRAGMA production default. Add no inspector UI. Existing callers compile through compatibility overloads.

#### Phase 2 / PR 2: Chat lifecycle persistence

Make `DaemonChatController` the only caller of the new chat lifecycle writes. Add cumulative usage accumulation, provider/model snapshots, direct store guards for both nonterminal and all terminal states, atomic final usage from both finish states, first-winner field preservation, restart interruption, stale-event rejection, and retry identity.

#### Phase 3 / PR 3: Page-source provenance writers

Thread typed source inputs through main, CAS, workspace, restore, CLI, agent ingest, and user-edit seams through `createPageVersionWithProvenance(on:request:)`. Add exact duplicate and compatibility-role validation before writes. Add staged workspace provenance.

Preserve source-delete `RESTRICT` and convert it into a typed domain failure without parsing SQLite error text. Add `ResourceDeletionRestriction.provenance(NonEmptyProvenanceDeletionBlockers)`. Each `ProvenanceDeletionBlocker` contains `sourceID`, `pageVersionID`, and owning `pageID`. `NonEmptyProvenanceDeletionBlockers` has a non-empty initializer and exposes an ordered array; an empty collection is unrepresentable.

Before deletion, query every provenance edge for the source in the same transaction. Deduplicate by the full typed identity `(sourceID, pageID, pageVersionID)`, so distinct versions of one page remain distinct blockers. Order by `pageID`, then `pageVersionID`, then `sourceID`, all by raw-value byte order at the persistence boundary. If the collection is non-empty, return or throw the complete typed restriction before issuing `DELETE`; write nothing and emit no event. A concurrent FK race still maps to a refreshed complete collection in a retrying read transaction. Never return only the first blocker. An unreferenced source deletes and emits its normal single event.

Issue #219 owns deletion-impact analysis and all deletion UI. Its analysis combines incoming links, incoming bookmarks, and provenance references as separate typed categories. It also owns link-to-plain-text conversion, required bookmark removal, blocker presentation, and navigation. Phase 3 exposes provenance blockers as analysis input only. Issue #1005 must not add a standalone blocker list, recovery sheet, alert, or navigation flow.

#### Phase 4 / PR 4: Extraction canonicalization

Add typed extraction activity plans and projections. Add internal production-no-op `AppendDerivedMarkdownHooks.afterInitialWrites` with rollback and retry coverage. Move all known extraction and transcript writers to canonical typed seams. Keep compatibility decoding for legacy data.

Phase 4 implementation uses `ExtractionActivityPlan`,
`ExtractionActivityPlanCodec`, `AppendDerivedMarkdownError`, and
`GRDBWikiStore.appendDerivedMarkdown`. The current activity plan stores version,
producer, origin, provider, model, tool version, source version, and note.
Malformed or unsupported plan JSON falls back to normalized markdown, activity,
and agent columns. The Phase 4 source-markdown API manifest lists the canonical
append method with its compatibility writers.

#### Phase 5 / PR 5: Shared metadata inspector

Add ordered tabs, injectable empty-tab assertion reporting plus pure fallback, shared metadata models, exhaustive conditional projections, every renderer case, action-router no-op/error/eligibility paths, detail-owned hydration, live/persisted chat merge, event refresh, hosted layout tests, and accessibility.

##### Implemented Phase 5 decisions

Phase 5 uses `InspectorTab.metadata`, `.outline`, and `.history` as ordered
caller-supplied arrays. `InspectorTab.decodePersisted(_:)` accepts the legacy
outline/history values and maps invalid persistence to metadata;
`normalizedFallback(selection:availableTabs:)` stays pure, while
`normalize(selection:availableTabs:reportProgrammerError:)` reports an empty
tab list exactly once before returning that fallback. Detail owners normalize
persisted state only from keyed task work, never during view construction.

`MetadataPanelModel`, `MetadataSubject`, `MetadataSection`, `MetadataRow`,
`MetadataValue`, typed link/action targets, and all three projections live in
the app presentation layer. They are immutable value models with no callbacks,
store, daemon, or database-handle references. `MetadataValueRenderer` is the
single locale/calendar-aware renderer, and `MetadataActionRouter` is the sole
main-actor side-effect seam for typed navigation, comparison, copy, and
validated HTTP(S) URLs.

`MetadataPanelView` is shared by page, source, and chat inspectors. It has a
180...500-point inspector clamp and uses
`MetadataMetrics.stackedRowThreshold == 300`: hosted `NSWindow` tests establish
stacked rows below 300 and a two-column grid at 300 through 500. Identifiers
are selectable, values wrap, controls use their native keyboard and VoiceOver
semantics, and the picker is announced as “Inspector section.”

Each detail view owns exactly one `MetadataHydrationState`; its
`MetadataHydrationKey` includes the typed subject and `messageVersion` durable
generation. File-backed tasks call `WikiReadPool.asyncRead` and return value
models; the in-memory fallback stays on the model store. Cancellation is
checked before every owner state publication. Durable event/Darwin reloads
advance `messageVersion`; chat daemon updates re-project cached durable data
without another store read. Live chat usage is overlaid by `ChatTurnID`: a
matching turn replaces in place, while a distinct active turn remains separate
from historical usage and is never counter-summed.

Issue #219 still exclusively owns deletion warnings, cleanup, blocker
presentation, and deletion navigation. This phase adds no deletion UI.

Each phase must run all commands before review:

```text
make build
make test
swift build
swift test
```

A phase is not independently buildable if it needs a later phase to compile, migrate, or pass tests. Use temporary compatibility overloads when required, then remove them in the final phase when all call sites are typed.

## Acceptance Criteria

- **AC-01:** Metadata is the default available inspector tab for pages, sources, and persisted chats.
- **AC-02:** The inspector uses ordered tabs and pure normalization. It contains no tab-availability boolean matrix.
- **AC-03:** Legacy `outline`, `history`, unknown, and corrupt stored values decode and normalize deterministically.
- **AC-04:** The shared renderer handles every `MetadataValue` case, optional omission, empty state, and Technical content.
- **AC-05:** Every metadata link and action routes to the exact typed target.
- **AC-06:** The hosted inspector is readable and accessible at 180 and 500 points.
- **AC-07:** The inspector performs no store or daemon I/O.
- **AC-08:** Detail-owned hydration cancels stale subject work and never applies stale results.
- **AC-09:** Chat metadata extends the durable turn keyed by `ChatTurnID`. No unrelated run ID exists.
- **AC-10:** `claimed_at` is the exact turn start timestamp. Provider and model are snapshotted at claim.
- **AC-11:** Cumulative usage yields correct per-turn deltas for streamed, final-only, mixed, missing, reset, and malformed forms.
- **AC-12:** One terminal outcome wins across success, failure, cancel, stop, transport close, and restart.
- **AC-13:** Old-generation, old-claim, and wrong-turn events cannot mutate a current turn.
- **AC-14:** Restart marks claimed or submitted turns interrupted and preserves the last valid usage.
- **AC-15:** Retry creates a new `ChatTurnID`; duplicate command replay remains idempotent.
- **AC-16:** Live and persisted data merge by `ChatTurnID` without double counting.
- **AC-17:** `page_version_sources` is append-only, typed, constrained, indexed, and atomic with page-version creation.
- **AC-18:** Every page-version creation seam applies the specified provenance semantics.
- **AC-19:** Page-source identity comparisons use typed IDs only outside persistence boundaries.
- **AC-20:** Extraction reads expose backend or tool, optional provider/model, and separate tool version from existing activities and agents.
- **AC-21:** Every listed extraction writer uses a canonical typed seam or an explicit legacy compatibility boundary.
- **AC-22:** Nil and legacy extraction data render without false provider or model claims.
- **AC-23:** Schema v48 supports fresh, upgrade, retry, idempotent reopen, rewind, FK, check, and read-only compatibility paths.
- **AC-24:** Every public metadata mutation emits one `ResourceChangeEvent` after commit.
- **AC-25:** Read-pool readers see committed metadata and never see rolled-back metadata.
- **AC-26:** Cross-process extraction, page, and chat changes refresh the selected inspector.
- **AC-27:** Existing Versions, History, and Compare Extractions behavior remains available.
- **AC-28:** Every phase passes `make build`, `make test`, `swift build`, and `swift test`.
- **AC-29:** Final documentation updates `PLAN.md`, the tracked issue plan, and `progress/`.
- **AC-30:** The exact-head audit finds no untested new function or branch and no unresolved ordinary implementation question.
- **AC-31:** All three chat usage reads handle missing, empty, legacy, complete decoding, ordinal selection, independent counter aggregation, matching currency, mixed currency, overflow, and corrupt decimal branches.
- **AC-32:** All three page provenance reads return typed values, deterministic ordering, current-head results, compatibility empties, unreferenced empties, and typed corruption for unknown roles.
- **AC-33:** The v48 migration rejects stale, partial, unknown, copy-mismatch, disabled FK enforcement, non-empty typed foreign-key-check results, thrown checker failures, and constraint-invalid states through distinct typed errors. Production verifies enforcement before the immediate transaction and runs real `PRAGMA foreign_key_check`; tests never toggle enforcement inside the transaction.
- **AC-34:** The extraction plan codec and canonical append API cover current, legacy, unsupported, malformed, nil, typed persistence, source-version, active-head, compatibility, and every typed validation branch.
- **AC-35:** Source deletion preserves `RESTRICT`, returns a deterministic non-empty typed provenance blocker collection without silently deleting edges or emitting, succeeds for an unreferenced source, and maps the full collection into issue #219’s provenance incoming-reference category.
- **AC-36:** One transactional helper owns every page-version provenance creation seam. It rejects exact duplicate pairs and invalid compatibility roles before writes, and every failure rolls back version, activity, mirror/ref/head, blob, all edges, and event.
- **AC-37:** Direct chat store transitions accept usage only for matching claimed or provider-submitted rows, reject every terminal state and stale claims, finish atomically from both nonterminal states, and preserve every first-winner field on later terminal outcomes.
- **AC-38:** Migration fixture classification, both executable hooks, and the final-schema foreign-key checker have exact invocation tests. Hook failures, constraint-invalid copied data, and injected checker violations remove all v48 objects and retain schema version 47. Retry uses fresh instance state, and production defaults do not leak across stores or fixtures.
- **AC-39:** Derived extraction persistence invokes its production-no-op checkpoint exactly once, rolls back every initial and later effect on failure, emits nothing, and supports a clean retry.
- **AC-40:** Empty inspector tabs report the programmer error through an injectable wrapper and independently return the pure metadata fallback when the reporter returns.
- **AC-41:** Page, source, and chat projections have one named test for every conditional row, ordering rule, typed target, eligibility threshold, optional extraction field, duration state, usage/status field, currency branch, and empty state.
- **AC-42:** Every `MetadataValue` renderer case and every action-router target, missing-subject, unavailable-compare, unsafe-URL, no-op, and error path has a direct named test.

## Test Strategy

Use Swift Testing for new unit and integration tests. Use XCTest only where hosted AppKit or accessibility APIs require it. Use injected clocks and scripted runtimes. Do not use timing sleeps for daemon lifecycle tests.

### AC-to-named-test matrix

| AC | Test file and named test functions |
| --- | --- |
| AC-01, AC-02 | `Tests/WikiFSAppTests/InspectorTabTests.swift`: `pageTabsStartWithMetadata()`, `sourceTabsStartWithMetadata()`, `chatTabsStartWithMetadata()`, `metadataOnlyHidesPicker()`, `registrationCarriesOrderedTabsNotBooleans()` |
| AC-03, AC-40 | `InspectorTabTests.swift`: `legacyOutlineDecodes()`, `legacyHistoryDecodes()`, `unknownValueDecodesAsMetadata()`, `normalizationKeepsAvailableSelection()`, `normalizationFallsBackToMetadata()`, `normalizationFallsBackToFirstWithoutMetadata()`, `emptyTabsReportsProgrammerErrorExactlyOnce()`, `emptyTabsPureFallbackReturnsMetadataWhenReporterReturns()`, `nonEmptyTabsDoNotReportProgrammerError()` |
| AC-04, AC-41 | `Tests/WikiFSAppTests/PageMetadataProjectionTests.swift`: `pageProjectionOmitsSourceRowsWhenAbsent()`, `pageProjectionIncludesSourceRowsWhenPresent()`, `pageProjectionOrdersSourceRowsByRoleNameAndID()`, `pageProjectionSourceRowsCarryTypedSourceTargets()`, `pageProjectionShowsTechnicalHashWhenPresent()`, `pageProjectionOmitsTechnicalHashWhenAbsent()`; `SourceMetadataProjectionTests.swift`: `sourceProjectionWithZeroAlternativesOmitsCompareAction()`, `sourceProjectionWithOneAlternativeOmitsCompareAction()`, `sourceProjectionWithTwoAlternativesIncludesCompareAction()`, `sourceProjectionIncludesModelWhenPresent()`, `sourceProjectionOmitsModelWhenAbsent()`, `sourceProjectionIncludesProviderWhenPresent()`, `sourceProjectionOmitsProviderWhenAbsent()`, `sourceProjectionIncludesToolVersionWhenPresent()`, `sourceProjectionOmitsToolVersionWhenAbsent()`, `sourceProjectionIncludesExtractionDateWhenPresent()`, `sourceProjectionOmitsExtractionDateWhenAbsent()`, `sourceProjectionIncludesSourceVersionWhenPresent()`, `sourceProjectionOmitsSourceVersionWhenAbsent()`, `sourceProjectionIncludesExtractionVersionWhenPresent()`, `sourceProjectionOmitsExtractionVersionWhenAbsent()`, `sourceProjectionIncludesHashWhenPresent()`, `sourceProjectionOmitsHashWhenAbsent()`; `ChatMetadataProjectionTests.swift`: `chatProjectionLegacyRowOmitsUnavailableUsageRows()`, `chatProjectionMissingStartOmitsDuration()`, `chatProjectionMissingFinishOmitsDuration()`, `chatProjectionCompleteTimesShowsDuration()`, `chatProjectionShowsInputTokensWhenPresent()`, `chatProjectionShowsOutputTokensWhenPresent()`, `chatProjectionShowsComputedTotalWhenInputAndOutputPresent()`, `chatProjectionOmitsTotalWhenInputMissing()`, `chatProjectionOmitsTotalWhenOutputMissing()`, `chatProjectionShowsCacheReadWhenPresent()`, `chatProjectionShowsCacheWriteWhenPresent()`, `chatProjectionShowsCostForMatchingCurrency()`, `chatProjectionOmitsCostForMixedCurrency()`, `chatProjectionShowsStatusWhenPresent()`, `chatProjectionOmitsStatusWhenUnavailable()`, `metadataProjectionUsesStableEmptyStateWhenNoRows()`, `technicalSectionContainsOnlyTechnicalFields()` |
| AC-05, AC-42 | `Tests/WikiFSAppTests/MetadataActionRouterTests.swift`: `opensTypedPageTarget()`, `opensTypedSourceTarget()`, `opensTypedChatTarget()`, `selectsExactActivityTarget()`, `opensValidatedURLTarget()`, `opensPageVersionComparison()`, `opensSourceExtractionComparison()`, `copiesExactIdentifier()`, `missingSubjectReturnsNoOp()`, `pageCompareUnavailableReturnsNoOp()`, `sourceCompareUnavailableReturnsNoOp()`, `unsafeURLIsRejectedWithoutOpen()`, `copyFailureReturnsTypedError()`, `targetOpenFailureReturnsTypedError()`, `explicitNoOpPerformsNoSideEffect()`; `MetadataValueRendererTests.swift`: `rendersText()`, `rendersDate()`, `rendersByteCount()`, `rendersInteger()`, `rendersTokenCount()`, `rendersDuration()`, `rendersIdentifier()`, `rendersLink()`, `rendersAction()`, `usesTabularDigitsForCounts()` |
| AC-06 | `Tests/WikiFSAppTests/MetadataPanelHostedTests.swift`: `hostedInspectorAt180UsesStackedRows()`, `hostedInspectorAt500UsesGridRows()`, `hostedInspectorSupportsWrappedValues()`, `hostedInspectorExposesPickerLabel()`, `hostedRowsExposeLabelsValuesAndHints()`, `hostedActionsAreKeyboardAndVoiceOverReachable()`, `hostedIdentifiersAreSelectable()` |
| AC-07 | `MetadataPanelHostedTests.swift`: `renderingMetadataPerformsNoStoreRead()`; `Tests/WikiFSTests/MetadataAPISignatureManifestTests.swift`: `inspectorTypesDoNotReferenceWikiStore()` |
| AC-08 | `Tests/WikiFSAppTests/MetadataHydrationTests.swift`: `subjectChangeCancelsPriorHydration()`, `cancelledHydrationCannotPublish()`, `failedHydrationPublishesTypedFailure()`, `inMemoryHydrationUsesStoreFallback()`, `fileHydrationUsesReadPool()` |
| AC-09, AC-10 | `Tests/WikiFSTests/ChatTurnMetadataStoreTests.swift`: `usageIsKeyedByChatAndTurn()`, `claimWritesStartedAtProviderAndModelAtomically()`, `noChatRunIdentifierExists()` |
| AC-31 | `Tests/WikiFSTests/ChatUsageReadTests.swift`: `chatTurnUsageReturnsNilForMissingTurn()`, `chatTurnUsageDecodesEveryField()`, `chatTurnUsageDecodesLegacyAllNilRow()`, `latestChatTurnUsageReturnsNilForEmptyChat()`, `latestChatTurnUsageUsesHighestDurableOrdinal()`, `latestChatTurnUsageReturnsLatestLegacyAllNilRow()`, `chatUsageSummaryReturnsEmptySummaryForEmptyChat()`, `chatUsageSummaryAggregatesInputTokens()`, `chatUsageSummaryAggregatesOutputTokens()`, `chatUsageSummaryAggregatesThoughtTokens()`, `chatUsageSummaryAggregatesCacheReadTokens()`, `chatUsageSummaryAggregatesCacheWriteTokens()`, `chatUsageSummaryIgnoresLegacyAllNilRows()`, `chatUsageSummaryAggregatesMatchingCurrencyCost()`, `chatUsageSummaryOmitsMixedCurrencyCost()`, `chatUsageSummaryOmitsCostWithoutCurrency()`, `chatUsageSummaryRejectsCounterOverflow()`, `chatUsageSummaryRejectsMalformedDecimal()` |
| AC-11 | `Tests/WikiFSAppTests/DaemonChatUsageTests.swift`: `streamedCumulativeUsageProducesTurnDelta()`, `finalOnlyUsagePersists()`, `mixedStreamAndFinalUsesGreatestCounters()`, `missingUsageLeavesColumnsNil()`, `counterResetRetainsPriorValue()`, `decreasingCounterIsRejected()`, `currencyChangeClearsCostOnly()`, `cacheReadAndWritePersist()`, `thoughtTokensPersist()`, `warmSessionSubtractsBaseline()` |
| AC-37 | `Tests/WikiFSTests/ChatTurnMetadataStoreTransitionTests.swift`: `usageUpdateAcceptsClaimedTurnWithMatchingClaim()`, `usageUpdateAcceptsProviderSubmittedTurnWithMatchingClaim()`, `usageUpdateRejectsCompletedTurn()`, `usageUpdateRejectsFailedTurn()`, `usageUpdateRejectsCancelledTurn()`, `usageUpdateRejectsStaleClaim()`, `finishClaimedTurnPersistsTerminalOutcomeAndFinalUsageAtomically()`, `finishProviderSubmittedTurnPersistsTerminalOutcomeAndFinalUsageAtomically()`, `laterDifferentTerminalOutcomePreservesWinnerState()`, `laterDifferentTerminalOutcomePreservesWinnerFinishedAt()`, `laterDifferentTerminalOutcomePreservesWinnerMessageAndError()`, `laterDifferentTerminalOutcomePreservesWinnerProviderAndModel()`, `laterDifferentTerminalOutcomePreservesWinnerEveryUsageField()`, `rejectedStoreTransitionWritesNothingAndEmitsNothing()` |
| AC-12 | `Tests/WikiFSAppTests/DaemonChatControllerMetadataTests.swift`: `startClaimsAndSnapshotsConfiguration()`, `successWinsTerminalRace()`, `failureWinsTerminalRace()`, `cancelWinsTerminalRace()`, `stopActiveTurnCancelsAndFinishes()`, `stopIdleSessionDoesNotCreateTerminalWrite()`, `transportCloseInterruptsActiveTurn()`, `lateCompletionCannotReplaceCancellation()`, `lateFailureCannotReplaceSuccess()` |
| AC-13 | `DaemonChatControllerMetadataTests.swift`: `staleGenerationUsageIsRejected()`, `staleGenerationTerminalIsRejected()`, `wrongTurnEventIsRejected()`, `oldClaimUsageIsRejected()`, `terminalUsageUpdateIsRejected()` |
| AC-14 | `DaemonChatControllerMetadataTests.swift`: `restartInterruptsClaimedTurn()`, `restartInterruptsProviderSubmittedTurn()`, `restartPreservesQueuedTurns()`, `restartPreservesLastUsageSnapshot()`, `restartUsesInjectedBootstrapClock()` |
| AC-15 | `DaemonChatControllerMetadataTests.swift`: `retryCreatesNewTurnIdentity()`, `retryPreservesOldTerminalRow()`, `duplicateCommandReturnsExistingTurn()`, `duplicateTurnCannotCreateSecondUsageRow()` |
| AC-16 | `Tests/WikiFSAppTests/ChatMetadataMergeTests.swift`: `liveTurnReplacesSamePersistedTurn()`, `persistedCatchUpDoesNotDoubleCount()`, `differentTurnRemainsHistorical()`, `terminalPersistedValueReplacesLiveOverlay()` |
| AC-17 | `Tests/WikiFSTests/PageVersionSourceStoreTests.swift`: `insertsTypedEdge()`, `rejectsUnknownRoleAtBoundary()`, `enforcesUniqueTriple()`, `pageDeleteCascadesEdges()`, `versionGCcascadesEdges()`, `sourceDeleteIsRestricted()`, `edgeHasNoUpdateOrDeleteAPI()` |
| AC-32 | `Tests/WikiFSTests/PageVersionSourceReadTests.swift`: `pageVersionSourcesReturnsEmptyForMissingVersion()`, `pageVersionSourcesReturnsEmptyForLegacyVersion()`, `pageVersionSourcesReturnsTypedResults()`, `pageVersionSourcesOrdersByRoleThenDisplayNameThenID()`, `pageVersionSourcesThrowsTypedCorruptionForUnknownRole()`, `pageHeadSourcesReturnsEmptyForMissingPage()`, `pageHeadSourcesReturnsEmptyForLegacyHead()`, `pageHeadSourcesResolvesCurrentHeadNotAlternative()`, `pageHeadSourcesThrowsTypedCorruptionForUnknownRole()`, `sourceReferencingPageVersionsReturnsTypedOrderedIDs()`, `sourceReferencingPageVersionsReturnsEmptyForUnreferencedSource()`, `sourceReferencingPageVersionsReturnsEmptyForMissingSource()` |
| AC-18, AC-36 | `Tests/WikiFSTests/PageVersionSourceWriterTests.swift`: `createEmptyPageHasNoSources()`, `mainUpdateWritesSourcesAtomically()`, `casSuccessWritesSources()`, `casFailureWritesNothing()`, `noOpSaveWritesNoVersionOrEdges()`, `changedProvenanceDisablesAmend()`, `workspaceExistingPageWritesEdges()`, `workspaceStagedPageStoresTypedSources()`, `workspaceMintCopiesStagedSources()`, `workspaceFastForwardKeepsExistingEdges()`, `workspaceMergeUnionsParentEdges()`, `workspaceRefreshUnionsParentEdges()`, `workspaceConflictResolutionUnionsEdges()`, `restoreCopiesTargetEdges()`, `revertUsesTargetEdgesWithoutCopy()`, `wikictlAddDecodesSourceRoles()`, `wikictlCASWritesSources()`, `agentIngestMarksPrimaryAndSupporting()`, `agentIngestEnvironmentUsesAssignedPrimaryAndExplicitRolesAddOnly()`, `userEditDefaultsToNoSources()`, `explicitUserSourceContextWritesEdge()`, `transactionHelperSuccessWritesVersionActivityRefsAllEdgesAndReturnsEventPayload()`, `transactionHelperSQLFailureRollsBackEveryEffectAndEmitsNothing()`, `missingSourceRollsBackVersionActivityMirrorRefHeadBlobAllEdgesAndEvent()`, `duplicateExactSourceRoleInputWritesNothingAndEmitsNothing()`, `sameSourceWithDifferentRolesIsAccepted()`, `compatibilityInvalidRoleWritesNothingAndEmitsNothing()`, `compatibilityEmptyRoleWritesNothingAndEmitsNothing()`, `everyCreationSeamUsesTransactionalProvenanceHelper()` |
| AC-19 | `Tests/WikiFSTests/PageSourceNamespaceAuditTests.swift`: `productionProvenanceCodeHasNoRawPageSourceComparison()`, `pageAndSourceIDsCannotCrossAPIBoundary()` |
| AC-20 | `Tests/WikiFSTests/ExtractionProvenanceProjectionTests.swift`: `projectsACPBackendProviderAndModel()`, `projectsAnthropicBackendProviderAndModel()`, `projectsGeminiBackendProviderAndModel()`, `projectsDoclingToolVersion()`, `projectsPdf2mdToolVersion()`, `projectsHTMLToolAndBackend()`, `projectsTranscriptTool()`, `projectsBytelessOEmbedSyntheticTool()`, `projectsSourceVersionIdentity()`, `activeProjectionUsesActiveMarkdownRef()` |
| AC-34, AC-39 | `Tests/WikiFSTests/ExtractionActivityPlanCodecTests.swift`: `currentVersionRoundTripsEveryField()`, `legacyBackendModelShapeDecodes()`, `unsupportedVersionThrowsTypedError()`, `malformedJSONFallsBackAndRetainsNormalizedColumns()`, `nilOptionalFieldsRoundTrip()`, `bytelessOEmbedSyntheticToolRoundTrips()`; `Tests/WikiFSTests/AppendDerivedMarkdownTests.swift`: `persistsTypedProducerAndOrigin()`, `persistsPresentSourceVersion()`, `persistsAbsentSourceVersion()`, `newDerivedVersionBecomesActiveAndPriorVersionRemainsAlternative()`, `rejectsNonDerivedOrigin()`, `rejectsModelWithoutProviderBackedProducer()`, `rejectsProviderFieldsForLocalTool()`, `rejectsToolVersionForBackend()`, `rejectsForeignSourceVersion()`, `rejectsMissingSource()`, `acceptsPermittedNilOptionalFields()`, `validationFailureWritesNothingAndEmitsNothing()`; `Tests/WikiFSTests/AppendDerivedMarkdownHookTests.swift`: `afterInitialWritesCheckpointRunsExactlyOnce()`, `productionAfterInitialWritesHookIsNoOp()`, `injectedAfterInitialWritesFailureRollsBackDerivedVersion()`, `injectedAfterInitialWritesFailureRollsBackActivityPlan()`, `injectedAfterInitialWritesFailureRollsBackSourceVersionLink()`, `injectedAfterInitialWritesFailurePreservesPriorHead()`, `injectedAfterInitialWritesFailureRollsBackBlobAndRefcountEffects()`, `injectedAfterInitialWritesFailureEmitsNothing()`, `retryAfterInjectedPersistenceFailureSucceeds()`; `Tests/WikiFSTests/ExtractionCompatibilityWriterTests.swift`: `appendProcessedMarkdownDerivedCompatibilityRoutesThroughAppendDerivedMarkdown()`, `legacyTranscriptWriterRoutesThroughAppendDerivedMarkdown()`, `wikictlTranscriptCompatibilityRoutesThroughAppendDerivedMarkdown()` |
| AC-21 | `Tests/WikiFSTests/ExtractionWriterContractTests.swift`: `pdfQueueUsesCanonicalExtraction()`, `pdfSeedUsesCanonicalExtraction()`, `pdfReextractUsesCanonicalExtraction()`, `acpWriterPersistsTypedPlan()`, `anthropicWriterPersistsTypedPlan()`, `geminiWriterPersistsTypedPlan()`, `doclingWriterPersistsToolVersion()`, `pdf2mdWriterPersistsToolVersion()`, `htmlWriterPersistsToolPlan()`, `materializerSidecarUsesTypedTool()`, `appleTranscriptUsesTypedTool()`, `youtubeTranscriptUsesTypedTool()`, `rssTranscriptUsesTypedTool()`, `vimeoTranscriptUsesTypedTool()`, `wikictlTranscriptUsesTypedTool()` |
| AC-22 | `ExtractionProvenanceProjectionTests.swift`: `nilActivityOmitsProducer()`, `nilTechniqueOmitsProducer()`, `legacyBackendTechniqueDecodes()`, `legacyUnknownTechniqueStaysTechnical()`, `legacyAgentVersionIsModelOnlyForExtraction()`, `corruptPlanFallsBackToColumns()`, `userEditHasNoExtractionProjection()`, `sourceSeedHasNoExtractionProjection()`, `revertProjectsRevertOrigin()` |
| AC-23, AC-33, AC-38 | `Tests/WikiFSTests/SchemaV48MigrationTests.swift`: `freshDatabaseHasV48Schema()`, `upgradeV47PreservesRows()`, `upgradeStampsVersionAfterCommit()`, `failedUpgradeRollsBackAndRetries()`, `reopenV48IsIdempotent()`, `rewoundV48SchemaRepairsSafely()`, `freshAndUpgradeSchemasMatch()`, `fixtureFactoryUsesProductionV47SchemaAndClassifier()`, `classifierIdentifiesExactV47Shape()`, `classifierIdentifiesExactV48Shape()`, `staleShadowTableIsCleanedBeforeRebuild()`, `partialChatTurnsShapeIsRejected()`, `unknownChatTurnsDefinitionIsRejected()`, `migrationHooksRunExactlyOnceInDeclaredOrder()`, `afterShadowCleanupCheckpointObservesCleanShadowAndUncreatedFinalTables()`, `afterChatCopyCheckpointReceivesExactSourceAndCopiedCounts()`, `afterShadowCleanupInjectedFailureRollsBackAndRetainsVersion47()`, `afterChatCopyInjectedFailureRollsBackAndRetainsVersion47()`, `injectedCopyCountMismatchRollsBackMigration()`, `constraintInvalidCopiedRowRollsBackMigrationAndRetainsVersion47()`, `migrationHooksAreInternalAndProductionDefaultsAreNoOp()`, `productionForeignKeyCheckerRunsRealCleanPragmaWithEnforcementEnabled()`, `productionForeignKeyCheckerRejectsDisabledEnforcementAndRollsBackToV47()`, `retryAfterEnablingForeignKeyEnforcementSucceeds()`, `injectedForeignKeyResultMapsToTypedViolation()`, `injectedForeignKeyCheckerThrowRollsBackAllV48ObjectsAndRetainsVersion47()`, `retryAfterReplacingThrowingCheckerWithProductionCheckerSucceeds()`,  `injectedForeignKeyViolationRollbackRemovesAllV48ObjectsAndRetainsVersion47()`, `retryAfterInjectedForeignKeyViolationSucceeds()`, `injectedForeignKeyCheckerRunsAtExactFinalSchemaCheckpoint()`, `injectedForeignKeyCheckerStateDoesNotLeakAfterRollbackAndReopen()`, `productionForeignKeyCheckerIsRestoredPerStoreInstance()`, `fixtureFactoryUsesFreshProductionCheckerByDefault()`,  `workspaceRefSourcesHasCompositeForeignKey()`, `deletingWorkspaceRefCascadesStagedSources()`, `deletingReferencedSourceIsRestricted()`, `chatCheckRejectsNegativeInputTokens()`, `chatCheckRejectsNegativeOutputTokens()`, `chatCheckRejectsNegativeThoughtTokens()`, `chatCheckRejectsNegativeCacheReadTokens()`, `chatCheckRejectsNegativeCacheWriteTokens()`, `chatCheckRejectsCostWithoutCurrency()`, `chatChecksRejectFinishBeforeStart()`, `roleCheckRejectsUnknownValue()`, `foreignKeysAreEnabled()`, `pageVersionCascadeWorks()`, `readOnlyV47ReturnsCompatibilityEmptyValues()`, `readOnlyV48ReadsMetadata()`, `readOnlyOpenNeverMigrates()` |
| AC-24 | `Tests/WikiFSTests/MetadataEventEmissionTests.swift`: `chatClaimEmitsAfterCommit()`, `chatUsageEmitsAfterCommit()`, `chatFinishEmitsAfterCommit()`, `pageVersionAndSourcesEmitOnceAfterCommit()`, `rolledBackPageProvenanceEmitsNothing()`, `extractionWriteEmitsAfterCommit()`; extend `StoreEmissionExhaustivenessTests` with all new public methods. |
| AC-25 | `Tests/WikiFSTests/MetadataReadPoolTests.swift`: `readerSeesCommittedChatUsage()`, `readerSeesCommittedPageSources()`, `readerSeesCommittedExtractionPlan()`, `readerNeverSeesRolledBackMetadata()`, `concurrentMetadataReadsAndWritesDoNotCorrupt()` |
| AC-26 | `Tests/WikiFSAppTests/MetadataCrossProcessRefreshTests.swift`: `darwinPageChangeRehydratesSelectedPage()`, `darwinSourceChangeRehydratesSelectedSource()`, `darwinChatChangeRehydratesSelectedChat()`, `eventBusChangeAdvancesHydrationKey()`, `daemonSyncRefreshesLiveChatWithoutStoreRead()` |
| AC-27 | `Tests/WikiFSAppTests/MetadataRegressionTests.swift`: `pageCompareActionOpensExistingWindow()`, `sourceCompareActionOpensExistingSheet()`, `historyTabKeepsChronologyAndNavigation()`, `outlineTabKeepsExistingContent()` |
| AC-35 | `Tests/WikiFSTests/ProvenanceDeletionRestrictionTests.swift`: `oneReferenceReturnsNonEmptyCollectionWithOneBlocker()`, `multipleVersionsOfOnePageRemainDistinctBlockers()`, `multiplePagesReturnAllBlockers()`, `duplicateJoinedRowsDeduplicateByFullTypedIdentity()`, `blockersOrderByPageThenVersionThenSourceID()`, `typedBlockersIncludeSourcePageVersionAndOwningPageIDs()`, `restrictedDeletionDoesNotDeleteSourceOrAnyProvenanceEdge()`, `restrictedDeletionWritesNothingAndEmitsNothing()`, `unreferencedSourceDeletionSucceedsAndEmitsOnce()`, `fullBlockerCollectionMapsToIssue219ProvenanceCategory()`, `issue219MappingPreservesOrderAndEveryBlockerIdentity()`, `emptyBlockerCollectionCannotBeConstructed()` |
| AC-28 | CI or PR evidence records successful `make build`, `make test`, `swift build`, and `swift test` for every phase. |
| AC-29 | `Tests/WikiFSTests/Issue1005DocumentationAuditTests.swift`: `planIndexLinksIssue1005Plan()`, `trackedPlanContainsFinalDecisions()`, `progressEntryNamesCompletedPhases()` |
| AC-30 | `Tests/WikiFSAppTests/ACPWiringTests.swift`: `ingestRequestHintsResolveQueueSourceEnvironment()`, `largeSourceExecutorHintsResolveQueueSourceEnvironment()`; `Tests/WikiFSAppTests/ACPIngestPlanTests.swift`: `largeSourceExecutorProfilesResolveQueueSourceEnvironment()`; `Tests/WikiFSTests/AgentLauncherStageKeyDispatchTests.swift`: `ingestRequestSerializesSourceIDsInDeclaredQueueOrder()`; and the exact callable/branch mappings below. |

### New-function, method, hook, and branch coverage manifest

This manifest is normative. It uses explicit test names; an AC-range or broad category claim is not coverage.

- `InspectorTab.decodePersisted(_:)`: `legacyOutlineDecodes()`, `legacyHistoryDecodes()`, and `unknownValueDecodesAsMetadata()`.
- `InspectorTab.normalizedFallback(selection:availableTabs:)`: `normalizationKeepsAvailableSelection()`, `normalizationFallsBackToMetadata()`, `normalizationFallsBackToFirstWithoutMetadata()`, and `emptyTabsPureFallbackReturnsMetadataWhenReporterReturns()`.
- `InspectorTab.normalize(selection:availableTabs:reportProgrammerError:)`: `emptyTabsReportsProgrammerErrorExactlyOnce()` and `nonEmptyTabsDoNotReportProgrammerError()`.
- `PageMetadataProjection.make(input:)`: `pageProjectionOmitsSourceRowsWhenAbsent()`, `pageProjectionIncludesSourceRowsWhenPresent()`, `pageProjectionOrdersSourceRowsByRoleNameAndID()`, `pageProjectionSourceRowsCarryTypedSourceTargets()`, `pageProjectionShowsTechnicalHashWhenPresent()`, and `pageProjectionOmitsTechnicalHashWhenAbsent()`.
- `SourceMetadataProjection.make(input:)`: `sourceProjectionWithZeroAlternativesOmitsCompareAction()`, `sourceProjectionWithOneAlternativeOmitsCompareAction()`, `sourceProjectionWithTwoAlternativesIncludesCompareAction()`, `sourceProjectionIncludesModelWhenPresent()`, `sourceProjectionOmitsModelWhenAbsent()`, `sourceProjectionIncludesProviderWhenPresent()`, `sourceProjectionOmitsProviderWhenAbsent()`, `sourceProjectionIncludesToolVersionWhenPresent()`, `sourceProjectionOmitsToolVersionWhenAbsent()`, `sourceProjectionIncludesExtractionDateWhenPresent()`, `sourceProjectionOmitsExtractionDateWhenAbsent()`, `sourceProjectionIncludesSourceVersionWhenPresent()`, `sourceProjectionOmitsSourceVersionWhenAbsent()`, `sourceProjectionIncludesExtractionVersionWhenPresent()`, `sourceProjectionOmitsExtractionVersionWhenAbsent()`, `sourceProjectionIncludesHashWhenPresent()`, and `sourceProjectionOmitsHashWhenAbsent()`.
- `ChatMetadataProjection.make(input:)`: `chatProjectionLegacyRowOmitsUnavailableUsageRows()`, `chatProjectionMissingStartOmitsDuration()`, `chatProjectionMissingFinishOmitsDuration()`, `chatProjectionCompleteTimesShowsDuration()`, `chatProjectionShowsInputTokensWhenPresent()`, `chatProjectionShowsOutputTokensWhenPresent()`, `chatProjectionShowsComputedTotalWhenInputAndOutputPresent()`, `chatProjectionOmitsTotalWhenInputMissing()`, `chatProjectionOmitsTotalWhenOutputMissing()`, `chatProjectionShowsCacheReadWhenPresent()`, `chatProjectionShowsCacheWriteWhenPresent()`, `chatProjectionShowsCostForMatchingCurrency()`, `chatProjectionOmitsCostForMixedCurrency()`, `chatProjectionShowsStatusWhenPresent()`, `chatProjectionOmitsStatusWhenUnavailable()`, and `metadataProjectionUsesStableEmptyStateWhenNoRows()`.
- `ChatMetadataProjection.mergedUsage(persisted:live:)` and `mergedUsages(persisted:live:)`: `liveTurnReplacesSamePersistedTurn()`, `persistedCatchUpDoesNotDoubleCount()`, `differentTurnRemainsHistorical()`, and `terminalPersistedValueReplacesLiveOverlay()`.
- `MetadataValueRenderer.presentation(for:locale:calendar:)`: `rendersText()`, `rendersDate()`, `rendersByteCount()`, `rendersInteger()`, `rendersTokenCount()`, `rendersDuration()`, `rendersIdentifier()`, `rendersLink()`, `rendersAction()`, and `usesTabularDigitsForCounts()`.
- `MetadataActionRouter`: `opensTypedPageTarget()`, `opensTypedSourceTarget()`, `opensTypedChatTarget()`, `selectsExactActivityTarget()`, `opensValidatedURLTarget()`, `opensPageVersionComparison()`, `opensSourceExtractionComparison()`, `copiesExactIdentifier()`, `missingSubjectReturnsNoOp()`, `pageCompareUnavailableReturnsNoOp()`, `sourceCompareUnavailableReturnsNoOp()`, `unsafeURLIsRejectedWithoutOpen()`, `copyFailureReturnsTypedError()`, `targetOpenFailureReturnsTypedError()`, and `explicitNoOpPerformsNoSideEffect()`. Issue #219 owns deletion-impact navigation.
- `chatTurnUsage(chatID:turnID:)`: `chatTurnUsageReturnsNilForMissingTurn()`, `chatTurnUsageDecodesEveryField()`, and `chatTurnUsageDecodesLegacyAllNilRow()`.
- `latestChatTurnUsage(chatID:)`: `latestChatTurnUsageReturnsNilForEmptyChat()`, `latestChatTurnUsageUsesHighestDurableOrdinal()`, and `latestChatTurnUsageReturnsLatestLegacyAllNilRow()`.
- `chatUsageSummary(chatID:)`: `chatUsageSummaryReturnsEmptySummaryForEmptyChat()`, `chatUsageSummaryAggregatesInputTokens()`, `chatUsageSummaryAggregatesOutputTokens()`, `chatUsageSummaryAggregatesThoughtTokens()`, `chatUsageSummaryAggregatesCacheReadTokens()`, `chatUsageSummaryAggregatesCacheWriteTokens()`, `chatUsageSummaryIgnoresLegacyAllNilRows()`, `chatUsageSummaryAggregatesMatchingCurrencyCost()`, `chatUsageSummaryOmitsMixedCurrencyCost()`, `chatUsageSummaryOmitsCostWithoutCurrency()`, `chatUsageSummaryRejectsCounterOverflow()`, and `chatUsageSummaryRejectsMalformedDecimal()`.
- `updatePersistedChatTurnUsage(...)`: `usageUpdateAcceptsClaimedTurnWithMatchingClaim()`, `usageUpdateAcceptsProviderSubmittedTurnWithMatchingClaim()`, `usageUpdateRejectsCompletedTurn()`, `usageUpdateRejectsFailedTurn()`, `usageUpdateRejectsCancelledTurn()`, `usageUpdateRejectsStaleClaim()`, and `rejectedStoreTransitionWritesNothingAndEmitsNothing()`.
- `finishPersistedChatTurn(...)`: `finishClaimedTurnPersistsTerminalOutcomeAndFinalUsageAtomically()`, `finishProviderSubmittedTurnPersistsTerminalOutcomeAndFinalUsageAtomically()`, `laterDifferentTerminalOutcomePreservesWinnerState()`, `laterDifferentTerminalOutcomePreservesWinnerFinishedAt()`, `laterDifferentTerminalOutcomePreservesWinnerMessageAndError()`, `laterDifferentTerminalOutcomePreservesWinnerProviderAndModel()`, and `laterDifferentTerminalOutcomePreservesWinnerEveryUsageField()`.
- `ChatTurnUsageAccumulator` and controller `finishTurnIfCurrent(...)`: `streamedCumulativeUsageProducesTurnDelta()`, `finalOnlyUsagePersists()`, `mixedStreamAndFinalUsesGreatestCounters()`, `missingUsageLeavesColumnsNil()`, `counterResetRetainsPriorValue()`, `decreasingCounterIsRejected()`, `currencyChangeClearsCostOnly()`, `cacheReadAndWritePersist()`, `thoughtTokensPersist()`, `warmSessionSubtractsBaseline()`, `staleGenerationUsageIsRejected()`, `staleGenerationTerminalIsRejected()`, `wrongTurnEventIsRejected()`, and `oldClaimUsageIsRejected()`.
- `createPageVersionWithProvenance(on:request:)`: `transactionHelperSuccessWritesVersionActivityRefsAllEdgesAndReturnsEventPayload()`, `transactionHelperSQLFailureRollsBackEveryEffectAndEmitsNothing()`, `missingSourceRollsBackVersionActivityMirrorRefHeadBlobAllEdgesAndEvent()`, `duplicateExactSourceRoleInputWritesNothingAndEmitsNothing()`, and `sameSourceWithDifferentRolesIsAccepted()`.
- Compatibility role decoding: `compatibilityInvalidRoleWritesNothingAndEmitsNothing()` and `compatibilityEmptyRoleWritesNothingAndEmitsNothing()`.
- `PageVersionSourceInput.agentIngest(sourceIDs:)`: `agentIngestMarksPrimaryAndSupporting()` and `agentIngestEnvironmentUsesAssignedPrimaryAndExplicitRolesAddOnly()`.
- `ArgumentParser.decodePageVersionSources(_:)`: `wikictlAddDecodesSourceRoles()`, `rejectsUnknownRoleAtBoundary()`, and `wikictlRejectsEmptySourceRole()`.
- `PageCommand.mergedAgentIngestProvenance(_:environment:)`: `agentIngestEnvironmentUsesAssignedPrimaryAndExplicitRolesAddOnly()`.
- `AgentLauncher.ingestProvenanceEnvironment(for:)`: `ingestRequestSerializesSourceIDsInDeclaredQueueOrder()`.
- `AgentLauncher.ingestProvenanceProviderHints(for:addingTo:)` and the provider-hint `env.` boundary: `ingestRequestHintsResolveQueueSourceEnvironment()`.
- Large-source `runACPIngestPlannerExecutors` planner/executor/finalizer hints and serial fallback-profile injection: `largeSourceExecutorHintsResolveQueueSourceEnvironment()` and `largeSourceExecutorProfilesResolveQueueSourceEnvironment()`.
- All page-version creation seams: `everyCreationSeamUsesTransactionalProvenanceHelper()`, plus `createEmptyPageHasNoSources()`, `mainUpdateWritesSourcesAtomically()`, `casSuccessWritesSources()`, `casFailureWritesNothing()`, `workspaceExistingPageWritesEdges()`, `workspaceMintCopiesStagedSources()`, `workspaceMergeUnionsParentEdges()`, `workspaceRefreshUnionsParentEdges()`, `workspaceConflictResolutionUnionsEdges()`, and `restoreCopiesTargetEdges()`.
- `pageVersionSources(versionID:)`: `pageVersionSourcesReturnsEmptyForMissingVersion()`, `pageVersionSourcesReturnsEmptyForLegacyVersion()`, `pageVersionSourcesReturnsTypedResults()`, `pageVersionSourcesOrdersByRoleThenDisplayNameThenID()`, and `pageVersionSourcesThrowsTypedCorruptionForUnknownRole()`.
- `pageHeadSources(pageID:)`: `pageHeadSourcesReturnsEmptyForMissingPage()`, `pageHeadSourcesReturnsEmptyForLegacyHead()`, `pageHeadSourcesResolvesCurrentHeadNotAlternative()`, and `pageHeadSourcesThrowsTypedCorruptionForUnknownRole()`.
- `sourceReferencingPageVersions(sourceID:)`: `sourceReferencingPageVersionsReturnsTypedOrderedIDs()`, `sourceReferencingPageVersionsReturnsEmptyForUnreferencedSource()`, and `sourceReferencingPageVersionsReturnsEmptyForMissingSource()`.
- `NonEmptyProvenanceDeletionBlockers`: `oneReferenceReturnsNonEmptyCollectionWithOneBlocker()`, `multipleVersionsOfOnePageRemainDistinctBlockers()`, `multiplePagesReturnAllBlockers()`, `duplicateJoinedRowsDeduplicateByFullTypedIdentity()`, `blockersOrderByPageThenVersionThenSourceID()`, `typedBlockersIncludeSourcePageVersionAndOwningPageIDs()`, and `emptyBlockerCollectionCannotBeConstructed()`.
- Source deletion restriction and #219 mapping: `restrictedDeletionDoesNotDeleteSourceOrAnyProvenanceEdge()`, `restrictedDeletionWritesNothingAndEmitsNothing()`, `unreferencedSourceDeletionSucceedsAndEmitsOnce()`, `fullBlockerCollectionMapsToIssue219ProvenanceCategory()`, and `issue219MappingPreservesOrderAndEveryBlockerIdentity()`.
- `ExtractionActivityPlanCodec`: `currentVersionRoundTripsEveryField()`, `legacyBackendModelShapeDecodes()`, `unsupportedVersionThrowsTypedError()`, `malformedJSONFallsBackAndRetainsNormalizedColumns()`, `nilOptionalFieldsRoundTrip()`, and `bytelessOEmbedSyntheticToolRoundTrips()`.
- `appendDerivedMarkdown(...)`: `persistsTypedProducerAndOrigin()`, `persistsPresentSourceVersion()`, `persistsAbsentSourceVersion()`, `newDerivedVersionBecomesActiveAndPriorVersionRemainsAlternative()`, `rejectsNonDerivedOrigin()`, `rejectsModelWithoutProviderBackedProducer()`, `rejectsProviderFieldsForLocalTool()`, `rejectsToolVersionForBackend()`, `rejectsForeignSourceVersion()`, `rejectsMissingSource()`, `acceptsPermittedNilOptionalFields()`, and `validationFailureWritesNothingAndEmitsNothing()`.
- `AppendDerivedMarkdownHooks.afterInitialWrites`: `afterInitialWritesCheckpointRunsExactlyOnce()`, `productionAfterInitialWritesHookIsNoOp()`, `injectedAfterInitialWritesFailureRollsBackDerivedVersion()`, `injectedAfterInitialWritesFailureRollsBackActivityPlan()`, `injectedAfterInitialWritesFailureRollsBackSourceVersionLink()`, `injectedAfterInitialWritesFailurePreservesPriorHead()`, `injectedAfterInitialWritesFailureRollsBackBlobAndRefcountEffects()`, `injectedAfterInitialWritesFailureEmitsNothing()`, and `retryAfterInjectedPersistenceFailureSucceeds()`.
- Extraction compatibility paths: `appendProcessedMarkdownDerivedCompatibilityRoutesThroughAppendDerivedMarkdown()`, `legacyTranscriptWriterRoutesThroughAppendDerivedMarkdown()`, `wikictlTranscriptCompatibilityRoutesThroughAppendDerivedMarkdown()`, `legacyBackendTechniqueDecodes()`, `legacyUnknownTechniqueStaysTechnical()`, `legacyAgentVersionIsModelOnlyForExtraction()`, `corruptPlanFallsBackToColumns()`, `userEditHasNoExtractionProjection()`, `sourceSeedHasNoExtractionProjection()`, and `revertProjectsRevertOrigin()`.
- Extraction writer seams: `pdfQueueUsesCanonicalExtraction()`, `pdfSeedUsesCanonicalExtraction()`, `pdfReextractUsesCanonicalExtraction()`, `acpWriterPersistsTypedPlan()`, `anthropicWriterPersistsTypedPlan()`, `geminiWriterPersistsTypedPlan()`, `doclingWriterPersistsToolVersion()`, `pdf2mdWriterPersistsToolVersion()`, `htmlWriterPersistsToolPlan()`, `materializerSidecarUsesTypedTool()`, `appleTranscriptUsesTypedTool()`, `youtubeTranscriptUsesTypedTool()`, `rssTranscriptUsesTypedTool()`, `vimeoTranscriptUsesTypedTool()`, and `wikictlTranscriptUsesTypedTool()`.
- Extraction projection tool cases: `projectsACPBackendProviderAndModel()`, `projectsAnthropicBackendProviderAndModel()`, `projectsGeminiBackendProviderAndModel()`, `projectsDoclingToolVersion()`, `projectsPdf2mdToolVersion()`, `projectsHTMLToolAndBackend()`, `projectsTranscriptTool()`, and `projectsBytelessOEmbedSyntheticTool()`.
- `classifyChatTurnsSchema(...)` and `SchemaV48FixtureFactory`: `fixtureFactoryUsesProductionV47SchemaAndClassifier()`, `classifierIdentifiesExactV47Shape()`, `classifierIdentifiesExactV48Shape()`, `partialChatTurnsShapeIsRejected()`, and `unknownChatTurnsDefinitionIsRejected()`.
- `migrateV47ToV48(in:hooks:foreignKeyChecker:)`: `upgradeV47PreservesRows()`, `upgradeStampsVersionAfterCommit()`, `staleShadowTableIsCleanedBeforeRebuild()`, `injectedCopyCountMismatchRollsBackMigration()`, `constraintInvalidCopiedRowRollsBackMigrationAndRetainsVersion47()`, `injectedForeignKeyViolationRollbackRemovesAllV48ObjectsAndRetainsVersion47()`, and `retryAfterInjectedForeignKeyViolationSucceeds()`.
- `SchemaV48MigrationHooks.afterShadowCleanup`: `afterShadowCleanupCheckpointObservesCleanShadowAndUncreatedFinalTables()` and `afterShadowCleanupInjectedFailureRollsBackAndRetainsVersion47()`.
- `SchemaV48MigrationHooks.afterChatCopy`: `afterChatCopyCheckpointReceivesExactSourceAndCopiedCounts()` and `afterChatCopyInjectedFailureRollsBackAndRetainsVersion47()`.
- Migration hook order/defaults: `migrationHooksRunExactlyOnceInDeclaredOrder()` and `migrationHooksAreInternalAndProductionDefaultsAreNoOp()`.
- `SchemaForeignKeyChecker.productionDefault.verifyEnforcement(_:)` and `.check(_:)`: `productionForeignKeyCheckerRunsRealCleanPragmaWithEnforcementEnabled()`, `productionForeignKeyCheckerRejectsDisabledEnforcementAndRollsBackToV47()`, `retryAfterEnablingForeignKeyEnforcementSucceeds()`, `productionForeignKeyCheckerIsRestoredPerStoreInstance()`, and `fixtureFactoryUsesFreshProductionCheckerByDefault()`.
- Injected `SchemaForeignKeyChecker.check(_:)` returned-violation branch: `injectedForeignKeyResultMapsToTypedViolation()`, `injectedForeignKeyCheckerRunsAtExactFinalSchemaCheckpoint()`, `injectedForeignKeyViolationRollbackRemovesAllV48ObjectsAndRetainsVersion47()`, `retryAfterInjectedForeignKeyViolationSucceeds()`, and `injectedForeignKeyCheckerStateDoesNotLeakAfterRollbackAndReopen()`.
- Injected `SchemaForeignKeyChecker.check(_:)` thrown-failure branch: `injectedForeignKeyCheckerThrowRollsBackAllV48ObjectsAndRetainsVersion47()` and `retryAfterReplacingThrowingCheckerWithProductionCheckerSucceeds()`.
- V48 constraint and FK branches: `workspaceRefSourcesHasCompositeForeignKey()`, `deletingWorkspaceRefCascadesStagedSources()`, `deletingReferencedSourceIsRestricted()`, `chatCheckRejectsNegativeInputTokens()`, `chatCheckRejectsNegativeOutputTokens()`, `chatCheckRejectsNegativeThoughtTokens()`, `chatCheckRejectsNegativeCacheReadTokens()`, `chatCheckRejectsNegativeCacheWriteTokens()`, `chatCheckRejectsCostWithoutCurrency()`, `chatChecksRejectFinishBeforeStart()`, `roleCheckRejectsUnknownValue()`, `foreignKeysAreEnabled()`, and `pageVersionCascadeWorks()`.
- Hydration callables: `subjectChangeCancelsPriorHydration()`, `cancelledHydrationCannotPublish()`, `failedHydrationPublishesTypedFailure()`, `inMemoryHydrationUsesStoreFallback()`, and `fileHydrationUsesReadPool()`.
- `MetadataHydrator.hydrate(subject:operation:publish:)` and `MetadataHydrationReadPath.resolve(readPoolAvailable:)`: `subjectChangeCancelsPriorHydration()`, `cancelledHydrationCannotPublish()`, `failedHydrationPublishesTypedFailure()`, `inMemoryHydrationUsesStoreFallback()`, and `fileHydrationUsesReadPool()`.
- `MetadataLayout.usesStackedRows(for:)` and `MetadataMetrics.stackedRowThreshold`: `hostedInspectorAt180UsesStackedRows()`, `hostedInspectorAt500UsesGridRows()`, and `hostedThresholdUsesStackedBelowAndGridAt300()`.
- Renderer/action boundary and documentation audits: `renderingMetadataPerformsNoStoreRead()`, `inspectorTypesDoNotReferenceWikiStore()`, `planIndexLinksIssue1005Plan()`, `trackedPlanContainsFinalDecisions()`, and `progressEntryNamesCompletedPhases()`.
- Event/read-pool/refresh compatibility: `pageVersionAndSourcesEmitOnceAfterCommit()`, `rolledBackPageProvenanceEmitsNothing()`, `extractionWriteEmitsAfterCommit()`, `readerSeesCommittedChatUsage()`, `readerSeesCommittedPageSources()`, `readerSeesCommittedExtractionPlan()`, `readerNeverSeesRolledBackMetadata()`, `darwinPageChangeRehydratesSelectedPage()`, `darwinSourceChangeRehydratesSelectedSource()`, `darwinChatChangeRehydratesSelectedChat()`, and `daemonSyncRefreshesLiveChatWithoutStoreRead()`.

At exact-head review, enumerate every new or changed callable from the diff. Add every missing callable and branch to this manifest and the AC matrix before approval.

## Review Strategy

Use this exact-head audit and repair loop for every phase and for the final issue branch:

1. Fetch the remote branch.
2. Record the exact head with `git rev-parse HEAD`.
3. Confirm the branch is not `main`.
4. Run `git status --short` and identify all changed files.
5. Review the diff from the phase base to the recorded head.
6. Run the four required build and test commands.
7. Run targeted tests for that phase.
8. Search for raw `PageID` and `SourceID` comparisons in new provenance code.
9. Search for lifecycle writes outside `DaemonChatController`.
10. Search for store I/O in inspector and metadata renderer files.
11. Search for new public store methods missing from `StoreEmissionExhaustivenessTests`.
12. Search the schema ladder and confirm v48 appears before the catch-all.
13. Compare fresh and upgraded schema output.
14. Review SwiftUI code with `swiftui-pro`, macOS layout with `macos-design`, and type hierarchy with `typography-designer`.
15. Review actor isolation and cancellation with `swift-concurrency-pro`.
16. Review tests with `swift-testing-pro`.
17. Review store access with `sqlite-concurrency`.
18. Fix every finding on the same branch.
19. Record the new exact head.
20. Repeat steps 4 through 17 against the new head.
21. Stop only when the re-audit has no unresolved finding and all commands pass.

The reviewer must verify macOS 15 and Swift 6.0 compatibility. Ignore skill advice that requires iOS 26, Swift 6.2, Xcode projects, macros, or Xcode-only build behavior.

Manual final checks:

1. Select a page, source, and persisted chat while the inspector remains open.
2. Switch each valid tab and reopen the app.
3. Resize from 180 to 500 points.
4. Run, cancel, fail, stop, and retry chat turns while Metadata is visible.
5. Kill and restart the daemon during a turn.
6. Re-extract each supported source type from app and daemon paths.
7. Ingest one source into a new page and several sources into one page.
8. Restore a page and inspect copied source provenance.
9. Run a `wikictl` write while the app displays the same subject.
10. Use VoiceOver and keyboard navigation for all rows and actions.
11. Capture SwiftUI runtime logs and confirm there is no state mutation during view update.

## Documentation Strategy

The final phase updates tracked documentation. Do not update tracked files while preparing this handoff artifact.

1. Replace `plans/issue-1005-selected-item-metadata.md` with the final implemented design and actual type names.
2. Add or update the issue #1005 entry in `PLAN.md` with a link to the tracked plan and phase status.
3. Add feature progress records under `progress/`. Include completed phases, migration v48, tests, and exact-head review evidence.
4. Keep bug-only notes out of `PLAN.md` and `PROGRESS.md`.
5. Use STE-flavored prose in the plan, progress records, PR descriptions, and review notes.
6. Document compatibility behavior for v47 read-only clients and legacy extraction rows.
7. Document the source deletion `RESTRICT` contract and typed provenance blocker identity. Cite open issue #219 as the owner of deletion-impact analysis, incoming links and bookmarks, link-to-text conversion, required bookmark removal, blocker presentation, and navigation. State that provenance is an additional incoming-reference category supplied by issue #1005.

## Risks/Blockers/Required Decisions

### Resolved decisions

- Use the existing durable `chat_turns` lifecycle keyed by `ChatTurnID`.
- `DaemonChatController` is the sole lifecycle writer.
- `claimed_at` is the exact start time.
- Provider and model snapshot at claim.
- Usage is a cumulative-provider snapshot converted to a per-turn delta.
- The first valid terminal transition wins.
- Retry uses a new `ChatTurnID`.
- Schema version 48 contains both chat metadata and provenance tables.
- Page-source provenance is mandatory and append-only.
- Source deletion uses `RESTRICT` while provenance exists and returns typed blocker identity for issue #219.
- Extraction model data comes from existing agent/activity persistence.
- Tool versions remain separate from provider models.
- Inspector tabs use ordered `[InspectorTab]`.
- Detail surfaces own asynchronous hydration and cancellation.
- All five phases are required.

### Implementation risks and required mitigations

1. **`chat_turns` rebuild risk:** v48 rebuilds a live table. Verify FK enforcement before the immediate transaction. Use one immediate transaction, row-count checks, the real production FK checker, distinct typed errors for disabled enforcement, returned violations, and thrown checker causes, plus failure-retry tests. Never toggle FK enforcement inside the transaction.
2. **Warm-session usage risk:** cumulative session totals can double count. Capture a baseline before each submit and persist only the nonnegative turn delta.
3. **Terminal race risk:** completion and transport close can race. Use controller generation, turn, claim, and terminal-state guards plus a conditional store update.
4. **Workspace staged-page risk:** no `PageVersionID` exists before merge. Persist typed staged provenance in `workspace_ref_sources` and copy it atomically at mint.
5. **Dependency on open issue #219:** provenance `RESTRICT` can block source deletion. Issue #1005 must expose typed source, page-version, and owning-page identities without deleting edges. Issue #219 must merge those identities into its deletion-impact analysis beside incoming links and incoming bookmarks, then own warnings, link-to-text conversion, required bookmark removal, blocker presentation, and navigation. Do not ship a separate deletion UI in issue #1005.
6. **Legacy extraction ambiguity:** old technique strings may not identify a model. Show only verified fields and place unknown technique in Technical.
7. **Cross-process freshness risk:** `wikid` has no in-process event bus with the app. Keep Darwin notification and model reload as the durable invalidation path.
8. **SwiftUI stale state risk:** subject changes can finish old reads late. Use `.task(id:)`, cancellation checks, and typed hydration keys.
9. **Schema drift risk:** fresh and upgraded SQL can diverge. Keep shared table builders and assert normalized schema equality.
10. **SwiftPM compatibility risk:** do not use Xcode-only macros or APIs. Run both Make and bare SwiftPM commands in every phase.

There are no ordinary product or architecture decisions left for the implementer. A newly discovered constraint that conflicts with this plan requires a documented plan amendment and reviewer approval before code proceeds.
