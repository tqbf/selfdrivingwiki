# App–daemon wire contract over gRPC

Status: **first slice implemented, families NOT migrated** (the XPC
workload route stays production until family parity passes — see
`plans/daemon-only-access.md` and the step list below).

## What this is

The language-neutral contract between the app and the bundled `wikid`
daemon: Protocol Buffers schemas under `Protocol/app-daemon/proto`, served
by the daemon over a Unix domain socket with gRPC (gRPC Swift 2 + its POSIX
HTTP/2 transport), consumed by the app through typed session adapters, and
proven language-neutral by a Rust peer (tonic/prost) that speaks the same
schemas in both roles.

Design decisions and review gates live in the approved plan; this doc maps
them onto the code. The language-neutral semantic rules and transport
boundaries are stated next to the schemas in
`Protocol/app-daemon/README.md`.

## First slice (this change)

- **Schemas** `Protocol/app-daemon/proto/wikid/appdaemon/v1/`:
  `AdmitSession`, `GetCapabilities`, `ListWikis`, `SubscribeEvents`
  (registry family only; store/queue/chat numbers reserved). Versioned
  package `wikid.appdaemon.v1`; the error taxonomy is a versioned
  `ErrorDetails` message with stable numeric codes carried in gRPC status
  details.
- **Daemon side** `Sources/WikiDaemonGRPC/`: the listener (`g/s` under the
  App Group container, mode-0700 directory, flock guard before bind, no
  TCP), the session store (XPC-issued 256-bit credentials, 30 s bootstrap
  window, idempotent exchange, revocation terminating streams), the
  service provider, and the registry event hub fed at the same call site
  as the XPC firehose.
- **XPC keeps admission**: one new selector (`grpcAdmission`) hands out the
  endpoint path + bootstrap credential, bound to the XPC connection; XPC
  invalidation revokes the session. No workload crosses XPC beyond what
  already did.
- **Client side** `Sources/WikiDaemonGRPC/AppDaemonSessionClient.swift` +
  `Sources/WikiCtlCore/DaemonGRPCSession.swift`: bootstrap → capabilities
  gate → typed calls; explicit per-call deadlines; client-side 4 MiB
  bound; no auto-retries.
- **Rust peer** `tools/app-daemon-interop/`: `serve` (fixture server for
  the Swift client) and `probe` (validates the Swift server), both driven
  by the shared corpus `Protocol/app-daemon/fixtures/corpus.json`.

## Verification (all local, all green)

| Gate | Command |
|---|---|
| Session store semantics + typed-failure mapping | `swift test --filter AppDaemonSessionStoreContractTests` |
| Live socket: ownership, stale recovery, round trip, revocation | `make test-app-daemon-grpc` |
| Rust↔Swift both roles over the corpus | `make test-app-daemon-interop` |
| Schema drift / lint / breaking / negative breaking edit | `make check-app-daemon-proto` |
| Bootstrap-only XPC surface + schema coverage | `swift test --filter 'AppDaemonProtoCoverageTests|AppDaemonBootstrapOnlyContractTests'` |

`make test-app-daemon-interop` fails when the peer binary is missing for
the selected tier — build it first with `make app-daemon-interop`.

## What is deliberately NOT here yet

- **Family migration** (store, queue, chat) — step 3 of the plan. The
  subscriber-cursor replacement, per-family adapters, parity fixtures, and
  the development switch belong to that step.
- **Cutover** — step 4. The legacy workload selectors stay on XPC; the
  gRPC surface serves the first-slice read/event family only.
- **Signed smoke + paired benchmark** — the make targets exist
  (`test-signed-app-daemon-grpc`, `benchmark-app-daemon-grpc`) and their
  harness scripts document the local procedure; they require a developer
  Mac with `signing/local.config` and a quiet machine. Cutover requires
  their recorded evidence (AC.1, AC.6).

## Toolchain pins

`Protocol/app-daemon/tools.lock.json` pins protoc 36.2, Buf 1.75.0,
swift-protobuf 1.41.0, grpc-swift-protobuf 2.5.0 with SHA-256 digests;
`make app-daemon-tools` installs and verifies them. The Rust toolchain is
pinned by `tools/app-daemon-interop/rust-toolchain.toml` (1.96.0) and
crate versions by the committed `Cargo.lock` (`cargo build --locked`).
The baseline descriptor image `Protocol/app-daemon/baseline/image.binpb`
is the breaking-check gate — regenerate only after compatibility review.

## Step 2 — workload contract design

> Authored by the OpenAI-family executor (gpt-6.2-sol) from the approved
> plan; integrated by the GLM executor. Counts and mappings are grounded
> in the sources cited inline.

### Inventory → schema coverage ledger

**151 store workload operations, 159 store operation tags in all.**
Counting the request and reply declarations independently yields 37
pairs in `Sources/WikiDaemonContract/DaemonStoreOpsSmall.swift:17–528`,
25 in `DaemonStoreOpsList.swift:87–536`, 39 in `DaemonStoreOpsBlob.swift:18–1244`,
and 50 in `DaemonStoreOpsEvents.swift:21–1305`. The blob count includes
the `DaemonSourceContentRequest` enum at line 1012. The registry adds
four staging, two mutation/session, and two event-tier operations
(`DaemonStoreWire.swift:81–119,367–386`). The header's "7" is stale:
`upgradeSearchIndex` is the eighth. Count DTO pairs and registry tags
separately.

