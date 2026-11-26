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
FINAL OUTER encoded envelope. Chunk payloads cross two base64 layers (chunk
`Data` inside DTO JSON, DTO JSON inside the envelope): a 1 MiB raw chunk is
≈ 1.37 MiB after the first layer and ≈ 1.83 MiB after the second — inside the
cap with envelope overhead. Tests assert the outer size.

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

## Store operation manifest (filled at P2)

See the plan §Phase 2.1 for the classification rules. This table lists every
`WikiStore` protocol requirement with exactly one classification:
**rpc** (structured wire op), **client** (client-local metadata), or
**removed** (no production consumer after cutover).

| Requirement | Class | Notes |
|---|---|---|
| (P2 populates this table exhaustively; `RemoteStoreSurfaceExhaustivenessTests` parses `WikiStore.swift` and fails on an unclassified or unmapped requirement) | | |

## Error mapping (filled at P2)

`WikiStoreError` case → wire case → reconstruction, with associated values
intact (`duplicateContent`/`duplicateURL` carry `SourceSummary`,
`deletionRestricted` carries blockers, typed not-found IDs preserved, CAS
family carried via `DaemonConflictDetail`). Transport-level
`daemonUnavailable`/`outcomeUnknown` covers connection loss. Deliberate
collapses: NONE (documented here if any appear).

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
served by a handle read.

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
