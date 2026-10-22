# CLI domain commands through the daemon

## Principle

The daemon is the single pathway to wiki data. Only `wikid` opens the wiki
database, `queue.sqlite`, `wikis.json`, and the search index for domain
commands. The app and `wikictl` are clients. There is no local fallback: when
the daemon is unreachable, commands fail fast with an explicit error.

## Why

Today the CLI boots the app's own domain layer in its process
(`CLIStoreProfile` → `CordisBoot.boot`, whose `StorePlugin` opens
`GRDBWikiStore`) and writes `wikis.json` directly. Several processes open the
same SQLite files. That is what caused the search writer contention in #1457,
and it leaves CLI `wiki delete` racing a live daemon's caches without eviction.

The standalone CLI cannot reach the app-embedded XPC service. XPC service
lookup is bundle-scoped; `wikictl` has no bundle. Verified live:
`NSCocoaErrorDomain 4099`, lookup error 3, on installed build `1232-9f7e94b1`.
See `plans/xpc-service-migration.md` §"wikictl consequence". A launchd Mach
service was deliberately removed at #887 (AMFI entitlement kills, TCC
reprompts, stale-daemon races); do not bring it back.

## Transport

Generalize the search socket into THE CLI→daemon transport. `SearchSocketWire`
(length-prefixed frames, 4 MiB cap, same-user gate, flock guard, per-phase
deadlines) and `DaemonSearchSocketServer` are already proven on this branch.

- Payloads use a versioned domain envelope: `{version, requestID, family,
  operation, payload}` → typed reply or typed error, following the
  `SearchRPCRequest`/`QueueRPCEnvelope` patterns. Unknown family or operation
  is a typed `invalidRequest`.
- A `hello` capabilities endpoint negotiates versions, so a new CLI against an
  old daemon reports "requires app ≥ build N" instead of a raw transport error.
- The app keeps XPC for now: `WikiDaemonEventSink` is an XPC reverse channel.
  Two client transports to one store owner is acceptable; the invariant is who
  opens the store. App-side convergence is a separate follow-on decision.
- App closed ⇒ daemon exits ⇒ socket unlinked ⇒ every domain command exits 1
  with "the wikid daemon is not running — launch the app". No silent fallback.

## Current pathways (inventory)

| Command family | Today | Target |
| --- | --- | --- |
| `wiki list/rename/resolve` | direct `wikis.json` reads | daemon registry methods (exist) |
| `wiki create/delete` | direct create+seed / degraded delete (no eviction, no search-index cleanup) | daemon `createWiki`/`deleteWiki` (full eviction) |
| `queue status/pause/resume/halt`, `transcribe` enqueue | daemon XPC — broken from CLI (lookup3) | `DaemonWorkloadClient` re-targeted onto the socket |
| page/source/chat/bookmark/workspace — READS | CLI boots Cordis profile in-process, opens the store | ✅ daemon executes the same command layer over the envelope (Phase 3) |
| page/source/chat search | daemon BM25 via socket; semantic leg, fusion, hit mapping still local | ✅ full command runs server-side; search commands are store-free (Phase 3) |
| `job list/get` | direct `queue.sqlite` reads | ✅ daemon `queueWikiItems` (full history + extraction-completed leg) |
| `extractor sync/fetch` | direct `queue.sqlite` writes | ✅ daemon executes the whole command; durable enqueue through the daemon's queue engine (Phase 4) |
| page/source/chat/bookmark/workspace/strategy/log/admin — WRITES | CLI boots Cordis profile in-process, opens the store | ✅ daemon executes the same command layer with typed CAS codes (Phase 4) |
| `chat new/send/stop` | retired | may return over the existing daemon chat endpoints |
| `extractor list`, `version`, `--dump-config` | container files / no DB | stay local |
| `--database-path` fixtures | local by design (refuses container paths) | unchanged |

The CLI cannot construct `GRDBWikiStore` directly — the boundary script
(`Tests/CordisTests/CordisBoundaryScriptTests.swift`) forbids it. The pathway
is the in-process profile boot; the daemon serves the same profile layer via
`prepareAndResolveWikiServices`, which is what "same domain layer as the app"
means concretely.

