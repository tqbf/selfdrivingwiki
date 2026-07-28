---
timestamp: 2026-06-16T044215Z
title: "2026-06-15 — LLM Wiki Phase A: Write path + change bridge — DONE ✅ (gate passed)"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-06-15 — LLM Wiki Phase A: Write path + change bridge — DONE ✅ (gate passed)

## Progress


Branch `llmwiki/phase-a-write-path` (stacked on `llmwiki/phase-0-many-wikis`).
Implements `plans/llm-wiki.md` Phase A: the `wikictl` write path, the shared
link-reparse refactor, and the Darwin-notification → debounced app refresh +
`signalChange()` change bridge. **All deterministic (no agent yet).** Independent
live-mount gate (Bash + one UI check) PASSED.

**Added / changed**
- **Shared upsert+reparse seam (`WikiFSCore/PageUpsert.swift`).** Lifted "create-
  or-update a page + reparse `[[links]]` + `replaceLinks`" out of
  `WikiStoreModel.save()` into `PageUpsert.upsert(in:id:title:body:)`. BOTH the
  app model (`save()` now calls it) AND `wikictl` call this one op, so the link
  graph stays consistent **identically** from both writers (the doc's "no second
  drifting implementation in the CLI"). Resolution order: explicit `--id` →
  title→id via `resolveTitleToID` → create. Returns the id + a `didCreate` flag.
  `newPage()` still uses `createPage` directly (it must always create, never
  resolve-to-existing). A unit test drives the SAME content through `PageUpsert`
  and through the model and asserts byte-identical `page_links`.
- **`wikictl` CLI — new SwiftPM targets.** Logic lives in a LIBRARY target
  `WikiCtlCore` (arg parsing, command dispatch, wiki resolution, the Darwin post)
  so it's unit-testable; the `wikictl` executable target is a thin process shell
  over it (the same library/executable split `WikiFSCore` uses). Command surface,
  each selecting the wiki via `--wiki <id-or-name>` or the `WIKI_DB` env var:
  - `page list [--json]` — id / title / mount-relative `pages/by-title/…` path per
    line, TSV or JSON (the path uses the SAME `FilenameEscaping` as the projection
    so the agent can `cat` it).
  - `page get (--title X | --id Y)` — prints the body. The **instant SoT read**
    that bypasses the ~5 s mount lag.
  - `page upsert --title X [--id Y] --body-file <path|->` — create-or-update via
    the shared `PageUpsert`; prints the resulting id. `-` reads stdin.
  - `page delete --id Y`.
  Opens the wiki's `<ulid>.sqlite` **read-write** via the literal App Group path
  the un-sandboxed app uses (`WikiResolver` → `DatabaseLocation.appGroupContainerDirectory`),
  resolved through the SAME `WikiRegistry` the app reads. WAL + `busy_timeout=5000`
  make the second writer safe. Exit codes: 0 ok / 2 usage / 1 runtime.
- **Darwin notification — wiki id in the NAME.** Darwin notifications carry no
  payload, so the wiki id can't be data. `WikiChangeNotification`
  (`WikiFSCore`, shared so the two sides can't drift) encodes it in the name:
  `org.sockpuppet.wiki.changed.<wikiID>`. `wikictl` posts THIS per-wiki name after
  every committing call (`upsert`/`delete`), never on a read, and **never signals
  the File Provider itself** — that stays the app's job (single owner of FP
  signaling). The app subscribes to exactly that name for each registered wiki, so
  the change bridge learns WHICH wiki changed with no demux table. (Rejected: one
  generic name + refresh-all-wikis — wasteful with N wikis and loses the "which
  wiki" the doc wants.)
- **Change bridge in the app (`WikiFS/WikiChangeBridge.swift`).** Observes the
  per-wiki Darwin notification for every registered wiki (re-subscribes on the
  wiki set changing via `.onChange(of: manager.wikis)`), and for the changed wiki,
  after a **per-wiki ~250 ms coalesce**, (a) rebuilds the active store's
  `summaries` if that wiki is on screen (`WikiStoreModel.reloadFromStore()`, a full
  source rebuild per §3.1) and (b) calls `FileProviderSpike.signalChange(forWikiID:)`
  so that wiki's mount refreshes (~5 s). The CF observer fires on a CFRunLoop
  callback and **hops to the main actor** before touching the coalescer / model /
  FP. The coalescing itself is the PURE `WikiFSCore/ChangeCoalescer` (injected
  scheduler + flush) so the debounce is unit-tested with a fake clock — one ingest
  burst of ~15 `wikictl` calls collapses to one rebuild + one FP signal per wiki.
- **`FileProviderSpike.signalChange(forWikiID:)`** — a per-wiki variant (the old
  `signalChange()` now delegates to it for the active wiki) so the bridge can
  refresh a wiki that is NOT the one on screen.
- **Packaging.** `Package.swift` gains `WikiCtlCore` + `wikictl`. `build.sh`
  builds `wikictl`, copies it to `build/wikictl` for the gate to invoke directly,
  AND embeds + codesigns it at `WikiFS.app/Contents/Helpers/wikictl` for Phase C's
  app-spawn. Read-only FP invariant intact — `wikictl` writes ONLY SQLite.
- Tests: 86 → **113** (+27). `PageUpsertTests` (create/update/explicit-id/
  duplicate-title resolution, link reparse, replace-not-append, CLI-vs-model link
  parity), `WikiCtlCommandTests` (arg parsing for every command incl. env-vs-flag
  precedence + usage errors; `PageCommand` dispatch against a temp DB; Darwin name
  carries the id), `ChangeCoalescerTests` (burst→one flush, per-wiki independence,
  re-arm after flush). `make test` → **113/113**; `make` clean signed bundle
  (app + appex + wikictl all real-signed).

**Smoke-tested (Bash, against the real registry's wiki, non-destructive)**
- `page list` (TSV + `--json`), `page get --title/--id`, `WIKI_DB` env and
  display-name selectors all resolve and return live SQLite bytes. An `upsert`
  with a `[[Home]]` body wrote a real `page_links` row (shared reparse seam works
  from the CLI), `page get` read it back instantly, and `delete` removed it (list
  returned to 2). Error paths return the right exit codes (unknown wiki → 1, bad
  args → 2).

**Verified (independent live gate, real `make clean && make install`, real-signed, Bash + one computer-use UI check)**
All five Phase A criteria passed; the decisive end-to-end run was on a
**freshly-created wiki `GateAClean`** (`01KV7BHTQM…`, mount `WikiFS-GateAClean`),
with items 1–2 also reconfirmed on the live `WikiFS` wiki.
- **(1) CLI write:** `printf 'Gate A body linking [[Home]]\n' | wikictl --wiki
  <id> page upsert --title "GateA-CLEAN9" --body-file -` → printed new id
  `01KV7BJWS8…`; SQLite row confirmed directly (title + body).
- **(2) Sidebar updates live (no relaunch):** the new page appeared in the running
  app's sidebar above Home, app pid unchanged — proving the per-wiki Darwin
  notification → debounced `WikiChangeBridge` → `reloadFromStore()` path
  (reconfirmed with two successive upserts on the WikiFS wiki).
- **(3) Mount reflects it (~1 s):** `pages/by-id/01KV7BJW….md` +
  `pages/by-title/GateA-CLEAN9--01KV7BJW.md` both served the exact body.
- **(4) Read-only intact:** overwrite/append of projected files AND of
  `indexes/links.jsonl` → "operation not permitted"; SQLite untouched.
- **(5) Link graph:** `page_links` row `01KV7BJW… → <Home>` and mount
  `indexes/links.jsonl` `{"from":"01KV7BJW…","to":"<Home>","link_text":"Home"}` —
  the CLI-written `[[Home]]` resolved through the shared `PageUpsert` seam end to
  end. Command surface (`get`/`list` TSV+JSON/`WIKI_DB` env/`delete`, exit codes
  1 unknown-wiki / 2 usage) all confirmed. 113/113 tests; real-signed app + appex
  + `wikictl`.

**Notes / carry-forward**
- **Heavily-churned domain replica can wedge (operational, NOT a code defect →
  use a fresh wiki for live gates).** The long-lived `WikiFS` domain's mount would
  not reflect CLI writes during the gate: `fileproviderctl dump` showed the
  daemon's replica holding a *phantom* page from an earlier session, `-1005`
  fetch errors, a missing `indexes/`, and "Stale NFS file handle" on
  previously-valid files — the extension wasn't even invoked. The DB itself is
  intact (a `wal_checkpoint(TRUNCATE)` confirmed all pages durable + readable by a
  fresh reader); this is a corrupted **daemon-side materialized replica**
  accumulated over many prior gate runs on that one domain. It did NOT recover via
  the app's `WIKIFS_REENUMERATE` remove+re-add, a `fileproviderd` bounce, or ~90 s
  of reconciliation — a true reset needs a domain teardown (only the signed app's
  lifecycle can do it; an ad-hoc CLI gets FP -2001/-2014). A **freshly-created**
  domain (`GateAClean`) materialized fully and correctly in ~1 s. **Phase B/C live
  gates should run against a freshly-created wiki, not the churned `WikiFS` one.**
  Logged to `ISSUES.md`.
- **~5 s mount-refresh window** (replicated-FP read-after-write) still applies; the
  CLI's `page get` is the instant-SoT escape hatch.
- **macOS-26 TCC prompt** ("access data from other apps") re-fires on a re-signed
  install and holds the app until "Allow" (Phase 0 carry-forward).
- A gate artifact wiki **`GateAClean`** was left in place (deleting is destructive;
  the gate doesn't require teardown); its only content is a seeded empty `Home`.

## Verification

Historical verification remains in the progress record above.
