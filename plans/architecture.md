# WikiFS — architecture (the system map)

This is the developer's map of how WikiFS fits together. It is grounded in the
code; where it would only duplicate another doc it cross-links instead. Read
[`PLAN.md`](../PLAN.md) → [`PROGRESS.md`](../PROGRESS.md) for status and build
history, [`INITIAL.md`](INITIAL.md) for the original architecture, and
[`llm-wiki.md`](llm-wiki.md) for the LLM-wiki design and the phase plan. Known
limitations live in [`ISSUES.md`](../ISSUES.md).

The one invariant that everything below serves: **the File Provider mount is
read-only; SQLite is the source of truth; reads and writes go through `wikictl`.**

---

## 1. Components & targets

Five SwiftPM targets ([`Package.swift`](../Package.swift)):

```
                ┌─────────────────────────────────────────────┐
                │              WikiFSCore (library)            │
                │  model · SQLite store · registry · ops seams │
                │  log/index/TREE · URL ingest · HTML→MD       │
                └───────────────┬───────────────┬─────────────┘
        depends ▲               │ depends       │ depends
                │               ▼               ▼
   ┌────────────┴──────┐  ┌──────────────┐  ┌──────────────────────┐
   │ WikiFS (app exe)  │  │ WikiCtlCore  │  │ WikiFSFileProvider    │
   │  SwiftUI viewer + │  │  (library)   │  │  (.appex: read-only   │
   │  Operations panel │  │              │  │   projection)         │
   └─────────┬─────────┘  └──────┬───────┘  └──────────────────────┘
             │ spawns            ▼
             │            ┌──────────────┐
             └──────────▶ │ wikictl (exe)│  the agent's write path
                          └──────────────┘
```

- **`WikiFSCore`** is a separate **dependency-free** library on purpose
  (BRINGUP decision). It holds *all* the deterministic logic, so:
  - it can be **unit-tested** without a running app, a real File Provider, or a
    real `claude` process (the 320-test suite hits the core directly), and
  - the **same** logic is shared by the app (writer + UI), the extension (reader),
    and the CLI (writer) — one schema, one link-reparse, one set of filename
    rules, no drift.
- **`WikiFS`** (the app) is un-sandboxed (see §7) so it can `Process`-spawn
  `claude`/`wikictl` and use the literal App Group path. It owns the SwiftUI views,
  the wiki switcher, domain registration, and the change bridge.
- **`WikiFSFileProvider`** is the `NSFileProviderReplicatedExtension`. Built as an
  executable, then `build.sh` repackages it into a `.appex` under
  `Self Driving Wiki.app/Contents/PlugIns`. Its Mach-O entry point is overridden to
  `_NSExtensionMain` via a linker flag — a Swift `main()` that calls
  `NSExtensionMain()` recurses infinitely on re-invocation and SIGSEGVs (see the
  comment in `Package.swift` and the appex-entry memory).
- **`WikiCtlCore` + `wikictl`** follow the same library/executable split as the
  app: logic in a testable library, a thin process shell on top.

`build.sh` assembles the `.app`, nests the `.appex` under `Contents/PlugIns`,
embeds `wikictl` under `Contents/Helpers` (so the app can spawn it at a stable
bundle-relative path — see `HelpersLocation.swift`), and codesigns **inside-out**
(helper → appex → app). Real signing needs a dev cert + the two profiles under
`signing/`; otherwise it ad-hoc signs and the extension won't load. Details:
[`build-environment.md`](build-environment.md), [`signing.md`](signing.md),
[`file-provider.md`](file-provider.md).

---

## 2. Data model

### Per-wiki SQLite schema

Each wiki is one `<ulid>.sqlite` file. The schema (in
`SQLiteWikiStore.bootstrapSchema()`) is built by a **stepwise, idempotent
`user_version` migration ladder** — each step runs only if the DB is below its
target version, then bumps `user_version`, so a fresh DB runs every step and an
existing DB runs only the new ones:

| `user_version` | Adds | Tables / shape |
| --- | --- | --- |
| **→ 1** | original v0 schema | `pages` (id ULID, title, slug, body, timestamps, version), unique `pages_slug_unique`, `attachments` (FK→pages), `page_links` (from/to FK→pages, link_text) |
| **→ 2** | file ingest | `ingested_files` — verbatim bytes + metadata, **not** tied to a page |
| **→ 3** | agent schema | `system_prompt` singleton (`id INTEGER PRIMARY KEY CHECK(id=1)`), seeded with `SystemPrompt.defaultBody` |
| **→ 4** | chronological log | `log` (id ULID, ts, kind, title, note) — append-only |
| **→ 5** | curated catalog | `wiki_index` singleton (`CHECK(id=1)`), seeded with `WikiIndex.defaultBody` |

The two singletons (`system_prompt`, `wiki_index`) are **rows in that wiki's own
DB** — multi-wiki is "one DB per wiki," so there are no `wiki_id` columns and no
per-query filtering anywhere.

Schema notes worth knowing:

- **Page identity is the ULID** (`PageID`); the `slug` is derived (lowercased,
  `[a-z0-9-]`, collision-suffixed with the first 6 of the ULID). Filenames in the
  projection are *presentation only* — the ULID is always the real identifier.
- **`page_links`** is rewritten wholesale on each upsert by `replaceLinks` (delete
  this page's outgoing links, re-insert the resolved subset; unresolved targets are
  omitted). `deletePage` clears links touching the page first, in one transaction,
  because foreign keys are on.
- **`log` is ordered by `ts, rowid`, NOT by the ULID `id`** — two appends in the
  same millisecond would tie on the ULID's lexical sort and order randomly. `ts` +
  monotonic `rowid` give deterministic insertion order (this was a real flaky-test
  fix; see the most recent `git log`).

### `changeToken()` — the sync anchor

`SQLiteWikiStore.changeToken()` returns a single opaque string that **must advance
on any change that a projected file reflects**, because the File Provider daemon
uses it as the sync anchor (an unequal token forces a re-enumeration / re-fetch).
It folds in seven terms:

```
"<pageCount>:<sumPageVersions>:<fileCount>:<sumFileVersions>:<spVersion>:<logCount>:<idxVersion>"
```

The *why* behind each fold:

- **pages use `count:sum(version)`, not `MAX(version)`** — `version` is per-row, so
  editing a page that doesn't hold the global max would leave `MAX` unchanged and
  the edit would silently stay stale. `count:sum` moves on every create / update /
  delete of any page.
- **`ingested_files` count+sum** — without it, ingesting/removing a file wouldn't
  refresh the `files/` tree.
- **`system_prompt` version** — editing *only* the prompt must still refresh
  `CLAUDE.md`/`AGENTS.md`.
- **`log` count** (append-only, so count suffices) and **`wiki_index` version**
  (UPSERTed like the prompt) — appending only a log entry, or editing only the
  index, must still refresh `log.md` / `index.md`.

Each fold falls back to `0` if its table is absent (a read connection opened
against a not-yet-migrated DB), so the token always answers.

### Registry & container layout

The set of wikis is a `WikiRegistry` (`WikiRegistry.swift`) persisted as
`wikis.json` in the App Group container — a plain `Codable` value type (MRU-ordered,
ULID identity, rename changes only the display name). `WikiManager` is the
`@MainActor @Observable` runtime owner the app binds to; `WikiDescriptor` is one
wiki's record.

`DatabaseLocation.swift` is the single source of truth for *where the bytes live*.
The App Group is `group.org.sockpuppet.wiki`; per-wiki DBs are
`<ulid>.sqlite`. There are **two resolvers for the same inode** because the two
sides reach the container differently:

- the **un-sandboxed app** builds the **literal** path
  `~/Library/Group Containers/group.org.sockpuppet.wiki/…` (it has no app-groups
  entitlement, so `containerURL(forSecurityApplicationGroupIdentifier:)` would
  return nil), while
- the **sandboxed extension** *does* have the entitlement and uses
  `containerURL(forSecurityApplicationGroupIdentifier:)`.

`DatabaseLocation` also holds the one-time legacy migration (the single v0
`WikiFS.sqlite` → wiki #1) and the Application-Support→App-Group migration.

---

## 3. File Provider projection

`Projection` (`Sources/WikiFSFileProvider/Projection.swift`) maps SQLite to the
read-only tree. It is bound to **one wiki** via `wikiID`; `openReadStore()` opens a
fresh, short-lived **read-only** store at that wiki's `<ulid>.sqlite` per request
(the app is the only writer; WAL + `query_only=ON` make concurrent reads safe —
note `SQLiteWikiStore.init(readOnlyURL:)` opens read-*write* and sets
`query_only=ON` rather than `SQLITE_OPEN_READONLY`, so the `-shm` attaches even when
no writer is live).

The projected root, per wiki:

```
<mount root>/
├── README.md            (static)
├── CLAUDE.md            ─┐ same system_prompt body, identical bytes,
├── AGENTS.md            ─┘ versioned by the singleton row version
├── index.md             curated wiki_index body (verbatim)
├── log.md               whole `log` table → grep-able lines (LogRenderer)
├── TREE.md              fixed layout map + live page/file counts (WikiTreeRenderer)
├── manifest.json        generated (IndexGenerators)
├── pages/
│   ├── by-id/<ulid>.md
│   └── by-title/<escaped>--<id8>.md
├── files/
│   ├── by-id/<ulid>.<ext>     verbatim ingested bytes
│   └── by-name/<name>
└── indexes/
    ├── pages.jsonl
    ├── links.jsonl
    └── files.jsonl
```

Key mechanics:

- **Per-domain wiring.** `FileProviderExtension.init(domain:)` builds
  `Projection(wikiID: domain.identifier.rawValue)`. The File Provider instantiates
  **one extension per domain**, so the domain identifier *is* the wiki ULID — no
  registry read needed in the extension. Every mutating op (`createItem`,
  `modifyItem`, `deleteItem`) returns a read-only error.
- **Size/content consistency.** A file node's reported `documentSize` and the bytes
  served by `contents(for:)` must derive from the *same* `Data`, or `cat`
  truncates. For the three generated index files this is enforced by a token-keyed
  byte cache (`IndexCache`, keyed `(wikiID, identifier, token)`); for pages/files
  it's the SQLite row read live in both paths.
- **Versioning drives refresh.** Single-row docs (pages, files, `CLAUDE.md`,
  `index.md`) are versioned by their row `version`; multi-row docs (`log.md`,
  `TREE.md`) and the generated indexes are versioned by the **change token**, so
  they re-fetch exactly when the relevant fold moves.
- **The refresh path & the ~5 s window.** A write advances the token; the app
  `signalEnumerator`s the domain; *later*, the daemon calls `enumerateChanges`,
  sees the higher `itemVersion`, discards its materialized replica, and the **next**
  read re-fetches from SQLite. Nothing in the code is stale — we wait on the daemon.
  The working-set enumeration re-emits all page/file nodes **plus** the generated
  index and root-doc nodes, because the index bytes derive from page/file content
  and must be invalidated together. Full reasoning in [`ISSUES.md`](../ISSUES.md).
- **One domain per wiki.** Registration lives in the app (`FileProviderSpike.swift`).
  `DomainRegistrationPolicy` hardens it: after each `add(domain)` it **verifies** the
  domain appears in `NSFileProviderManager.domains()`, **retries** with backoff on a
  busy daemon (async, never blocking the main actor), **nudges** the new domain's
  enumerator so it materializes promptly, and **surfaces** real failures instead of
  swallowing them.

---

## 4. Read/write split & the change bridge

```
  app editor ──save──▶ SQLiteWikiStore (write) ──▶ onPageDidChange ──▶ signalChange(domain)
                                                                              │
  wikictl  ──page upsert / log append / index set──▶ SQLite (write)          │
       │                                                                      │
       └── DarwinNotifier.postChange(forWikiID) ──▶ org.sockpuppet.wiki.changed.<ulid>
                                                          │
                                          WikiChangeBridge observes (per wiki)
                                                          │  ChangeCoalescer (~250 ms)
                                                          ▼
                                   rebuild sidebar (if on-screen) + signalChange(domain)
```

- **`wikictl` is the read AND write path; the mount is an optional read-only projection.** It opens
  the wiki's DB read-write via the literal App Group path (WAL + `busy_timeout=5000`
  make a second writer process safe), runs one command, prints to stdout, and — only
  after a **committing** call — posts the Darwin notification. It **never** signals
  the File Provider itself: the app is the single owner of FP signaling per domain.