## The landed envelope (v1) — what Phases 3–4 build on

Implemented in `Sources/WikiDaemonContract/DaemonDomainWire.swift`; dispatched
by `Sources/wikid/DaemonDomainSocketDispatcher.swift` (the daemon boot's
socket handler); spoken by `Sources/WikiCtlCore/DaemonDomainSocketClient.swift`
(+ `DaemonWikiRegistryClient`, `DaemonWorkloadClient`'s socket backend). The
byte-level transport (`SearchSocketWire` framing, socket file
`wikid-search.sock`, flock guard, same-user gate, deadlines) is unchanged;
only the payload changed.

Request: `{"version": 1, "requestID": "<uuid>", "family": "<family>",
"operation": "<verb>", "payload": <family JSON or null>}`

Reply: `{"version": 1, "requestID": "<echo>", "family": "<family>",
"operation": "<echo>", "payload": <family JSON or null>, "error": null |
{"code": "<code>", "message": "<text>"}}`

- `DaemonDomainVersion.current == 1`. The daemon checks `version` BEFORE
  dispatch; any mismatch is a typed `unsupportedVersion` reply. A reply that
  is not a domain envelope at all (an old daemon) decodes as
  `unsupportedVersion` on the client with "quit and relaunch (or reinstall)
  the app" guidance.
- Families today: `hello`, `search`, `queue`, `wiki`, Phase 3's `page`,
  `source`, `chat`, `bookmark`, `workspace`, and Phase 4's `strategy`, `log`,
  `admin`, `extractor` (an unknown family string or unknown operation still
  decodes to a typed `invalidRequest` reply — never a transport fault).
- Error codes: `invalidRequest`, `unsupportedVersion`, `notFound`,
  `unavailable`, `operationFailed`, plus Phase 4's typed CAS codes
  `casConflict` (kind `page` or `sourceMarkdown`, carrying expected + actual
  heads), `createOnlyConflict`, `expectedTargetMissing`, and
  `strategyRevisionConflict` (expected/actual revisions, nil = absent). Each
  CAS error carries a structured `DaemonConflictDetail`; the CLI rebuilds the
  SAME typed store error (`PageConflictError`,
  `SourceMarkdownConflictError`, `PageCreateConflictError`,
  `PageExpectedTargetMissingError`, `WikiStrategyConflictError`) so the
  existing exit-3 catch paths print the byte-stable conflict text.
- Family payloads ride unchanged inside `payload`:
  - `hello` / `capabilities` → reply payload is `DaemonHelloPayload`
    `{version, protocolVersion, families: [sorted strings], appVersion,
    buildVersion}`.
  - `search` / `search` → payload is the unchanged `SearchRPCRequest` JSON;
    reply payload the unchanged `SearchRPCReply` JSON.
  - `queue` / `queueSnapshot|enqueueItem|pauseQueue|resumeQueue|haltQueue` →
    payload is the unchanged `QueueRPCEnvelope<P>` JSON pair (lane controls
    carry a `DaemonQueueControlRequest {queue}`); the queue error taxonomy
    survives the socket intact. `queue` / `queueWikiItems` (Phase 3) →
    payload `DaemonQueueWikiItemsRequest {wikiID, itemID?}`; reply payload
    `DaemonQueueWikiItemsReply {itemsJSON: Data ([QueueItem] bytes),
    completedSourceIDs: [String]}` — the durable per-wiki read (FULL terminal
    history via `QueueStore.loadItems(wikiID:)`, not the bounded snapshot
    window) plus the wiki leg: every source id among the selected items that
    has a processed-markdown HEAD. This is what `wikictl job list/get` runs on.
  - `wiki` / `listWikis|createWiki|deleteWiki|renameWiki|resolveWiki` →
    payloads `DaemonWikiCreateRequest {name}`, `DaemonWikiDeleteRequest {id}`,
    `DaemonWikiRenameRequest {id, name}`, `DaemonWikiResolveRequest
    {selector}`; descriptor replies are the daemon's own `[WikiDescriptor]` /
    `WikiDescriptor` JSON bytes. Unknown ids resolve to typed `notFound`
    with the message `no wiki matching <selector>`.
  - `page|source|chat|bookmark|workspace` (Phase 3) → per-operation payload
    structs in `Sources/WikiDaemonContract/DaemonCommandWire.swift`, each
    carrying `wikiID` (resolved against the registry FIRST; unknown wiki is a
    typed `notFound` with the `no wiki matching <id>` text). The reply
    payload is ALWAYS the uniform `DaemonCommandOutcome
    {text | bytesBase64, didCommit, stderr}`: the daemon EXECUTES the CLI's
    own command layer (`PageCommand.run` and friends) against its prepared
    store, so the byte-stable stdout formats are produced by the identical
    code that produced them in-process and the CLI does no catalog work.
    Operations: `page` list/get/history/info/search/okfInspect/okfStatus/
    okfFreshness/okfVerify; `source` list/cat/export/info/search; `chat`
    list/get/search; `bookmark` list; `workspace` status/conflicts.
    `source export` carries the CLI's cwd (the default output path is built
    and the file WRITTEN daemon-side, in the caller's directory). The okf
    status/freshness/verify verbs are sanctioned Phase 3 scope — the daemon
    executes their writes and `didCommit` drives the CLI's Darwin post.
  - The search COMMANDS (Phase 3 store-freedom) are family-scoped operations
    (`page`/`source`/`chat` × `search`, payload
    `DaemonSearchCommandRequest {wikiID, query, limit}`), NOT a search-family
    op: the daemon resolves the BM25 leg with its own per-wiki Tantivy
    runtime, maps hits against the store catalog (absent ids dropped; an
    all-empty resolution is NO leg, never an error), fuses with the semantic
    cosine leg via the store's `searchSimilar`, and renders through the same
    `*Command.run` code — so the zero-results stderr note and TSV bytes are
    identical to the in-process path.
- Operation strings live in `DaemonDomainOperation` (Hello/Search/Queue/Wiki/
  Page/Source/Chat/Bookmark/Workspace namespaces) shared by both sides.

## Deviations from the plan (Phases 1–2)

- **`wiki resolve`** is not a CLI verb (it never was). The daemon's
  `resolveWiki` is served over the envelope, and `transcribe --wiki`
  resolution uses it. Ordinary command `--wiki` resolution stays a local
  registry read until Phase 5 strips registry construction from
  `WikiCtlCore` — routing it now would force every read-only command to
  require the daemon ahead of its phase.
- **The queue family requires `--wiki` at parse time** (pre-existing parser
  contract, unchanged here): the live-check invocation is
  `wikictl --wiki <id> queue status`.
- **Search wrapping is transport-level**: `DaemonSearchClient` and its
  transport seam are untouched; the envelope wraps/unwraps inside
  `DaemonSearchSocketClient`. Search keep-working is proven by the
  pre-existing socket suite plus a live `page search` round trip.
- **`DaemonWorkloadClient`'s socket backend implements the five CLI queue
  verbs** (snapshot, enqueue, pause, resume, halt). Its other methods throw a
  typed failure on that backend — the event sink and chat surfaces are XPC
  reverse-channel world and stay app-only.
- **`WikiDaemon.createWikiOverSocket/deleteWikiOverSocket`** route to the
  production creation coordinator when a profile owner exists and to the
  synchronous fixture seam otherwise (mirrors the `openStore` split) so
  in-process tests exercise the same dispatcher.
- **Fixture handlers in `DaemonSearchSocketTests` are wrapped in an envelope
  adapter** mirroring the daemon's search-family routing, so transport
  coverage is preserved verbatim while the wire changed shape.
- **The CLI consults `hello` via typed error guidance** rather than a
  proactive handshake per command: a version-mismatch surfaces as
  `unsupportedVersion` with relaunch guidance; `hello`/`capabilities` is
  served and tested for clients that want to negotiate explicitly.

## Deviations from the plan (Phase 4)

- **The daemon executes the CLI's write command layer too.** Same pattern as
  Phase 3 — one executor (`DaemonDomainCommands`), uniform
  `DaemonCommandOutcome` — extended to mutations. Bodies cross RESOLVED: the
  CLI resolves every `BodySource` (file path or `-` = stdin) BEFORE the wire,
  because the daemon has no caller stdin. `WorkspaceCommand.Action.resolve`
  became `body: BodySource` for the same reason (a raw `bodyFile: String`
  would have been treated as a PATH server-side).
- **Bodies and bytes ride inline.** `page add` body, `source add` raw bytes
  (base64), `editMarkdown` content, `strategy save` instructions, `workspace
  resolve` content, `index set` body — all resolved CLI-side, capped by the
  4 MiB request frame (an oversized `source add` fails on the CLIENT with
  `frameTooLarge` before connecting, the same ceiling family as `source cat`
  replies).
- **CAS expectations ride the request; the store evaluates them inside the
  write, server-side.** No pre-check round trip. The server executor catches
  the five typed store errors and replies with the typed CAS code + structured
  detail — never a stringified stderr guess. The CLI's
  `DaemonCommandRouter.conflictError(from:)` rebuilds the typed error, so
  main.swift's existing catch clauses keep their exact byte-stable conflict
  text and exit 3; successes never throw, keeping exit 0.
- **`page add` runs with the SAME write tooling as the in-process path**: the
  markdown linter (which AUTO-FIXES the body — nil would silently change what
  gets stored) and the package-driven fence validator resolved from the
  daemon's container. Reads keep Phase 3's nil tooling.
- **Extractor sync/fetch: the ENTIRE command runs daemon-side.** The daemon
  builds its own package catalog (the durable machine catalog the app
  publishes, plus its reviewed overlay — the same posture as the app-bundled
  CLI helper) and the durable enqueue goes through the daemon's queue ENGINE
  (the exact `engine.enqueue` closure the `enqueueItem` queue-family
  operation's handler runs). The CLI sends only parameters and never opens
  `queue.sqlite`; these two commands now REQUIRE the app running (fail fast).
  The CLI's old direct-write path survives only for `--database-path`
  fixtures until Phase 5 strips it. Tests inject a catalog double via the
  fixture-daemon seam (`testExtractorCatalog`).
- **Source okf family + `page okfCorrect` + `chat rename` ride along.** The
  Phase 4 charter is "every mutating command", and Phase 3's note said the
  remaining okf writes wait "until Phase 4" — so the source
  okfInspect/Status/Freshness/Verify/Correct ops (mirroring the page family's
  Phase 3 payloads) and the two leftover writes migrated too. `strategy read`
  migrated with save/reset for family completeness (it is the strategy
  family's only read; leaving it local would keep a store-opening read
  behind).
- **Per-endpoint handler budgets** (`DaemonDomainBudgets`, the documented
  choice from §"Long-running operations"): the whole `admin` family and
  `workspace merge`/`reap` run under a 600 s SERVER handler budget with a 660
  s CLIENT deadline (client above server, so the true outcome rides back
  instead of the client giving up first); everything else keeps the socket's
  standard posture (60 s server / 30 s client). The server peeks the decoded
  envelope at handler start (`Connection.startProcessing`) and races the
  handler against its operation's budget — an undecodable frame keeps the
  standard bound, and the race still fires on an oversized budget, so a stuck
  handler cannot pin an fd. No async-job pattern: the budget sufficed in
  testing.
- **Frame cap** (unchanged 4 MiB, guarded in the dispatcher's shared reply
  encoder): covers every new family. `page get` on a >~4 MiB page still fails
  typed `operationFailed` naming the cap.

## Deviations from the plan (Phase 3)

- **The daemon EXECUTES the CLI's command layer.** Instead of one handler per
  operation re-encoding each read's output, `wikid` links `WikiCtlCore`
  (macOS) and runs `PageCommand.run` / `SourceCommand.run` /
  `ChatCommand.run` / `BookmarkCommand.run` / `WorkspaceCommand.run` against
  its prepared store (`WikiDaemon.domainCommandStore` — the
  `prepareAndResolveWikiServices` admission path; the fixture seam in
  tests). Every family replies with the uniform `DaemonCommandOutcome`
  `{text | bytesBase64, didCommit, stderr}`. Byte-stable stdout is therefore
  guaranteed by construction — the same code renders the bytes in both
  worlds — and future CLI verbs inherit the transport by mapping one
  action. The command semantics stay in ONE module that both processes run.
- **Unknown wiki text on migrated reads** is the daemon's byte-stable
  `no wiki matching <selector>` — the local registry path's
  `"… in the registry"` suffix is gone, matching the Phase 2 daemon text
  (`wiki list`/`transcribe --wiki` already print it).
- **The okf status/freshness/verify verbs are Phase 3 scope even though they
  write** (per the Phase 3 charter's okf read-verb list): the daemon executes
  their writes through the same store seam, `didCommit: true` rides the
  outcome, and the CLI posts the Darwin notification exactly as the
  in-process path did. `okfCorrect` and all other writes stay local until
  Phase 4.
- **Search store-freedom is family-scoped, not a search-family op.** The plan
  sketched "a daemon-side search operation that returns RESOLVED, ranked
  summaries"; landed instead as `page`/`source`/`chat` × `search` operations
  that run the ENTIRE command server-side (BM25 leg via `ensureSearchRuntime`
  → catalog mapping → `searchSimilar` fusion → the same `*Command.run`
  rendering). Same store-freedom outcome, but the zero-results note and TSV
  bytes come from the identical code, so nothing is re-encoded client-side.
- **`job list/get` reads FULL terminal history, not the engine snapshot.**
  `queueSnapshot` is a bounded active+recent window for UI bootstrap; the new
  `queueWikiItems` queue-family operation reads `QueueStore.loadItems(wikiID:)`
  through a read-only WAL connection beside the engine's writer (the same
  pattern the transcribe completion poll uses) and resolves the
  extraction-completed wiki leg through the prepared store. Rendering stays
  CLI-side (`JobCommand.renderList/renderGet` — pure presentation).
- **Frame-cap audit (4 MiB).** Worst cases: `source cat` (raw bytes ride
  base64 — a source over ~3 MiB cannot fit) and `page get` (a page body over
  ~4 MiB cannot fit). Both fail with a typed `operationFailed` naming the cap
  and the narrower read to use instead — never a truncation. The guard is in
  the dispatcher's shared reply encoder, so EVERY family is protected;
  `source export` is immune (the daemon writes the file into the caller's cwd
  — which rides the request — and replies with just the path). Chunked
  replies remain out of scope: no real payload hit the cap.

## CAS and exit codes

CAS crosses the wire as typed error codes, not strings: `casConflict`
(expected/actual heads), `createOnly`, `expectedTargetMissing`,
`strategyRevision`. The CLI maps them to exit code 3. The 0/1/2/3 contract and
byte-stable stdout formats are scripting contracts; preserve both.

## Phases

0. **Land `bugfix/concurrent-cli-search`** — the search socket, safe index
   opens, and the fail-fast error contract. ✅ **Implemented.**
1. **Transport generalization + queue verbs** — introduce the domain envelope,
   re-target `DaemonWorkloadClient` onto the socket. Fixes the pre-existing
   lookup3 defect. No new domain handlers; lowest risk first.
   ✅ **Implemented** (commit `2d809bbe`). See §"The landed envelope (v1)"
   below for the exact wire shape Phases 3–4 build on.
2. **Registry + lifecycle** — `wiki list/rename/create/delete` through the
   daemon. Delete inherits full eviction (search runtime, database artifacts),
   closing the CLI's degraded-delete race. Drop the CLI's direct create path.
   ✅ **Implemented** (commit `c123797d`); `wiki resolve` has no CLI verb —
   the daemon's `resolveWiki` is served over the envelope and backs
   `transcribe --wiki` resolution (see §Deviations).
3. **Read-only domain endpoint** — page/source/chat/bookmark/workspace reads,
   info/okf-inspect, `job list/get` (new queue read endpoint). Server executes
   through the daemon's prepared services.
   ✅ **Implemented** (commits `0bf3478e`, `15b67245`): the five command
   families + server-side search resolution + `queueWikiItems` behind
   `job list/get`, all store-free on the CLI side. See §"Deviations from the
   plan (Phase 3)" — notably the daemon EXECUTES the CLI's command layer and
   replies with a uniform outcome, which is how byte-stable stdout is kept.
4. **Writes** — page/source/strategy/bookmark/workspace mutations, log/index,
   `extractor sync/fetch` via `enqueueItem` (move BEFORE stripping the CLI's
   direct queue write, or durable enqueue is lost when the app is closed),
   admin maintenance. Source `addURL`/`refresh` network fetching moves into the
   daemon. Typed CAS codes throughout.
   ✅ **Implemented** (see §"Deviations from the plan (Phase 4)"): every
   mutating wikictl command now rides the daemon — page
   add/delete/revert/okfCorrect, source
   addURL/addFile/editMarkdown/rename/setActive/refresh + the source okf
   family, chat rename, bookmark createFolder/addRef/rename/delete/move,
   workspace create/abandon/merge/refresh/resolve/retry/reap, strategy
   read/save/reset, log append + index set, admin vacuums + MIME repair, and
   `extractor sync/fetch` (durable enqueue through the daemon's queue engine).
   CAS crosses as typed codes (`casConflict`, `createOnlyConflict`,
   `expectedTargetMissing`, `strategyRevisionConflict`) that the CLI maps back
   to the byte-stable exit-3 conflict text. The CLI is store-free for every
   registry-selected command.
5. **Completion + enforcement** — transcribe waits via a daemon poll endpoint;
   retire CLI `queue.sqlite` reads; strip store/queue/registry construction
   from `WikiCtlCore`/`wikictl`; extend the boundary script to reject
   `QueueStore(`/`WikiRegistry.load(` in those targets so "one pathway" stays
   true.
6. **Optional follow-on (separate plan)** — app-side convergence: retire the
   local `QueueEngine` fallback, consider unifying the app onto the socket,
   sole-writer evolution.

## Long-running operations

`admin vacuumAll`, `workspace merge`, source `addURL` (network), and
`transcribe` waits exceed any single handler deadline. Give handlers
per-endpoint budgets, or use the async enqueue + daemon-poll pattern (the
transcribe flow already demonstrates it). Audit the largest read payloads
against the 4 MiB frame cap before finalizing; add chunked replies only if a
payload can exceed it.

Phase 4 landed the per-endpoint budget: `DaemonDomainBudgets` gives the admin
family and workspace merge/reap a 600 s server handler budget (660 s client
deadline); everything else keeps the socket's 60 s/30 s posture. The budget
sufficed — no async-job pattern was needed. `transcribe`'s wait already uses
its own durable poll and is untouched.

## Test strategy

- **Unit**: in-process server + client per endpoint on a temp container
  (`DaemonSearchSocketTests` pattern), using `testFixtureMakeStore` so handlers
  run without the app. Wire round-trip and version-rejection tests per family;
  timeout tests follow `DaemonWorkloadClientTimeoutTests`. No blocking waits;
  `.serialized` suites.
- **Boundary**: `CordisBoundaryScriptTests` extended to forbid store, queue,
  and registry construction in the CLI targets. This is the enforcement that
  keeps the migration from regressing.
- **Integration gate (opt-in, the real proof)**: install the built app, wait
  for the socket file, run the actual bundled `wikictl` (not
  `.build/debug/wikictl`) for one verb per family and assert exit code and
  output; quit the app and assert the exit-1 "not running" failure; drive one
  CAS conflict end-to-end to exit 3. This is the only tier that exercises
  TCC, App Group, and signing realities.

## Risks

- **Scripted users**: a new CLI against an old daemon fails everything. The
  `hello` handshake turns that into a clear version message; the CLI ships
  inside the app bundle (`Contents/Helpers`), so they upgrade together.
- **Transitional builds** (old CLI + new daemon) still have the delete race;
  document it until Phase 2 lands everywhere.
- **Agent-facing errors change shape**: from SQLite authorization denials to
  socket ENOENT/EACCES. Error text must not imply "no wiki exists".
- **App-closed becomes a hard failure for every command.** Deliberate posture
  change per operator direction; make the error name the cause.