`Sources/WikiDaemonContract/WikiDaemonProtocol.swift:13–208` declares
**40 selectors**: 38 production workload selectors, one production
admission selector, and one test-only probe. The reverse callback at
line 297 is additional. Each unary RPC below has an `<Rpc>Request` and
`<Rpc>Reply` unless noted. The ledger key names the coverage-test entry.
Each workload entry requires a success fixture and the applicable
negative or event fixtures listed here.

| Family | XPC selector | v1 RPC / message | Corpus coverage | Ledger key |
|---|---|---|---|---|
| Registry | `listWikis` | `ListWikis` (existing) | MRU, empty, optional home page | `registry.listWikis` |
| Registry | `createWiki` | `CreateWiki` | Assigned descriptor, default name, created event, failure | `registry.createWiki` |
| Registry | `deleteWiki` | `DeleteWiki` | Removed identity, deleted event without name, missing wiki | `registry.deleteWiki` |
| Registry | `renameWiki` | `RenameWiki` | Same identity, renamed event, missing wiki | `registry.renameWiki` |
| Registry | `resolveWiki` | `ResolveWiki` | ID, name, collision precedence, miss | `registry.resolveWiki` |
| Lifecycle | `openStore` | `OpenStore` | First and repeated open, missing wiki, open failure | `lifecycle.openStore` |
| Lifecycle | `closeStore` | `CloseStore` | Release without forcing an in-use store closed | `lifecycle.closeStore` |
| Lifecycle | `changeToken` | `GetStoreChangeToken` | Present token vs unavailable token | `lifecycle.changeToken` |
| Store | `storeOperation` | `GetPage`, `ListPages`, `UpsertPage`, `StoreSmall`, `StoreList`, `StoreBlob`, `StoreMutation`, plus infrastructure below | One typed pair per operation, chunk and outcome sequences, typed failures, post-commit events | `store.<DaemonStoreOperation case>` |
| Search | `search` | `Search`, `Autocomplete` | Both modes, empty hits, kind filter, distance bounds, wrong wiki | `search.search`, `search.autocomplete` |
| Events | `registerEventSink` | `SubscribeEvents` / `SubscribeEventsRequest` | Family selection, unsupported family, cancellation and revocation | `events.registerEventSink` |
| Events | `WikiDaemonEventSink.deliverEvent` (reverse) | `DaemonEvent` / `RegistryEvent`, `StoreEvent`, `QueueEvent`, `ChatEvent`, `SearchUpgradeProgress` | Each live event variant, unknown tag; no XPC object on wire | `events.deliverEvent` |
| Queue | `queueSnapshot` | `GetQueueSnapshot` | Active/recent order, run states, empty and paged reads | `queue.queueSnapshot` |
| Queue | `enqueueItem` | `EnqueueItem` | Typed payload, optional dedupe key, assigned item ID | `queue.enqueueItem` |
| Queue | `cancelItem` | `CancelItem` | Item identity and cancelled event | `queue.cancelItem` |
| Queue | `cancelAllInFlight` | `CancelAllInFlight` | Zero and nonzero affected counts | `queue.cancelAllInFlight` |
| Queue | `retryItem` | `RetryItem` | Failed item retried, invalid state | `queue.retryItem` |
| Queue | `pauseQueue` | `PauseQueue` | Queue kind and paused event | `queue.pauseQueue` |
| Queue | `resumeQueue` | `ResumeQueue` | Queue kind and running event | `queue.resumeQueue` |
| Queue | `haltQueue` | `HaltQueue` | Halt distinct from pause, affected live work | `queue.haltQueue` |
| Queue | `reorderItem` | `ReorderItem` | Anchor present vs absent, reordered event | `queue.reorderItem` |
| Queue | `hasActiveWork` | `HasActiveWork` | True and false for a specified wiki | `queue.hasActiveWork` |
| Queue | `waitForCompletion` | `SubscribeEvents` / `QueueEvent` terminal variants | Success, failure, cancellation; already-terminal and race parity in step 3 | `queue.waitForCompletion` |
| Queue | `loadTranscript` | `LoadQueueTranscript` | Empty and multi-page typed transcript | `queue.loadTranscript` |
| Queue | `loadAllActivitySnapshots` | `LoadQueueActivitySnapshots` | Empty and multi-page activity reads | `queue.loadAllActivitySnapshots` |
| Queue | `loadQueueReport` | `LoadQueueReport` | Loaded, not reported, unavailable | `queue.loadQueueReport` |
| Queue | `loadQueueReportSummaries` | `LoadQueueReportSummaries` | Bounded item batch, partial matches, unavailable | `queue.loadQueueReportSummaries` |
| Queue | `queueOwnershipStatus` | `GetQueueOwnershipStatus` | Epoch and each host state | `queue.queueOwnershipStatus` |
| Queue | `relinquishQueue` | `RelinquishQueue` | Completed transition, stale epoch, active-item blockers | `queue.relinquishQueue` |
| Chat | `startChat` | `StartChat` | First message, optional overrides, assigned chat ID | `chat.startChat` |
| Chat | `submitChatTurn` | `SubmitChatTurn` | Draft and existing target, typed context, returned chat ID | `chat.submitChatTurn` |
| Chat | `continueChat` | `ContinueChat` | Persisted target and missing chat | `chat.continueChat` |
| Chat | `sendChatMessage` | `SendChatMessage` | Live follow-up and invalid session state | `chat.sendChatMessage` |
| Chat | `stopChat` | `StopChat` | Scoped stop and resulting lifecycle event | `chat.stopChat` |
| Chat | `chatSessionState` | `GetChatSessionState` | Typed live and persisted-only views | `chat.chatSessionState` |
| Chat | `chatDiagnosticSnapshot` | `GetChatDiagnostics` | Process vs chat scope, redaction, unsupported revision | `chat.chatDiagnosticSnapshot` |
| Chat | `resetChatDiagnostics` | `ResetChatDiagnostics` | Explicit acknowledgement, rotation, stale acknowledgement | `chat.resetChatDiagnostics` |
| Chat | `resolveChatPermission` | `ResolveChatPermission` | Approve, reject, stale request | `chat.resolveChatPermission` |
| Chat | `setChatConfigOption` | `SetChatConfigOption` | Valid option/value, invalid option/value | `chat.setChatConfigOption` |
| Admission | `grpcAdmission` | **Retain XPC**. Existing `AdmitSession` and `GetCapabilities` follow admission | Exchange, capability mismatch, revocation; test XPC separately | `admission.grpcAdmission` |
| Test only | `runSignedExtractorProbe` | **Excluded**. No production RPC, message, or capability | Signed smoke uses the separate test-only bootstrap interface in the `WIKIFS_SIGNED_PROBE=1` fixture build | `excluded.signedExtractorProbe` |