- **Darwin notifications carry no payload**, so the wiki id lives in the notification
  *name*: `org.sockpuppet.wiki.changed.<ulid>` (`WikiChangeNotification`). The app
  subscribes to exactly that name for each registered wiki, so its observer knows
  which wiki changed with no demux table.
- **`WikiChangeBridge`** (app) observes those names, hops to the main actor, and
  feeds a **per-wiki `ChangeCoalescer`** (a pure, fake-clock-testable ~250 ms
  debounce — one ingest fires a burst of `wikictl` calls and we want one rebuild +
  one FP signal, not fifteen). On flush it rebuilds the active store's summaries (if
  that wiki is on screen) and `signalChange(forWikiID:)`s that wiki's domain.
- **`PageUpsert` is the shared seam.** "Create-or-update a page, then reparse
  `[[links]]` and rewrite `page_links`" lives in one place
  (`WikiFSCore/PageUpsert.swift`) and is called by **both** the app's save path and
  `wikictl page upsert`, so a CLI write and an in-app write leave byte-identical link
  rows. The `wikictl page get` read prints the body straight from SQLite — the
  instant-source-of-truth escape hatch that bypasses the ~5 s mount lag.

---

## 5. The `claude -p` operations

The app runs three discrete operations against the **active** wiki: **Ingest**,
**Query**, **Lint** (`plans/llm-wiki.md` Phase C). The design keeps everything
deterministic *except the agent itself* behind pure, unit-tested seams:

- **`WikiOperation`** (core, pure) — the operation enum + its **own `-p` prompt**.
- **`OperationCommand`** (core, pure) — assembles the exact `claude` argv, env, and
  cwd. Unit tests assert the precise flag surface without spawning anything.
- **`OperationRequest`** + **`AgentStaging`** (app + core) — the per-op intent and
  the pure path/snapshot math for staging.
- **`AgentLauncher`** (app, `@MainActor @Observable`) — owns the scratch dir, does
  the staging, spawns the `Process`, parses the stream, and holds the edit lock.

What a run actually looks like:

```
cd <per-run writable scratch dir>          # Claude Code needs a writable cwd; the mount is read-only
    WIKI_DB=<wiki ULID>                    # selects the wiki for wikictl (no --wiki flag needed)
    PATH=<Contents/Helpers>:<inherited>    # so the agent's `wikictl` resolves
claude -p "<operation prompt>"
    --model opus                           # top-level is ALWAYS opus (the curator/writer)
    --output-format stream-json --verbose --include-partial-messages
    --append-system-prompt "<this wiki's system_prompt body>"
    --dangerously-skip-permissions
   [--agents '{"source-reader":{…,"model":"sonnet","tools":["Bash","Read"]}}']   # large Ingest only
```

Decisions baked in here, each with a hard-won reason:

- **Staging from SQLite, not the mount.** The agent reads via `wikictl` (DB-direct), not the mount. `AgentLauncher` stages a `WIKI_STATE.md`
  snapshot (page titles + `index.md` + log tail, via `WikiStateSnapshot`) and, for
  Ingest, the raw `source.<ext>` bytes (via `ingestedFileContent`) into scratch —
  read from SQLite, not the ~5 s-laggy mount. The prompt names those absolute paths
  and forbids re-discovery (`IngestWriteRule.dontRediscover`).
- **The write rule lives in the `-p` prompt, not only the schema.**
  `IngestWriteRule.writes` leads every *writer* prompt with the read-only-by-design
  rule, "read and write via `wikictl`, never read from the mount," and the exact
  `wikictl` write commands. Phase D had moved this entirely into
  `--append-system-prompt`; a live run showed the agent *under-weighting* it —
  printing "the mount is read-only, there must be a mutation tool, let me search,"
  running ToolSearch, then `echo > pages/by-title/__wikitest__.md` to probe the
  mount. So the load-bearing rule is in the system prompt; the broader
  layout/conventions stay in the schema (DRY — asserted both ways in
  `OperationCommandTests`). The Sonnet digester never writes, so it carries no write
  rule.
- **`--dangerously-skip-permissions`.** The fine-grained `--allowedTools` allowlist
  is incompatible with the `$WIKI_ROOT`/`$WIKI_DB` env-var paths and compound shell
  commands the design depends on (the CLI can't statically verify a command with a
  shell expansion, so it demands an approval that doesn't exist in `-p` mode — the
  run dies with zero output). It's also required for the Task tool that drives the
  fan-out. The app is local, un-sandboxed, and user-initiated, so we bypass.
- **Ingest tiering (`IngestPlan`).** The app picks the mode by source size
  (`decide(sourceByteSize:)`, threshold `tinySourceByteThreshold = 4096`):
  - **tiny (`< 4 KB`) → `.singleOpus`** — one Opus pass reads the small source and
    writes pages + index + log itself, no `--agents`.
  - **large → `.opusCurator`** — Opus is the curator: it inspects the source's
    size/structure *without* reading the bulk, splits it into chunks, and fans out
    to **2–19** Sonnet `source-reader` **digesters** (`--agents`, read-only
    `["Bash","Read"]`, no `wikictl`) that return structured digests. Opus then
    synthesizes, decides the page set, and **writes every page + `index.md` + the log
    entry itself**, optionally forking follow-up questions or pulling pages with
    `wikictl page get` to double-check (the `<20` cap is on total Sonnet
    invocations). The top-level `--model` is `opus` in **both** modes; the tiering is
    purely in the fan-out. (Verified against CLI 2.1.178: `opus` →
    `claude-opus-4-8`, `sonnet` → `claude-sonnet-4-6`.)
- **Query / Lint** are single-Opus runs (still get the write rule + staged state, as
  they may file an answer/report page and always log).
- **Live streaming.** `--output-format stream-json` NDJSON is parsed line-at-a-time
  by `AgentEventParser` into typed `AgentEvent`s (system-init, assistant text,
  tool-use with a human-readable input summary, tool-result, **subagent** fan-out
  rows, final result) rendered live in `AgentActivityView`. The parser is *tolerant*
  — any line it can't map becomes `.raw`, never a crash. The raw stream also lands in
  a backend `run.jsonl` (+ `run.stderr.log`) in scratch for post-hoc debugging.
- **The edit lock.** `onLock`/`onUnlock` fire around the run (unlock from the
  `terminationHandler`, so even a killed agent releases it), making the in-app editor
  read-only during a run to prevent the autosave-vs-`wikictl` clobber race.
- **The schema as the structure layer.** `SystemPrompt.defaultBody` (projected as
  `CLAUDE.md`/`AGENTS.md`, delivered via `--append-system-prompt`) documents the
  layout, conventions, the `wikictl` reference, the read-after-write rule, and the
  three workflows. It's the evolvable "schema" the user co-edits in-app over time.

