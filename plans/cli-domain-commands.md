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
| `job list/get` | direct `queue.sqlite` reads | new queue read endpoint |
| `extractor sync/fetch` | direct `queue.sqlite` writes | daemon `enqueueItem` |
| page/source/chat/bookmark/workspace/strategy/log/admin | CLI boots Cordis profile in-process, opens the store | generic domain-command endpoint executed through the daemon's prepared services |
| `page/source/chat search` | daemon BM25 via socket; semantic leg, fusion, hit mapping still local | move resolution server-side so search commands are store-free |
| `chat new/send/stop` | retired | may return over the existing daemon chat endpoints |
| `extractor list`, `version`, `--dump-config` | container files / no DB | stay local |
| `--database-path` fixtures | local by design (refuses container paths) | unchanged |

The CLI cannot construct `GRDBWikiStore` directly — the boundary script
(`Tests/CordisTests/CordisBoundaryScriptTests.swift`) forbids it. The pathway
is the in-process profile boot; the daemon serves the same profile layer via
`prepareAndResolveWikiServices`, which is what "same domain layer as the app"
means concretely.

## CAS and exit codes

CAS crosses the wire as typed error codes, not strings: `casConflict`
(expected/actual heads), `createOnly`, `expectedTargetMissing`,
`strategyRevision`. The CLI maps them to exit code 3. The 0/1/2/3 contract and
byte-stable stdout formats are scripting contracts; preserve both.

## Phases

0. **Land `bugfix/concurrent-cli-search`** — the search socket, safe index
   opens, and the fail-fast error contract.
1. **Transport generalization + queue verbs** — introduce the domain envelope,
   re-target `DaemonWorkloadClient` onto the socket. Fixes the pre-existing
   lookup3 defect. No new domain handlers; lowest risk first.
2. **Registry + lifecycle** — `wiki list/rename/create/delete` through the
   daemon. Delete inherits full eviction (search runtime, database artifacts),
   closing the CLI's degraded-delete race. Drop the CLI's direct create path.
3. **Read-only domain endpoint** — page/source/chat/bookmark/workspace reads,
   info/okf-inspect, `job list/get` (new queue read endpoint). Server executes
   through the daemon's prepared services.
4. **Writes** — page/source/strategy/bookmark/workspace mutations, log/index,
   `extractor sync/fetch` via `enqueueItem` (move BEFORE stripping the CLI's
   direct queue write, or durable enqueue is lost when the app is closed),
   admin maintenance. Source `addURL`/`refresh` network fetching moves into the
   daemon. Typed CAS codes throughout.
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