Test-only bootstrap, fixture injection, and synthetic event controls stay
out of the production descriptor. XPC launch and lifetime invalidation
remain transport responsibilities, not workload methods.

### Store family design

`OpenStore` prepares or confirms the daemon's store for a `WikiId`. It
grants no local write access. `CloseStore` releases the caller's claim
without forcing eviction while another session holds the store.
`GetStoreChangeToken` returns an optional typed token, not an
empty-string sentinel. These preserve the lifecycle boundary at
`Sources/WikiDaemonContract/WikiDaemonProtocol.swift:33–47`.

Use dedicated unary request/reply pairs for the hot operations
`GetPage`, `ListPages`, and `UpsertPage`. `GetPage` returns optional
page metadata and a body value. `ListPages` carries the sort order and
returns a byte-budgeted page. `UpsertPage` carries an optional target,
title, body, author, provenance, and a `oneof` for unrestricted,
expected head, or expected absence. Use the composed upsert seam for
content, provenance, and parsed links in one transaction. Return the
typed result, mutation outcome, and optional commit echo. A failed
expectation or rollback emits nothing
(`DaemonStoreOpsBlob.swift:722–744,1143–1179`,
`DaemonStoreOpsList.swift:182–196`, `DaemonStoreValueMirrors.swift:285–301`).

The other 148 manifest operations each get one request arm and one reply
arm. Use the same explicit arm number for the operation in both
envelopes. Pin numbers in the descriptor ledger, not to enum declaration
order. The operation-specific types follow
`DaemonStoreOpsLedger.pair(for:)` and the value mirrors. Strip the
`Daemon` prefix from the DTO name and use lower snake case for the arm.
For example, `activeContentVersion` maps to
`StoreSmallRequest.active_content_version` and
`StoreSmallReply.active_content_version`. Each envelope carries one wiki
scope. No operation payload repeats that scope.

| RPC / schema sketch | Operation set | Success reply |
|---|---|---|
| `StoreSmall(StoreSmallRequest) → StoreSmallReply` | All 37 small tags | Matching arm, including typed mutation result where applicable |
| `StoreList(StoreListRequest) → StoreListReply` | 24 list tags other than `listPages` | Matching arm, ordered typed rows, optional next-page token |
| `StoreBlob(StoreBlobRequest) → StoreBlobReply` | 37 blob tags other than `getPage` and `upsertPage` | Matching arm with typed metadata and inline content or a handle |
| `StoreMutation(StoreMutationRequest) → StoreMutationReply` | All 50 event-producer tags | Matching arm, mutation outcome, optional commit echo |

Treat the partition as a payload classification, not a read/write
classification. Small operations include writes, and some blob writes
emit events. Preserve no-emit annotations for derived work and no-op
behavior for conditional mutations. Preserve the DTOs' ordering, optional
values, and variant distinctions. For example, `sourceContent` selects
active `SourceId` or a content-version ID, and present empty bytes are
not absent bytes (`DaemonStoreOpsBlob.swift:1011–1028`).
`DaemonStoreValueMirrors.swift:4–24` defines the legacy mirror, ordering,
and echo rules.

| Additional store ledger key | Replacement | Corpus coverage |
|---|---|---|
| `store.payloadBegin` | `BeginPayloadUpload` | Size, digest, purpose, over-limit failure |
| `store.payloadChunk` | `AppendPayloadChunk` | Ordered chunks, wrong index, digest mismatch |
| `store.payloadCommit` | `CommitPayloadUpload` | Complete seal, partial rejection, expiry |
| `store.payloadRead` | `ReadPayloadChunk` | Multi-chunk download, wrong session or wiki, expired handle |
| `store.resolveOutcome` | `ResolveStoreOutcome` | In-flight join, cached result, epoch or cache miss, fingerprint mismatch |
| `store.sessionBootstrap` | `GetStoreSessionBootstrap` | Extraction and renderer claims, token, absent Default vs committed strategy |
| `store.sinkHandshake` | `SubscribeEvents` with store family | Typed live `StoreEvent`. The acknowledged repair path belongs to step 3 |
| `store.upgradeSearchIndex` | `UpgradeSearchIndex` / `SearchUpgradeProgress` | Start outcomes and progress phases, including terminal states |

