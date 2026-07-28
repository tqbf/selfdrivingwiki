---
timestamp: 2026-06-16T050916Z
title: "2026-06-15 — LLM Wiki Phase B: `log.md` + `index.md` — DONE ✅ (gate passed)"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-06-15 — LLM Wiki Phase B: `log.md` + `index.md` — DONE ✅ (gate passed)

## Progress


Branch `llmwiki/phase-b-index-log` (stacked on `llmwiki/phase-a-write-path`).
Implements `plans/llm-wiki.md` Phase B: the append-only `log` table + the curated
`wiki_index` singleton, two `wikictl` subcommands to write them, and both
projected read-only at each wiki's root. All deterministic (no agent yet).
Independent live-mount gate (Bash, on a freshly-created wiki) PASSED.

**Added / changed**
- **Two stepwise migrations** slotted into the existing `bootstrapSchema()` ladder
  (`SQLiteWikiStore.swift`), continuing past the v2→3 `system_prompt` step:
  - **v3→4** — a `log` table (`id` ULID PK, `ts` REAL, `kind` TEXT, `title` TEXT,
    `note` TEXT nullable). Append-only chronological log; NOT a singleton — each
    `appendLog` INSERTs a fresh ULID-keyed row (`id` sorts == chronological).
  - **v4→5** — a `wiki_index` SINGLETON (`id INTEGER PRIMARY KEY CHECK(id=1)`,
    `body_markdown`, `updated_at`, `version`), modeled EXACTLY on `system_prompt`:
    seeded with `WikiIndex.defaultBody`, UPSERT on write, `version` bumped each
    write. Existing v1/v2/v3 DBs migrate forward with pages + files + system_prompt
    preserved (`LogIndexTests.migratesV3DatabaseToV5PreservingData` builds a v3 DB
    by hand and asserts all three ride through untouched + the index seeds).
- **Value types (`WikiFSCore`).** `LogEntry` (+ closed `LogEntry.Kind`
  `ingest|query|lint`) and `WikiIndex` (the `system_prompt`-shaped singleton +
  `defaultBody`). `LogRenderer` — pure, deterministic `log.md` rendering: one
  grep-able `## [YYYY-MM-DD] <kind> | <title>` heading per row (UTC date via a
  fixed `en_US_POSIX` formatter so `grep "^## \[" log.md | tail -5` works exactly
  as the doc shows), the optional note on the following line.
- **Store methods (`SQLiteWikiStore` + `WikiStore` protocol).** `appendLog(kind:
  title:note:)`, `getWikiIndex()`, `updateWikiIndex(body:)` on the protocol (so the
  CLI commands run against `WikiStore`, like the `page` commands);
  `listAllLogEntriesOrderedByID()` stays concrete (a read-projection helper, like
  `listAllPagesOrderedByID`).
- **⚠️ `changeToken()` extended** `…:spVersion` → `…:spVersion:logCount:idxVersion`
  (now `"pCount:pSum:fCount:fSum:spVersion:logCount:idxVersion"`). SAME reasoning
  as the `spVersion` fold: appending ONLY a log entry (logCount) or editing ONLY
  the index (idxVersion) must still advance the anchor or the projected
  `log.md`/`index.md` would never refresh. `log` uses COUNT (append-only — rows
  only grow), `wiki_index` uses the row `version` (UPSERTs). Both fall back to `0`
  on a pre-v4/v5 read connection (table absent), exactly like the `spVersion`
  helper. ALL `changeToken` test literals gained the trailing `:0:1` (fresh DB:
  no log rows, index seeded at v1).
- **`wikictl` subcommands (`WikiCtlCore` + `wikictl`).** `ArgumentParser` grew a
  top-level command switch (`page` / `log` / `index`) and two parsers; the new
  `LogIndexCommand` executes `logAppend` / `indexSet` against a `WikiStore`
  (mirrors `PageCommand`); `main.swift`'s dispatch (`execute`) routes to the right
  family and reads the deferred `--body-file` body (`-` = stdin):
  - `wikictl [--wiki <id>] log append --kind ingest|query|lint --title "…"
    [--note "…"]` — appends one dated row, echoes the new ULID. Rejects an invalid
    `--kind`.
  - `wikictl [--wiki <id>] index set --body-file <path|->` — UPSERTs the singleton
    body wholesale (version+1); `-` reads stdin.
  Both select the wiki via `--wiki`/`WIKI_DB` and post the SAME per-wiki
  `WikiChangeNotification` Darwin name as Phase A after committing (both return
  `didCommit: true`) — reusing the existing `WikiResolver` + `DarwinNotifier`
  plumbing unchanged, so the app's change bridge refreshes that wiki with no new
  wiring.