---

## 6. URL ingest

`URLIngestService` (core) is the fetch → dispatch → store pipeline with an
**injected** `URLResourceFetcher`, so dispatch/filename/store logic is unit-tested
with a fake fetcher (no real network in tests). Flow:

1. **Fetch** — `URLSessionFetcher` (production impl): ephemeral `URLSession`, a
   desktop Safari User-Agent (so sites don't 403), follows HTTP redirects and
   reports the final URL, bounded timeout, non-2xx → `httpStatus` / transport →
   `network`. The app is un-sandboxed, so this needs no entitlement and fires no
   prompt.
2. **Share-link normalize** — `ShareLinkNormalizer.normalize(_:)` runs **before** the
   request. Dropbox `www.dropbox.com`/`dropbox.com` → `dl.dropboxusercontent.com`
   (preserving path + query so the `.pdf` filename and `rlkey`/`e` auth params
   survive). Unrecognized URLs pass through byte-for-byte; Google Drive / OneDrive
   shapes are stubbed for trivial add-later.
3. **Content-sniff** — `plan(for:)` reads leading magic numbers (`%PDF`, `\x89PNG`,
   `\xFF\xD8\xFF`, `GIF8`, `PK\x03\x04`) and, when the *declared* type is ambiguous
   (`text/html`, missing, `application/octet-stream`), stores clearly-binary bytes
   verbatim as the sniffed type — the backstop if an interstitial slips past the
   normalizer. A specific declared type is trusted as-is.
4. **Convert or store verbatim** — `text/html`/`xhtml` → `HTMLToMarkdown` (a
   hand-rolled tokenizer + streaming renderer + entity decoder; **not**
   `NSAttributedString(html:)`, which is WebKit-backed, main-thread-only, and
   untestable) stored as `.md` named from `<title>`; `application/pdf` → verbatim
   `.pdf`; other `text/*` → verbatim; else → verbatim bytes with an inferred ext.
5. **Store** through the **same** `store.ingestFile` path as a drag-dropped file, so
   the result shows up under `files/` and is pickable in Operations → Ingest.

---

## 7. Key invariants, decisions & gotchas

- **Read-only mount, SQLite as SoT** (§ everything). The extension rejects every
  mutation; writes only ever go through `wikictl`. Do not "fix" the read-after-write
  lag by reading through to SQLite on every `cat` — that abandons the replicated
  model, which is the POC.
- **The app is un-sandboxed** (`WikiFS/WikiFS.entitlements` has no
  `com.apple.security.app-sandbox`). Why: it must `Process`-spawn `claude`/`wikictl`,
  and it uses the **literal** App Group path (no app-groups entitlement). The
  *extension* is sandboxed and entitled. `wikictl` needs no entitlements — it's an
  un-sandboxed helper writing user-owned files, launched by the un-sandboxed app.
- **Dependency-free.** Hand-wrapped SQLite C API, hand-rolled HTML→Markdown, no
  SwiftPM package deps.
- **Identity is the ULID.** The domain identifier ↔ DB filename mapping is the wiki's
  ULID, never its display name, so a rename never orphans the file or wedges the
  domain.
- **Pure-core / thin-shell split** keeps the non-deterministic surface (the agent,
  the File Provider daemon, the network, SwiftUI) small and the deterministic surface
  (schema, link graph, argv, prompts, parsing, ingest dispatch) fully unit-tested.
- **Gotchas → [`ISSUES.md`](../ISSUES.md):** the ~5 s replica read-after-write window;
  a heavily-churned domain replica can wedge (use a fresh wiki for live gates); the
  macOS-26 TCC "access data from other apps" prompt on first/re-signed launch; and
  kill-mid-ingest can leave partial state (a page written but `index.md`/`log.md` not
  yet — no cross-call transactionality, accepted for the POC).