`GetStoreSessionBootstrap` is an application read, not a second
admission RPC. It returns the registration claims, change token, and
optional strategy state at `DaemonStoreWire.swift:695–804`. Package
declarations remain data. Do not infer host policy from the extractor
kind or registry identity.

**Staging.** Retain the bounds in `DaemonStoreWire.swift:394–435` and the
ordered integrity checks at lines 446–585. `BeginPayloadUpload` takes
`WikiId`, purpose, total bytes, and a 32-byte SHA-256 digest. It returns
`UploadId`. `AppendPayloadChunk` takes that ID, a zero-based index, up to
**1 MiB of raw bytes**, and the running digest. Reject duplicate and
out-of-order chunks. `CommitPayloadUpload` checks total size and digest,
then returns `PayloadHandle` with `PayloadHandleId`, size, digest,
purpose, and `Timestamp` expiry. It seals bytes only. The separate typed
workload RPC performs the mutation. `ReadPayloadChunk` returns indexed
chunks with total size, chunk count, and final-chunk indication. Verify
the whole digest before use.

Bind upload IDs and handles to the admitted session, daemon instance,
wiki, purpose, and transfer direction. A handle is not a path or an
authorization credential. Reject mismatches before dispatch. Retain the
256 MiB per-upload limit, 900 s idle expiry for incomplete uploads, and
600 s expiry for committed handles. Bound outstanding staging bytes and
handles per session. Reclaim them on revocation. A staged text field
uses UTF-8. A staged structured collection uses the protobuf encoding of
the specific collection message named by its typed field. The receiver
checks the handle's purpose and decodes that message. Never stage Swift
JSON, dispatch by a value inside the bytes, or split one atomic write
into several mutations.

**Mutation outcomes.** Carry `MutationStamp` on store writes:
`MutationRequestId` plus expected `StoreMutationEpoch`. The latter is a
daemon mutation guard, not a subscription cursor. Preserve admission by
`(wiki, request ID)` and operation/payload fingerprint, in-flight
joining, and the bounded outcome cache
(`DaemonStoreWire.swift:427–431,618–693`). `ResolveStoreOutcome`
identifies the original typed operation and stamp, with a digest of the
exact original operation payload submitted. Use the original encoded
payload for this check, never a re-encoding assumed to be canonical. The
known result is a typed reply arm, including `UpsertPageReply` for the
dedicated write. A miss answers `CODE_OUTCOME_UNKNOWN`. Resolve is
read-only. It cannot admit or replay a write.

**Commit events.** `StoreEvent` carries `WikiId`, a change token, and an
ordered batch of `ResourceChange` messages. Each change has a `KIND_`
change enum (created, updated, deleted) and a typed target arm. Cover
page, source, chat, bookmark, system prompt, wiki index, log, and
strategy. Use explicit singleton arms where the resource is a singleton.
Preserve a legacy unclassified target with its own arm only for a
genuinely absent legacy kind, never for an unknown future arm. Reply
echoes use the same change shape, with the existing store-local `seq`
retained as source metadata, not a subscription position. The committed
store event feeds `SubscribeEvents` at `EVENT_FAMILY_STORE` (2). Publish
from the store emission seam after commit and unlock, not from the RPC
handler. The legacy batch and delivery fields are described in
`DaemonStoreEventsWire.swift:39–68`. Step 3 replaces the delivery epoch,
watermark, and acknowledged handshake.

**Typed failures.** Return a non-OK gRPC status with `ErrorDetails`,
never an embedded error string in a success reply. Preserve associated
values in an additional typed status detail, `WorkloadErrorContext`,
with distinct payload arms for the cases that carry data. Keep details
bounded and redact diagnostic text. The decoder uses the stable numeric
code and checks that any required detail arm matches. It does not parse
`message`.

The source lists are `Sources/WikiDaemonContract/DaemonStoreWire.swift:968–1039`
(22 cases), `QueueRPCWire.swift:39–61` (six codes), and
`SearchRPCWire.swift:87–103` (five codes). The existing numbers 0–8 come
from `common.proto`. The new numbers below are proposed v1 allocations;
numeric codes are stable after acceptance.

