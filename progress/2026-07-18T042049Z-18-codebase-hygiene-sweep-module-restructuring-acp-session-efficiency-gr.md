---
timestamp: 2026-07-18T042049Z
title: "2026-07-17/18 — Codebase hygiene sweep + module restructuring + ACP session efficiency + GRDB adoption"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-07-17/18 — Codebase hygiene sweep + module restructuring + ACP session efficiency + GRDB adoption

## Progress


A comprehensive multi-day session touching 40+ PRs across five major efforts.

### Codebase hygiene sweep (15 PRs, #487–#511)

**Correctness fixes:**
- #487/#495: WikiDaemon `changeToken` bare `try?` → sentinel + `DebugLog` (stale FP projections)
- #492/#494: 11 silent-swallow `try?` on mutating/persistence writes → `do/catch + DebugLog` (#475 pattern)
- #493/#499: `-warnings-as-errors` on all 9 Swift targets (37 existing warnings fixed)

**Type safety:**
- #489/#498: Link-kind prefixes (`"page:"`/`"source:"`/`"chat:"`) → `ResourceKind.linkPrefix` typed accessor (7+ sites)
- #501/#505: Typed enum sweep — `SourceMarkdownOrigin` (5 cases), `WorkspaceStatus` rawValue decode, `LinkRole` enum
- #508/#513: Queue-layer typing — namespace shared `"running"` rawValue, typed `QueueLogRecord` fields
- #509/#515: Agent config typing — `HintKey`/`StageRoutingKey` enums, `legacyAgentName` constant
- #510/#521: MIME type namespace — `MimeType` with typed predicates replacing 13+ inline comparisons

**Dead code + dedup:**
- #488/#497: Deleted dead content-sniff forwarder shims (−81 lines)
- #502/#504: Cross-module dedup — `KeychainSecretStore`, `HTMLEntities.escapeHTML`, `SlugUtils.slugBase` (−122 lines)
- #507/#512: Naming cleanup — deleted dead `Resource` protocol, renamed `WikiLinkValidator.swift` → `WikiLinkFixer.swift`, `FileProviderSpike` → `FileProviderFacade`

**Performance:**
- #490/#496: Cache `makeLinkMaps()` per `ReadScope` + `getChat(id:)` direct lookup (N+1 → O(1))
- #491/#500: Remove ~28 redundant per-mutator `reload*()` calls (Phase E follow-up — 8 table scans → 4 per save)
- #503/#514: Perf wins batch — cache chat transcript render, hoist O(n²) array copy, batched markdown head query
- #511/#516: Shared `WikiLinkIndex` builder (unify link-map computation between WikiRenderContext and Projection)

**Build infrastructure:**
- #518/#529: `JSONSidecarConfig` protocol (collapse config load/save boilerplate)
- #519/#523: SQLite PRAGMA tuning — `synchronous=NORMAL`, `mmap_size`, `cache_size`, `temp_store=MEMORY`
- #520/#522: Release-mode Makefile targets (`make check-release`, `make test-fast-release`)
- #531/#533: Directory reorganization — 223 files into 17 subdirectories (zero build impact)

### Module restructuring (5 PRs, #532–#536)

- #534: Design doc — `plans/module-restructure.md`. Key finding: `SQLiteWikiStore` is a fan-in hub (not a leaf); `WikiStoreModel` is the composition root by design (3,096 lines, 75+ store calls, 68 views observe it). No circular deps exist.
- #535: Phase 1 — extract `WikiFSLinks` (11 files) + `WikiFSTypes` leaf (PageID, ULID, ResourceKind, EmbedTarget, ParsedLink, DebugLog). `@_exported import` re-export pattern. Discovered the bidirectional dependency (WikiFSCore ↔ WikiFSLinks) and solved it with the leaf split.
- #536: Phases 2+3 — extract `WikiFSMarkdown` (16 files, links JavaScriptCore) + `WikiFSSearch` (7 files, links NaturalLanguage). Moved `DebugLog` to `WikiFSTypes`.

Module graph after restructuring:
```
WikiFSTypes (leaf, Foundation only) ← WikiFSLinks ← WikiFSMarkdown
WikiFSTypes ← WikiFSSearch
WikiFSCore depends on all four, @_exported import re-exports them
```