- **Projection (`Projection.swift` + `WikiFSContainerID`).** Two new root-level
  read-only files: `index.md` (the singleton body served verbatim, sized/versioned
  by the row `version` — exactly the `CLAUDE.md`/`AGENTS.md` path) and `log.md`
  (the rendered table, versioned by the change token since its bytes derive from
  many rows — like the generated index files). New `log-md`/`index-md` container
  ids; added to `node(for:)`, the root children, the working set, and
  `contents(for:)`. Both resilient to the v4/v5 tables being absent on a
  pre-migration read connection → empty/default, so the files always exist.
- **Signaling.** `log.md`/`index.md` are root children, so the app's existing
  `signalChange()` (`.rootContainer` + `.workingSet`) refreshes them — no new
  signal container needed (same as `manifest.json` / `CLAUDE.md`).
- Tests: 113 → **135** (+22). `LogIndexTests` (v3→5 migration preserving
  pages+files+system_prompt + seeding the index; `appendLog` field correctness +
  nil-note + chronological order; `LogRenderer` grep-able prefix + empty doc;
  `updateWikiIndex` UPSERT version-bump + persist-across-reopen +
  recreate-after-delete; **changeToken advances on a log-only AND an index-only
  write**). `WikiCtlLogIndexTests` (arg parsing/dispatch for both commands incl.
  bad-`--kind` + missing-required + unknown-subcommand; `LogIndexCommand`
  execution against a temp DB). Existing `changeToken`/migration literals updated.
  `make test` → **135/135**; `make` clean signed bundle (app + appex + `wikictl`).

**Smoke-tested (Bash, against the `GateAClean` wiki, non-destructive)**
- `log append --kind ingest --title … --note …` and `--kind query` (no note) both
  echoed new ULIDs and wrote correct `log` rows (kind/title/note); `index set`
  from stdin UPSERTed the `wiki_index` body to version 2. The hand-computed change
  token reflected the writes (`…:logCount=2:idxVersion=2`), proving both folds
  advance live. DB migrated to `user_version 5`.

**Verified (independent live gate, real `make clean && make install`, real-signed, Bash + minimal computer-use)**
On a **freshly-created wiki `GateBClean`** (`01KV7CWPJE…`, mount
`WikiFS-GateBClean`, made via the in-app switcher) — no `WIKIFS_REENUMERATE`
needed, the new root files materialized cleanly in seconds (confirming Phase A's
churned-domain finding). App pid **44966 unchanged through every step** (no
relaunch anywhere).
- **(1) `log append` → grep-able `log.md`:** appended `--kind ingest` (with
  `--note`) and `--kind query` (no note) → mount `log.md` refreshed in ~2 s to
  `## [2026-06-16] ingest | Article One` / `## [2026-06-16] query | How does X
  compare?`; `grep "^## \["` returned exactly the two headings; the note renders
  for the ingest entry and is absent for the no-note query entry. `--kind bogus`
  rejected (exit 2).
- **(2) `index set` → rewrites root `index.md`:** `printf … | wikictl index set
  --body-file -` bumped `wiki_index.version` 1→2; mount `index.md` refreshed in
  ~1 s and `diff` vs the set body was IDENTICAL (verbatim).
- **(3) log-only / index-only edit advances the anchor + refresh, no relaunch:**
  a fresh `log append --kind lint` advanced the token fold `logCount` 2→3
  (idxVersion held at 2) → `log.md` changed bytes in ~2 s; a fresh `index set`
  advanced `idxVersion` 2→3 (logCount held at 3) → `index.md` refreshed in ~3 s;
  pid 44966 unchanged both times. Both halves of the `…:logCount:idxVersion` fold
  drive the sync anchor independently.
- **SoT confirmed:** `PRAGMA user_version` migrated 3→5 **lazily on the first
  `wikictl` write** (a fresh wiki ships at 3); `wiki_index` at version 3, all 3
  `log` rows intact. 135/135 tests; real-signed app + appex + `wikictl`.

**Notes / carry-forward**
- A fresh wiki's DB ships at `user_version 3` and migrates to 5 **lazily on the
  first `wikictl` write** (the `bootstrapSchema()` ladder runs on store-open) —
  expected; the projected `log.md`/`index.md` exist (default/empty) before then.
- **~5 s mount-refresh window** still applies; `wikictl page get` is the instant
  SoT escape hatch.
- **macOS-26 TCC prompt** re-fires on a re-signed install and holds the app until
  "Allow" (Phase 0 carry-forward).
- Gate artifact wiki **`GateBClean`** left in place (deleting is destructive; the
  gate doesn't require teardown), as with `GateAClean`.

## Verification

Historical verification remains in the progress record above.