| Legacy failure | `ErrorDetails.Code` | gRPC status / typed context |
|---|---|---|
| Store `open` | `CODE_STORE_OPEN_FAILED` (9) | `INTERNAL` |
| Store `sqlite` | `CODE_STORE_SQLITE` (10) | `INTERNAL`, SQLite result code and safe diagnostic |
| Store `notFound` | `CODE_PAGE_NOT_FOUND` (11) | `NOT_FOUND`, `PageId` |
| Store `chatNotFound` | `CODE_CHAT_NOT_FOUND` (12) | `NOT_FOUND`, `ChatId` |
| Store `sourceNotFound` | `CODE_SOURCE_NOT_FOUND` (13) | `NOT_FOUND`, `SourceId` |
| Store `sourceVersionNotFound` | `CODE_SOURCE_VERSION_NOT_FOUND` (14) | `NOT_FOUND`, content-version ID |
| Store `sourceMarkdownVersionNotFound` | `CODE_SOURCE_MARKDOWN_VERSION_NOT_FOUND` (15) | `NOT_FOUND`, Markdown-version ID |
| Store `noProcessedMarkdown` | `CODE_NO_PROCESSED_MARKDOWN` (16) | `FAILED_PRECONDITION`, `SourceId` |
| Store `deletionRestricted` | `CODE_DELETION_RESTRICTED` (17) | `FAILED_PRECONDITION`, ordered provenance blockers |
| Store `invalidBookmarkRow` | `CODE_INVALID_BOOKMARK_ROW` (18) | `DATA_LOSS`, row ID and reason |
| Store `invalidRendererEventID` | `CODE_INVALID_RENDERER_EVENT_ID` (19) | `INVALID_ARGUMENT`, rejected input where safe |
| Store `unexpected` | `CODE_STORE_UNEXPECTED` (20) | `INTERNAL` |
| Store `duplicateContent` | `CODE_DUPLICATE_CONTENT` (21) | `ALREADY_EXISTS`, existing `SourceSummary` |
| Store `duplicateURL` | `CODE_DUPLICATE_URL` (22) | `ALREADY_EXISTS`, existing `SourceSummary` |
| Store `pageConflict` | `CODE_PAGE_CONFLICT` (23) | `ABORTED`, target and expected/optional actual head |
| Store `pageCreateConflict` | `CODE_PAGE_CREATE_CONFLICT` (24) | `ALREADY_EXISTS`, title, existing page, optional head |
| Store `pageExpectedTargetMissing` | `CODE_PAGE_EXPECTED_TARGET_MISSING` (25) | `FAILED_PRECONDITION`, expected target context |
| Store `strategyRevisionConflict` | `CODE_STRATEGY_REVISION_CONFLICT` (26) | `ABORTED`, optional expected/current revisions |
| Store `sourceMarkdownConflict` | `CODE_SOURCE_MARKDOWN_CONFLICT` (27) | `ABORTED`, source and expected/optional current head |
| Store `epochMismatch` | `CODE_STORE_EPOCH_MISMATCH` (28) | `FAILED_PRECONDITION`, expected and actual epoch |
| Store `daemonUnavailable`, queue/search `unavailable` when transient | `CODE_UNAVAILABLE` (6) | `UNAVAILABLE`, retryable condition, not permission to replay |
| Store `outcomeUnknown` | `CODE_OUTCOME_UNKNOWN` (29) | `FAILED_PRECONDITION`, reconcile before any new write |
| Queue `ownershipTransition` | `CODE_QUEUE_OWNERSHIP_TRANSITION` (30) | `FAILED_PRECONDITION`, ownership plus active item IDs |
| Queue `invalidRequest`, search `invalidRequest` | `CODE_INVALID_REQUEST` (1) | `INVALID_ARGUMENT` |
| Queue `operationFailed`, search `operationFailed`, otherwise unclassified | `CODE_OPERATION_FAILED` (31) | `INTERNAL`, safe diagnostic |
| Queue `unsupportedVersion`, search `unsupportedVersion`, unserved capability | `CODE_CAPABILITY_MISMATCH` (3) | `FAILED_PRECONDITION` |
| Queue `invalidEnvelope` | `CODE_INVALID_ENVELOPE` (32) | `INVALID_ARGUMENT` for the request, `DATA_LOSS` for a malformed reply |
| Search `unknownWiki`, registry/lifecycle wiki miss | `CODE_WIKI_NOT_FOUND` (5) | `NOT_FOUND` |

Use `CODE_INVALID_REQUEST` for an unknown request variant. For an
unknown reply or event variant, surface a local typed unknown-variant
failure, not a fabricated server success. Legacy `ChatSyncWireError`
maps missing version or malformed data to `CODE_INVALID_ENVELOPE`,
unsupported version to `CODE_CAPABILITY_MISMATCH`, and unsupported
legacy envelope kind to unknown variant
(`Sources/WikiFSEngine/ChatSyncWire.swift:231–252`). Unsupported
diagnostic versions also map to `CODE_CAPABILITY_MISMATCH`
(`Sources/WikiFSTypes/ChatDiagnosticTypes.swift:248–285`). Classify chat
preflight and lifecycle failures at their source. Do not infer a code
from the legacy string. Legacy `nil` and `false` failures become typed
status errors at the source, not successful empty replies. Preserve
genuine optional values, report outcomes, and terminal work failures as
domain data.

Future typed failures require an explicit mapping, a new number if the
existing code cannot preserve their meaning, and a corpus case. Never
renumber or reuse a retired code. Unknown numeric codes map to the zero
member and fail locally as unknown variant without a retry. Only a
transient condition can set `retryable`. An application-level `ABORTED`
conflict requires reconciliation, not replay.

### Queue family design

The queue methods in the ledger are unary, except the completion
subscription. `GetQueueSnapshot` preserves ordered active and recent
items, queue run states, provider counts, and active ingestion wikis
(`Sources/WikiFSEngine/QueueWorker.swift:268–279`). Use typed rows for
state and provider counts rather than string-keyed dictionaries. This is
the existing workload read. Step 3 decides how it serves as a
subscription baseline.

`EnqueueItem` carries `WikiId`, queue kind, typed payload, and optional
dedupe key. The daemon assigns `QueueItemId`, order, attempt, state, and
timestamps (`Sources/WikiFSCore/Core/QueueTypes.swift:305–331`). Project
payload fields directly. Use typed stage/provider rows and tagged
page/source name records. A present `LintSelection` with an empty page
list means whole-wiki lint; absence means normal ingestion
(`QueueTypes.swift:97–154`). Return the assigned ID. A dedupe key
preserves the existing enqueue semantics, not a general retry policy.