### ACP session efficiency (6 PRs, #525/#537–#549)

Design doc `plans/acp-session-efficiency.md` (PR #537). Four implementation phases:

- #539 Phase 1: Warm subprocess across ingest phases — `startProcess()`/`createSession()`/`closeSession()` split. Eliminates 6 subprocess lifecycles per 5-source ingest (12–24s saved).
- #540 Phase 2: `session/resume` crash recovery — capability detection (`canResume`/`canLoadSession`), `resume()` implementation (`resumeSession` → `loadSession` → `nil` fallback chain), subprocess death detection via `kill(pid, 0)`.
- #542 Phase 3: `session/fork` for executors — `forkSession(from:cwd:)`, planner session kept alive through executor loop, graceful fallback to fresh `createSession()`.
- #544/#549 Phase 4: Usage/cost capture (`SessionUsage` struct, `translateNotification` returns usage), context monitoring (64%/80% thresholds), `parallelExecutors` via `withTaskGroup` with per-session event batching.
- #546: Usage UI spike — surface token counts + cost in Activity window (per-item) and menu bar (daily cumulative).
- #547: Named constants for ACPBackend + AgentLauncher (timeouts, env keys, filenames, delimiters)
- #548: Strip 77 `TEMP DEBUG` comments + fix `QueueStore.loadItemEvents` bare `try?`
- #551: Remove idle stall detection, shift watchdog to observability-only

### GRDB adoption (4 PRs, #530/#538/#543/#545/#550/#557)

Design doc `plans/grdb-adoption.md` (PR #538). Key findings: `mutate()` seam is portable (15-line wrapper), `ValueObservation` complements (not replaces) `WikiEventBus`, `QueueStore` is the ideal pilot.

- #543: QueueStore pilot — full GRDB rewrite (replaces raw `sqlite3_*` with `DatabaseQueue` + `DatabaseMigrator` + `FetchableRecord`). Proves GRDB works in the project.
- #545: GRDBWikiStore skeleton — 1,662 lines, ~50 of 88 methods, `mutate()` seam, `DatabaseQueue` with PRAGMAs, sqlite-vec registration.
- #550: All 50 remaining stubs implemented — 3,024 lines added. All 88 `WikiStore` protocol methods now have GRDB implementations. Zero stubs.
- #557: 37-version migration ladder — `PRAGMA user_version` + same switch ladder translated to GRDB. Fresh DB → `createFreshSchema` + stamp to v37. Existing DB → run unapplied migrations. `writeWithoutTransaction` for independent commit per step. FTS5 corruption heal-and-retry.

**Path to removing SQLiteWikiStore:**
1. ✅ All 88 methods implemented
2. ✅ 37-version migration ladder
3. ⏳ Parity tests (swap at injection point, run 2,400+ tests against GRDBWikiStore)
4. ⏳ Swap injection point, deprecate SQLiteWikiStore
5. ⏳ Delete SQLiteWikiStore + SQLiteStatement + WikiReadPool

### Design research docs (3 PRs)

- #526/#541: Tantivy search sidecar — `plans/tantivy-search-sidecar.md`. 4-phase adoption: build spike → shadow index → cutover → retire FTS5+sqlite-vec. One unified index with facets. Embeddings stay in SQLite.
- #530/#538: GRDB adoption — `plans/grdb-adoption.md`. Feature mapping, `mutate()` seam design, observation migration, custom extension registration, migration framework evaluation.
- #532/#534: Module restructuring — `plans/module-restructure.md`. Phased extraction plan, circular dependency analysis, `WikiStoreModel` decomposition assessment.

### Other improvements

- #527: Filed — off-peak ingest scheduling (item-level `scheduledFor` + queue-level time windows)
- #528: Filed — budget/quota-aware ingestion (data seam ready from ACP Phase 4 + #546)
- #524: Filed — zstd BLOB compression via C extension (mirror CSqliteVec pattern)
- #552: Wire Settings window via OpenWindowBridge
- #555: Enrich activity window with run metadata and timing
- #556: Format broken links with namespace prefixes in agent lint prompt

## Verification

Historical verification remains in the progress record above.