Cancel and retry take `QueueItemId`. Cancel-all returns an affected
count. Pause, resume, and halt take a queue-kind enum and retain
distinct effects. Reorder takes the item ID and optional before-item ID.
`HasActiveWork` takes `WikiId` and returns a bool.
`LoadQueueTranscript` returns ordered typed transcript items.
`LoadQueueActivitySnapshots` returns typed activity rows. Reports
preserve `loaded`, `not_reported`, and `unavailable` arms. Summaries
accept bounded item-ID batches and return typed item/summary pairs or an
unavailable result (`Sources/WikiFSCore/Core/QueueReportTypes.swift:454–474`).
A report-unavailable outcome is not a failure to decode or execute the
RPC.

Carry `QueueOwnership` on queue replies that replace the versioned
envelope. It contains a `QueueOwnershipEpoch` wrapper over `uint64` and
a typed host state: serving, relinquishing, relinquished, or shutdown
blocked. `RelinquishQueue` requires the expected epoch and returns the
completed epoch and the existing four shutdown checks. A blocked
transition includes current ownership and active item IDs. The queue
epoch is distinct from the daemon instance and any delivery position
(`Sources/WikiDaemonContract/QueueRPCWire.swift:4–36,77–85,212–253`).

`QueueEvent` is a typed `oneof` on `SubscribeEvents` at
`EVENT_FAMILY_QUEUE` (3). Cover enqueued, started, completed, failed,
cancelled, reordered, progress, transcript, usage, live usage, run
paths, run state, pending permission, report updated, and report
unavailable. Use typed attempt, transcript, usage, permission, and
report messages instead of the nested JSON fields at
`Sources/WikiFSEngine/QueueEventEnvelope.swift:12–49,81–130`. A
permission-clear event is explicit. The completion subscription replaces
the blocking `waitForCompletion` reply. It observes terminal variants
for the requested item and distinguishes completed, failed, and
cancelled. Step 3 defines the terminal-state snapshot for already-
finished items and closes the race between that read and the stream. Do
not add a polling unary wait.

### Chat family design

Use `WikiId` and `ChatId` to scope live chat operations. `StartChat`
takes the first message and optional provider, model, and
thinking-option overrides. `SubmitChatTurn` uses a tagged draft or
existing-chat target; only draft submissions carry draft overrides. Its
typed submission carries command ID, turn ID, user text, tagged
page/source/chat references, and `submitted_at`. Start and submit return
the authoritative chat ID on success
(`Sources/WikiFSEngine/ChatXPCRequests.swift:12–93`,
`Sources/WikiFSTypes/ChatConversationTypes.swift:5–9,50–70`).
`ContinueChat` targets a persisted chat. `SendChatMessage` targets a
live session. `StopChat` scopes cancellation to the wiki and chat. An
acknowledgement is not a terminal event.

`GetChatSessionState` returns the authoritative projection values from
`Sources/WikiFSEngine/ChatSyncWire.swift:95–115,208–229`. Carry lifecycle
and turn state, queued turns, attention, capabilities, provider state,
usage, active transcript content, pending permission, and run metadata
as typed fields. Do not recreate the old cluster of run flags or ship
`usageData` as bytes. Keep persisted transcript paging separate from
live event recovery. Step 3 defines the projection baseline's
relationship to the stream and the old sync watermarks.

`ResolveChatPermission` identifies the pending request and uses explicit
approve-with-option or reject arms. Reject a stale identity or an option
the request did not offer. `SetChatConfigOption` uses
`ChatConfigOptionId` and `ChatConfigValueId` and applies to a live
session. These identifiers are provider-defined values, not free-form
commands or a closed enum (`ChatXPCRequests.swift:152–184`).

`GetChatDiagnostics` returns a versioned, bounded, **redacted** export.
Optional chat correlation narrows the process-wide read. Preserve
process identity, timestamps, typed stage/outcome, keyed fingerprints,
and drop counts. Never include raw user or assistant text, tool inputs,
credential values, fingerprint keys, or unredacted stderr.
`ResetChatDiagnostics` acknowledges a delivered export, bound to its
diagnostic process identity and export reference. A failed client export
must not drain the ring. A stale acknowledgement must not rotate a newer
ring (`Sources/WikiFSTypes/ChatDiagnosticTypes.swift:176–245,252–285`).

`ChatEvent` uses the `EVENT_FAMILY_CHAT` (4) subscription. Map
`chatSyncUpdate` to a typed session-event or compatibility-refresh arm.
The event vocabulary covers turn lifecycle, transcript deltas,
permission requests/resolution, session readiness/recovery/close, and
failure categories (`Sources/WikiFSEngine/ChatDomain.swift:425–447`). Do
not expose `chatEvent`, `chatState`, `chatAcpSessionId`, or
`chatPendingPermission` as separate event variants. The old boundary
already rejects those legacy tags (`QueueEventEnvelope.swift:20–23,222–228`).

### Search family design

Migrate the app's unified search, not the CLI search socket. `Search`
and `Autocomplete` replace the two cases at
`Sources/WikiDaemonContract/SearchRPCWire.swift:18–59`. Both take
`WikiId`, typed page/source/chat filters, and a result limit. An empty
filter list means all supported kinds, as did absent or empty kinds on
XPC. `Search` takes query text. `Autocomplete` takes partial text and
edit distance, clamped to 0–255 as on XPC. Keep ordered hits with title
and score, and use one document-target arm (`PageId`, `SourceId`, or
`ChatId`). The arm replaces the composite `kind:ULID` identifier and
separate kind string. An empty hit list is success. Before serving,
synchronize the per-wiki runtime with the current store change token so
the read reflects observable committed writes
(`WikiDaemonProtocol.swift:54–60`).

`UpgradeSearchIndex` is the daemon-scoped backfill command with a wiki
target. Return `started` (including an existing run), `not_needed`, or
`embedder_unavailable`, plus the scanned total. `SearchUpgradeProgress`
carries wiki, phase (pages/sources/chats), done, total, and
running/complete/failed state
(`Sources/WikiDaemonContract/DaemonSearchUpgradeWire.swift:25–30,39–69,87–119`).
Attach it to `SubscribeEvents` as its own search family
(`EVENT_FAMILY_SEARCH = 17`, outside the existing reservation). It is
not a store commit and must not advance a store reconciliation position.
Step 3 defines any recovery for missed terminal progress. An explicit
second start is not a transport retry.

### Registry mutations design

`ListWikis` and `WikiDescriptor` stay unchanged. `CreateWiki` takes a
name and returns the assigned descriptor. Apply the existing trim and
default to `Untitled Wiki`
(`Sources/WikiDaemonContract/DaemonDomainWire.swift:705–714`).
`DeleteWiki` takes `WikiId` and acknowledges completion of the registry
and database removal. `RenameWiki` takes `WikiId` and display name, and
acknowledges the change without changing identity or moving the
database. Use the daemon lifecycle coordinator, not a direct registry or
SQLite write from the provider.

`ResolveWiki` takes a `oneof` with `WikiId` or display name and returns
a descriptor or `CODE_WIKI_NOT_FOUND`. The legacy selector adapter keeps
exact ID lookup first and exact display-name lookup second
(`Sources/wikid/WikiDaemon.swift:1347–1355`). On the typed wire, an
explicit ID lookup does not silently reinterpret a miss as a name.

Use the existing `RegistryEvent` on `EVENT_FAMILY_REGISTRY` (1). Publish
only after the registry change succeeds. Include display name for create
and rename, omit it for delete, and keep the existing `ListWikis`
refresh behavior. Legacy import landing also emits created without
adding an import RPC
(`Sources/WikiDaemonContract/DaemonRegistryEventsWire.swift:4–8,33–38,47–68`).

### Cross-cutting rules

- **Additive v1.** Define workload types in new family files in
  `wikid.appdaemon.v1` with `option swift_prefix = "AppDaemon"`. Append
  methods to `AppDaemon` in `service.proto:35–53`. Do not change existing
  method paths, fields, numbers, or types. For step 3 event delivery, use
  a new optional `WorkloadEvent workload = 3` on `DaemonEvent`. Put the
  exhaustive store, queue, chat, and search progress `oneof` inside that
  new message. Require exactly one of the existing registry arm or the
  workload field. Keep registry at field 2. The family numbers 2–4 are
  currently reserved, not usable. At activation, carve out only 2–4 for
  their documented assignments and retain 5–16 as reserved
  (`events.proto:26–43`). Review that intentional allocation through the
  descriptor gate. Do not use a previously removed field's number or
  name. Reserve both in the same edit if a future removal is separately
  allowed. Incompatible changes require a new package version.
- **Capability and dispatch.** Keep the existing admission and capability
  check before workload dispatch. Advertise each family only when both
  methods and mappings are available. Advertise event support separately
  from unary support. Do not send workload events to a registry-only
  subscriber. Dispatch every known arm exhaustively at the caller and
  provider boundary. An unset required `oneof`, an unexpected reply arm,
  or an unknown arm without a usable known arm fails typed. Ignore
  unknown additive fields on a valid known message. Do not require
  unknown fields to survive a decode/re-encode. Every enum has zero
  `*_UNSPECIFIED`, never sent deliberately. Map unknown numeric values to
  zero and fail typed rather than guessing. Use `KIND_` for kind enums
  and `CODE_` for error codes.
- **Presence, IDs, and units.** Use `optional` when absence differs from
  a scalar default, and explicit presence for nullable messages. Wrap
  repeated values in a present message when absent and empty differ. Use
  `WikiId`, `PageId`, `SourceId`, `QueueItemId`, and wrappers for page
  versions, commands, attempts, permissions, provider IDs, and other
  distinct domain identities. Use `ChatId` for chat identity: the
  checkout has a distinct `ChatID` with the same raw representation as
  the former chat-valued `PageID`
  (`Sources/WikiFSTypes/ChatID.swift:3–7`). Keep source content/Markdown
  version IDs in their current `PageID` representation until those
  namespaces migrate. Use a tagged union for mixed targets. Do not
  rewrite existing ULIDs or other raw identifiers. Use UTC
  `google.protobuf.Timestamp` for instants and `google.protobuf.Duration`
  for durations. Do not encode wall-clock times as epoch milliseconds.
  Epochs, sequence metadata, indices, revisions, and byte counts are not
  timestamps.
- **Bounds.** Enforce the 4 MiB maximum on each encoded message in both
  directions, including stream messages, before application dispatch
  where possible (`service.proto:11–21`). Oversize is
  `RESOURCE_EXHAUSTED` with `CODE_RESOURCE_EXHAUSTED` when the provider
  can return status details. A transport rejection must still fail typed
  at the receiver. Target 1 MiB for store chunks and encoded list pages.
  Use optional, session-bound continuation tokens for byte-budgeted
  reads, not event positions. Store blobs and oversized single values use
  typed handles. Queue snapshots, activity reads, transcripts and reports
  use bounded pages or typed download handles. Chat uses bounded typed
  batches or handles for oversized transcript, text, or report values.
  Diagnostic export must retain its drop counts. Large immutable event
  content can reference a typed download handle rather than splitting a
  single logical change. Search and autocomplete bound hit count and
  encoded size. Registry descriptors, lifecycle calls, queue controls,
  permission/config commands, and progress events stay inline. Never
  silently truncate a successful reply to make it fit.
- **Deadlines.** Keep admission and capabilities at the existing 10 s
  client budget (`Sources/WikiDaemonGRPC/AppDaemonSessionClient.swift:43–54`).
  Use 30 s client / 60 s handler for registry, lifecycle, ordinary store
  calls and chunks, search and autocomplete, queue reads and controls,
  and chat commands and reads. These match the standard constants at
  `Sources/WikiDaemonContract/DaemonDomainWire.swift:645–677`. Use the
  660 s client / 600 s handler budget for typed store `workspaceMerge`
  and `reapStaleWorkspaces`, the counterparts of the long workspace calls
  at lines 680–694. CLI admin stays out of scope. Backfill start and chat
  submission deadlines bound admission, not worker or provider run time.
  Each unary call has an explicit client deadline and server ceiling. The
  daemon observes the earlier limit. Streams are tied to session lifetime
  and caller cancellation, not unary deadlines. A timeout or transport
  loss does not prove rollback.
- **Retry.** Disable gRPC retries and hedging. Automatic bounded backoff
  applies only to bootstrap exchange within its admission window and to
  subscription recovery (`Protocol/app-daemon/README.md:57–62`). Registry,
  store, search, queue, and chat reads can be issued again explicitly. A
  new read can reflect newer state. Reconcile ambiguous writes through
  `ResolveStoreOutcome` where applicable or through authoritative reads.
  Never auto-retry registry or lifecycle changes, store writes or upload
  mutations, queue controls, chat commands, diagnostic reset, or search
  upgrade commands. A typed transient failure does not override this
  rule.
- **Step boundary.** Step 3 owns subscription cursors, replay and loss
  detection, snapshot barriers, terminal queue repair, adapter parity
  fixtures and their wiring, and the development switch. Existing
  workload reads and unary pagination do not establish stream positions.
  Step 4 owns production cutover and removal of XPC workload selectors.
  The CLI domain socket, File Provider wires, and Linux stdio transport
  do not change.

### Fixture + coverage plan

Extend `Protocol/app-daemon/fixtures/corpus.json` with typed cases for
each family. Each case has a stable ID, family, ledger key, method or
event arm, and structured request values. Expect a typed reply or a
status error, plus any ordered event expectations for the case. Error
cases specify the gRPC status and details version, code, retryability,
daemon instance, and typed context. Include absent vs present-default
fields, present empty collections, unknown additive fields, unknown
enum/oneof tags, ordering, bounds, and session binding. Use multi-call
fixtures for staging and outcome resolution. Corpus JSON is fixture
notation only, not a workload payload or dispatch format.

Use the **same case IDs and expectations in both roles**. In role A,
Rust `serve` validates the request from the production Swift client and
serves the expected reply, error, or events. In role B, Rust `probe`
drives the production Swift listener/provider and checks request
handling and the same outcomes. Inject deterministic domain operations
behind the provider, not a second provider or transport. Compare decoded
known values, presence, and variant tags, never re-encoded bytes. This
extends the roles at
`Tests/WikiFSAppTests/AppDaemonRustInteropTests.swift` and the corpus
rule at `Protocol/app-daemon/fixtures/corpus.json:2–3`. Missing peer
binaries, unknown fixture IDs, or unexecuted role cases fail the gate.
Step 3 wires live adapter parity and subscription recovery tests.
Isolated schema/event fixtures do not claim that parity.

Add a workload coverage ledger to the proto coverage gate. Scan the
selector declaration block and reverse sink separately, using the
inventory precedent at
`Tests/WikiFSTests/AppDaemonBootstrapOnlyContractTests.swift:28–61`.
Require exact set equality with production, admission-only, and
explicitly excluded ledger entries. For the store, use an exhaustive
`DaemonStoreOperation` switch with no default, following
`Tests/WikiFSTests/DaemonStoreOpsCompletenessTests.swift:20–44,634–683`.
Require 151 manifest pairs and eight classified infrastructure/event
operations. Infrastructure does not get a fictitious slice-2 DTO pair.
It must still resolve to a dedicated method or a named subscription
replacement.

For every mapped operation, assert its generated request/reply
descriptors and any arm numbers, at least one matching fixture ID, and
executed handling in both interop roles. Pin success, status, and event
coverage separately. Check both directions: each corpus ID resolves to a
known ledger entry and both role runners account for it, and each
production workload entry has corpus evidence. An explicit step-3
subscription dependency can defer live recovery evidence, not erase the
payload row. Admission and exclusions have their own assertions. In
particular, the signed probe must not appear in the production proto
descriptors or capability list.
