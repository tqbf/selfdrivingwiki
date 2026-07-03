# Graph model & versioning — objects, refs, and the concurrency substrate

**Status:** design accepted; Phase 0 (concurrency substrate) implemented on branch
`graph-model-and-versioning`. Successor to
[`source-versioning-and-providers.md`](source-versioning-and-providers.md)
(draft at `tqbf/selfdrivingwiki@c80e566`) — every decision locked there is
preserved unless explicitly amended in §2.

**The organizing idea:** import git's storage discipline into the wiki's SQLite.
Immutable, content-addressed **blobs** (git's objects) need no locks and no
coordination — any process may read them forever. Append-only **version rows**
give every source a history that writers can extend without conflicting. All
mutation is squeezed into a tiny **refs** table where "refresh", "rollback",
and "switch extraction" are each a one-row repoint. Versioning, dedup,
provenance, byteless sources, rich media, generative UI, and concurrency stop
being seven features and become one model.

---

## 1. Why not a graph database (the CozoDB decision)

The question that started this design was "should we move to CozoDB?" The
answer is **no**, recorded here so it isn't relitigated without new facts:

- **Concurrency gets worse, not better.** Cozo's Swift bindings ship only the
  in-memory and SQLite storage engines; Cozo-on-SQLite is single-writer behind
  a process-internal lock, and the multi-writer RocksDB backend is both absent
  from the Swift build and single-process (it takes a `LOCK` file). Our
  architecture is **three processes on one file** — app writer, `wikictl`
  writer, File Provider reader — which plain WAL already serves and Cozo
  cannot: Cozo stores relations as opaque KV encodings, so `wikictl` and the
  extension could no longer open the DB and read meaningful rows. Everything
  would have to funnel through the app over XPC — a daemonization rewrite.
- **The maintenance bet is bad.** Cozo is a single-author project whose last
  tagged release is years old. Kuzu — the best-funded embedded graph DB — was
  archived in October 2025 after an Apple acqui-hire. SQLite is the most
  deployed software artifact on Earth and this app's dependency-free stance
  (BRINGUP) is a feature.
- **We need the graph *model*, not a graph *engine*.** A wiki has thousands of
  nodes, not millions; there are no unbounded multi-hop traversals dominating
  the workload. Typed edge tables + recursive CTEs cover the query surface.
  `page_links` / `source_links` already are the graph.
- **The one thing Cozo genuinely offers** — time-travel queries over a
  `Validity` type — is physically the same thing as our append-only version
  rows (full fact copies per interval), minus control. We build the same
  capability as schema, below.

*Escape hatch, if ever wanted:* run Cozo **in-memory, in-app only**, as a
derived Datalog index rebuilt from SQLite (the same relationship FTS5 and the
chunk embeddings already have to the base tables). Zero durability bet, trivial
to delete. Not planned; noted.

## 2. Amendments to the draft plan

The draft's three layers (content versioning, extraction alternatives, unified
providers), its locked decision table, provenance grouping, `@` version-pin
sigil, and byteless sources all stand. Four amendments:

| # | Amendment | Replaces | Why |
|---|-----------|----------|-----|
| A1 | **Content-addressed `blobs` table** under `source_versions` and extraction rows | inline `content BLOB` per version | Dedup for free (unchanged re-fetch appends ~100 bytes, not megabytes); `revert` becomes a pointer copy; immutable rows are readable by any process/thread with zero coordination |
| A2 | **`refs` table** for active-version pointers | `sources.active_content_version_id` / `active_markdown_version_id` columns | One uniform mutation shape (kind, owner, version) → one changeToken fold, one audit surface, one CAS discipline; adding a new pointer kind is a row, not a migration |
| A3 | **Roles + pins on reference edges** (`cite` / `embed` / `render`), `![[source:…]]` embed sigil | `source_links` as untyped edges | The whole rich-media story (embed video/image, render generative UI) is edge metadata, not new tables; Obsidian-compatible embed syntax |
| A4 | **ULID-canonical link targets, normalized at save time**, display resolved at render time | Phase B locked Decision 1 (`?title=`, name-canonical bodies) | Renames become one-row metadata updates; see §6 for why Decision 1's premises no longer hold |

And one addition the draft explicitly deferred that this design treats as a
**prerequisite**, not a phase: the concurrency substrate (§8), because every
later phase multiplies writers (provider fetches, extraction runs, agent
ingests) and the current store crashes under a second thread.

## 3. Current state (grounded)

What the sweep of the code established — the facts the schema must respect:

- `sources.content` is `BLOB NOT NULL` (`SQLiteWikiStore.swift:186`): there is
  no byteless concept, no dedup (re-dropping a file makes a new ULID row), a
  100 MB cap (`ingestByteCap`, line 1251), and full-load I/O (no incremental
  blob API anywhere).
- `source_markdown_versions` is already an append-only full-snapshot chain —
  but `parent_id` has **no FK and is never read**; HEAD is `MAX(id)` (ULID
  order, `processedMarkdownHead`, line 2541). Four `origin` values exist in
  code: `extraction`, `source`, `user`, `revert` (the doc comment omits
  `source`). `revert` copies content wholesale.
- **No extraction provenance exists**: which backend/model produced an
  `extraction` version lives only in debug logs. **URL-ingested sources do not
  persist their origin URL at all** — the filename stem is the only trace.
  `provider_runs` has nothing to backfill from; provenance starts at zero.
- Links are name-canonical in bodies. Page rename rewrites nothing; other
  pages' `[[Old Title]]` go ghost, and on their next save `replaceLinks`
  **silently drops** the row (unresolved targets are omitted, line 1165) — the
  `save()` comment's "self-heal" claim is wrong in the harmful direction.
  Source rename does rewrite bodies (`renameSource`, line 1372) but is
  deliberately non-transactional because `updatePage`/`replaceLinks` each own
  `BEGIN IMMEDIATE` and raw `BEGIN` doesn't nest.
- Two resolution tiebreaks coexist: pages pick lowest ULID (oldest), sources
  pick `updated_at DESC` (newest). `resolveSourceByName`'s fallback pass is a
  full-table scan run *inside* `replaceLinks`' write transaction.
- Quote fragments (`#"…"`) resolve against the HEAD extraction at scroll time;
  reprocessing a source silently kills existing highlights. `source_links`' PK
  `(from_page_id, to_source_id)` cannot represent a pinned or role-typed edge.
- `changeToken()` is an 8-field fold (`pages` count+sum, `sources` count+sum,
  `system_prompt` version, `log` count, `wiki_index` version,
  `source_markdown_versions` count). Tests hard-code the 8-field literal.
- The store is one connection + a prepared-statement cache keyed by SQL text,
  `@unchecked Sendable`, main-thread-only **by convention**; the six
  transaction sites use raw `BEGIN IMMEDIATE` and are not re-entrant.
  `init(databaseURL:)` performs writes at open (migrations, search self-heal);
  only `init(readOnlyURL:)` is side-effect-free.

## 4. The schema

Four table families. Everything below is additive to v17 and follows the
existing stepwise ladder discipline (each step guarded on `user_version`,
fresh-path block kept in parity — `freshFastPathMatchesStepwiseLadder`).

### 4.1 `blobs` — immutable objects (A1)

```sql
CREATE TABLE blobs (
    hash       TEXT PRIMARY KEY,     -- lowercase hex SHA-256 of content
    byte_size  INTEGER NOT NULL,
    content    BLOB NOT NULL
);
```

- Write path: `INSERT OR IGNORE` — identical bytes are stored once, ever.
- No mime, no name, no timestamps: those are *claims about a use of the bytes*
  and live on the referencing row. The same bytes cited twice with different
  mimes is legal and correct.
- No changeToken fold needed: blobs are unreachable except through version
  rows, which do fold.
- GC: a blob is garbage when no `source_versions.blob_hash`,
  `source_versions.thumbnail_hash`, or `source_markdown_versions.blob_hash`
  references it. Deleting a source cascades its versions; a lazy
  `wikictl admin vacuum-blobs` (and an app maintenance hook) sweeps orphans.
  Nothing depends on eager GC.
- The 100 MB `ingestByteCap` stays, enforced at ingest before hashing.

### 4.2 `source_versions` + `provider_runs` — the append-only history

```sql
CREATE TABLE provider_runs (
    id            TEXT PRIMARY KEY,          -- ULID
    provider_kind TEXT NOT NULL,             -- 'local' | 'url' | 'zotero' | 'folder' | 'git' | …
    query         TEXT,                      -- what was asked (URL, search string, item key)
    external_ref  TEXT,                      -- provider-scoped stable identity of the fetched thing
    fetched_at    REAL NOT NULL
);

CREATE TABLE source_versions (
    id              TEXT PRIMARY KEY,        -- ULID; chain order = ULID order (existing convention)
    source_id       TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
    parent_id       TEXT,                    -- lineage, informational (matches smv convention)
    blob_hash       TEXT REFERENCES blobs(hash),   -- NULL = byteless/external
    mime_type       TEXT,
    original_path   TEXT,                    -- path within the fetch (sibling resolution, §7)
    thumbnail_hash  TEXT REFERENCES blobs(hash),   -- presentation only
    provider_run_id TEXT REFERENCES provider_runs(id),
    external_identity TEXT,                  -- e.g. the YouTube video id, the canonical URL
    fetched_at      REAL NOT NULL
);
CREATE INDEX source_versions_source ON source_versions(source_id, id);
```

- **Refresh appends; nothing updates.** A re-fetch whose bytes are unchanged
  appends a version row pointing at the *same* `blob_hash` — history records
  "checked at T, unchanged" for the cost of a row.
- **Byteless sources** are `blob_hash IS NULL` + provenance
  (`external_identity`, `provider_run_id`) + optional thumbnail. Their working
  material is the active derived alternative (transcript), exactly per the
  draft.
- `provider_run_id` lives on the **version** (each fetch is a run), while
  `role` lives on the **source** (§4.4) — a media child is media in every
  version. Sibling resolution joins versions through their shared run.
- `sources` keeps identity + presentation: `id`, `filename`, `ext`,
  `display_name`, `role`, zotero columns (legacy provenance, retained),
  timestamps, `version` counter. `content`, `byte_size`, `mime_type` migrate
  into v1 version rows (migration in §9).

### 4.3 `refs` — the only mutable pointer state (A2)

```sql
CREATE TABLE refs (
    kind       TEXT NOT NULL,     -- 'source-content' | 'source-derived'
    owner_id   TEXT NOT NULL,     -- sources.id
    version_id TEXT NOT NULL,     -- source_versions.id | source_markdown_versions.id
    generation INTEGER NOT NULL DEFAULT 1,   -- bumped on every repoint (changeToken fold)
    updated_at REAL NOT NULL,
    PRIMARY KEY (kind, owner_id)
);
```

- `source-content` → the active content version (draft's
  `active_content_version_id`). `source-derived` → the active extraction
  alternative (draft's `active_markdown_version_id`).
- Refresh = insert blob + insert version + `UPSERT` one ref (generation+1).
  Rollback = repoint one ref. Both are milliseconds inside one transaction.
- **Default-active rule** (draft open question #2, resolved): when no ref row
  exists, the active version is `MAX(id)` for that owner — i.e. today's exact
  HEAD semantics. A ref row is only written when someone *chooses*; absence
  means "track latest". This makes migration free (no ref backfill) and keeps
  `wikictl`-written chains live-tracking by default.
- changeToken gains one fold: `COALESCE(SUM(generation), 0)` over `refs`
  (plus a `source_versions` count fold and a `provider_runs` count fold; §10).

### 4.4 Edges — roles and pins (A3)

`page_links` is untouched. `source_links` is rebuilt (v11-style
rename→create→copy→drop) as:

```sql
CREATE TABLE source_links (
    from_page_id      TEXT NOT NULL REFERENCES pages(id),
    to_source_id      TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
    link_text         TEXT NOT NULL,
    role              TEXT NOT NULL DEFAULT 'cite',   -- 'cite' | 'embed' | 'render'
    pinned_version_id TEXT,                           -- NULL = follow the active ref
    PRIMARY KEY (from_page_id, to_source_id, role)
);
```

- `cite` — today's `[[source:…]]`: a reference, rendered as a link.
- `embed` — `![[source:…]]` (Obsidian's embed sigil): the renderer inlines the
  content — `<img>` for images, `<video>`/player for media, an iframe/player
  keyed on `external_identity` for byteless YouTube-style sources.
- `render` — an embed whose target's active derived alternative is a
  generative-UI spec (§7); the renderer mounts the interactive artifact.
- Existing rows copy over with `role='cite'`, `pinned_version_id=NULL` —
  byte-identical behavior.

### 4.5 Extraction alternatives (draft Layer 2, + CAS)

`source_markdown_versions` keeps its table name (three renames is enough) and
gains, per the draft: `extraction_technique TEXT` (backfilled `'legacy'`;
new writes record `pdf2md`, `claude-opus-4-8`, `whisper-large-v3`,
`user-edit`, …) and `source_version_id TEXT` (backfilled to the source's v1
content version). Two amendments:

- `content TEXT` is joined by `blob_hash TEXT REFERENCES blobs(hash)`; new
  rows write the blob and leave `content = ''`; readers prefer the blob.
  `revert` becomes a new row pointing at the target's hash — a pointer copy.
  (Old rows keep inline content until a one-time backfill migrates them; the
  read path handles both forever.)
- `mime_type TEXT DEFAULT 'text/markdown'` — a derived alternative is not
  necessarily markdown. A Whisper transcript is `text/vtt`-ish markdown; a
  generative-UI spec is `application/vnd.wiki.jsonrender+json` (§7). "The
  transcript is bad, keep both, compare, nominate" (the draft's core Layer-2
  insight) applies identically to UI specs.

HEAD determination changes from `MAX(id)` to "the `source-derived` ref if
present, else `MAX(id)`" — one query, default-compatible.

## 5. The graph, named

With the tables above, the wiki *is* this typed property graph — queryable
with plain SQL and recursive CTEs, no engine required:

```
nodes:  page · source · source_version · smv (derived alternative) · provider_run · blob
edges:  page        —links(link_text)→                    page          (page_links)
        page        —refers(role, pin)→                   source        (source_links)
        source      —has-version→                          source_version (FK)
        source_ver  —derived-from(lineage)→                source_version (parent_id)
        smv         —extracted-from(technique)→            source_version (source_version_id)
        source_ver  —produced-by→                          provider_run  (FK)
        refs        —active→                               version rows   (the only mutable edges)
        version/smv —content→                              blob          (hash)
```

Example queries this unlocks (candidates for a `wikictl graph` verb, later):
"pages citing any version derived from this provider run" (join through
`provider_run_id`), "orphan sources" (anti-join on `source_links`), "what did
this page's embedded video look like when the page was written" (pin +
version), "everything downstream of this blob" (hash back-joins).

## 6. ULID-canonical links (A4)

**Decision: link targets become ULIDs at rest; humans and agents keep writing
titles; displays resolve at render time.**

Phase B's Decision 1 ("no `?id=` anywhere") was made for the *render-time URL
contract* when bodies were name-canonical and renames were rare. The sweep
shows the premises broke: renames silently **drop** link rows on next save;
`renameSource` exists only to compensate (a non-atomic multi-page body
rewrite); resolution runs full-table scans inside write transactions; two
different tiebreak conventions decide ambiguity; ASCII-only case folding
misses non-ASCII titles. All of it is the cost of storing display names as
identity.

The shape that keeps authoring ergonomic *and* storage stable:

1. **Authoring is unchanged.** Agents and users write `[[Some Title]]`,
   `[[source:Display Name]]`, `![[source:Video]]`. Nothing about `wikictl`
   prompts or human habits changes.
2. **Save-time canonicalization** (in `PageUpsert`, the single shared seam):
   each resolvable link is rewritten in the stored body to
   `[[page:01H…|Some Title]]` / `[[source:01J…|Display Name]]` — ULID target,
   the human text preserved as the alias. Unresolvable links stay exactly as
   written (they are *forward links*; today they vanish from the graph — a
   later phase may add a `pending_links` table, out of scope here).
3. **Render-time display**: the renderer resolves ULID → *current*
   display name and prefers it over the stored alias, so a stale alias
   self-heals visually without touching bytes. This is the true
   display-at-render resolver (today's `DisplayNameResolver` is ingest-time
   metadata extraction — a different thing, kept).
4. **Rename collapses to one row.** Page rename = `UPDATE pages SET title`.
   Source rename = `UPDATE sources SET display_name`. `renameSource`'s
   body-rewrite loop, `WikiLinkRewriter`'s rename path, and the rename-drops-
   links bug all become structurally unnecessary. (The rewriter stays for the
   one-time body migration and the save-time normalizer.)
5. **`wiki://` URLs carry `?id=`** (with `title=` kept alongside during
   transition); click-time resolution becomes a direct row fetch.
   `replaceLinks` stops resolving names inside its transaction — parse
   already-canonical ULIDs and validate existence.

**Pinning** composes here, per the draft's `@` sigil:
`[[source:01J…@v3|Name]]`, `![[source:01J…@v3#"quote"|Name]]`. `@vN` (ordinal
within the chain, human-writable) resolves to a version ULID at save time and
lands in `source_links.pinned_version_id`. No `@` = follow the ref. Quote
fragments resolve against the *pinned* version's content — fixing today's
silent highlight loss on reprocess for pinned links, and giving "the webpage
as I read it" reproducibility.

**Costs, named honestly:** raw markdown in the editor shows
`[[page:01H…|Title]]` — noisier than `[[Title]]`. Mitigations: the alias keeps
it readable and greppable; an editor pretty-display pass is deferred (open
question #3). Migration is a one-time body rewrite over all pages (§9), the
riskiest step of the link track — it reuses the battle-tested
`WikiLinkRewriter` splice machinery (code-fence-safe, alias/fragment-
preserving) and is fully dry-runnable (`wikictl lint --fix-links --dry-run`).

## 7. Rich media & generative UI — one rendering rule

The renderer's dispatch is a single rule: **resolve the edge to a version, then
dispatch on content type.** No widget registry, no special cases.

- `![[source:…]]` → resolve pin/ref → version:
  - `image/*` → `<img>` served from the blob (bytes are immutable → cache
    forever by hash).
  - `video/*` / `audio/*` with bytes → native `<video>`/`<audio>` (WKWebView
    handles these already).
  - byteless + `external_identity` → provider-shaped embed (YouTube iframe,
    etc.), thumbnail as poster.
  - `application/pdf` → the existing PDF view, inline-framed.
- A `render` edge (or an embed whose active derived alternative is
  `application/vnd.wiki.jsonrender+json`) → the generative-UI path: the JSON
  spec is fetched from the blob store and mounted by a json-render runtime in
  the reader's WKWebView. **The spec is just a derived alternative** —
  produced by an extraction run (`technique: 'claude-opus-4-8-jsonrender'`,
  `source_version_id: <the CSV/data snapshot it visualizes>`), versioned,
  comparable, revertable, pinnable like every other extraction. "Regenerate
  the chart" = run extraction again = new alternative; "the chart was better
  before" = repoint one ref.
- **Provenance-sibling resolution** (draft §media, kept): a website snapshot's
  HTML keeps its original relative `<img src="images/foo.png">`; at render
  time the renderer resolves `images/foo.png` against sibling sources' current
  versions *in the same provider run* by `original_path`. Nothing is rewritten
  in stored text. `original_path` collisions within a run (draft open question
  #5, resolved): first match in ULID order wins, and the fetch layer must
  disambiguate at materialize time by suffixing (`images/foo-2.png`) — the
  same rule `MarkdownFolderReader` already applies to duplicate filenames.
- Media sources (`role='media'` on `sources`) are filtered from the main
  Sources list, surfaced inline and under a disclosure on their primary — per
  the draft, unchanged.

## 8. The concurrency substrate (Phase 0 — implemented with this doc)

The current store is main-thread-only because of three structural hazards, not
because of SQLite: (1) the statement cache hands two callers of byte-identical
SQL the same `sqlite3_stmt*` (the `String(cString:)` crash); (2) the
`statements` dictionary itself is unguarded; (3) raw `BEGIN IMMEDIATE` doesn't
nest, which is the *stated reason* `renameSource` is non-atomic. Every future
phase multiplies concurrent writers (provider fetches, extraction runs, agent
ingests, UI), so this is the prerequisite, fixed as:

1. **Method-atomic store.** `SQLiteWikiStore` gains an internal
   `NSRecursiveLock`; every public entry acquires it for the full method body.
   The statement-aliasing race and the dictionary race become structurally
   impossible from *any* thread. (Recursive, because public methods compose:
   `renameSource` → `updatePage` → …). `FULLMUTEX` keeps guarding the C layer;
   the lock guards the app layer — the gap the skill documents.
2. **Nestable transactions.** A `withTransaction` primitive: depth 0 issues
   `BEGIN IMMEDIATE` (the existing early-write-lock discipline), nested calls
   issue `SAVEPOINT`s. The six raw transaction sites convert; **`renameSource`
   wraps in `withTransaction` and becomes atomic** — the phase-d
   "eventually consistent" caveat is retired. Best-effort side effects
   (`try? reembedSource`) keep their semantics: a failed inner savepoint rolls
   back only itself.
3. **`WikiReadPool`.** A small pool vending read-only snapshot connections
   (`init(readOnlyURL:)` — no migrations, no self-heal, `query_only=ON`), each
   with its *own* statement cache. WAL gives each read a consistent snapshot
   concurrent with the writer. First clients: the debounced page/source
   searches, which move off the main thread entirely (FTS + vec cosine over a
   pool reader). The omnibox, existence-set builds, and projection-style reads
   are natural follow-on clients.
4. **Values-only across boundaries.** Unchanged but now load-bearing: reads
   return decoded Swift structs; no statement handle or column pointer ever
   escapes a method. (`SQLiteStatement` already copies bytes out immediately.)
5. **What deliberately does *not* change:** writes still flow through the
   `@MainActor` model — they mutate observable UI state, and the synchronous
   write-then-reload contract at ~100 call sites is good UX, not a bug. The
   `WikiStore` protocol stays synchronous. The blocking-modal upgrade pattern
   survives but is no longer the only safe shape: with a method-atomic store,
   a future bulk job may run wholly off-main and post progress, provided it
   coordinates with the model (open question #4). Cross-process behavior
   (wikictl second writer, FP reader) is untouched — WAL + `busy_timeout`
   already handle it.

The `sqlite-concurrency` skill and the AGENTS.md invariant are updated in the
same change: the invariant shifts from *"never touch the store off-main"* to
*"the store is method-atomic; reads may go off-main via `WikiReadPool`; writes
go through the main-actor model; never hold connection state across calls."*

## 9. Migration & compatibility

Additive ladder steps (v18…), each independently shippable; the fresh-path
block extends in parity, enforced by the existing test:

1. **v18 — Phase 0 has no schema.** (Concurrency is code-only.)
2. **v18: `blobs`, `provider_runs`, `source_versions`, `refs`** created empty;
   then the backfill: for each source, hash `content` → `INSERT OR IGNORE`
   blob → insert v1 version row (`parent_id NULL`, `fetched_at = created_at`)
   → *leave `sources.content` in place*, unread by new code. This is the
   draft's "keep a nullable copy during a transition build" answer to its
   highest-risk open question #1: the column is dropped only in a later step
   (table rebuild) after a release has soaked. Reads go through
   `sourceContent(id:)` which now resolves ref → version → blob, so the
   call-site surface (wikictl `cat`/`export`, FP projection, agent staging)
   doesn't change signatures.
3. **v19: extraction columns** (`extraction_technique`, `source_version_id`,
   `blob_hash`, `mime_type`) + backfills (`'legacy'`, v1 version id). Optional
   one-time content→blob backfill for old rows.
4. **v20: `source_links` rebuild** with `role`/`pinned_version_id`
   (copy-over `role='cite'`).
5. **Link canonicalization** (Phase D) is a *data* migration, not schema: a
   guarded one-time body rewrite (dry-runnable via lint), then the save-path
   normalizer keeps it invariant.
6. **Pre-migration readers** (FP extension binary skew — three separately
   compiled processes share the file): every new fold and read falls back via
   `try?` exactly like the existing token fields; new tables absent → fold 0.
   The projection's size==content invariant is preserved because
   `documentSize` and `contents(for:)` both derive from the same version row.

## 10. changeToken & File Provider

The token grows three folds (11 fields):
`… : svCount : refsGenSum : runCount` — `COUNT(*)` of `source_versions`,
`COALESCE(SUM(generation),0)` of `refs`, `COUNT(*)` of `provider_runs`. A
ref repoint *must* move the token (it changes the bytes the projection
serves for `sources/by-*` and the `.md` sibling); version appends must move it
(new rows change `sources.jsonl`). Tests hard-coding the 8-field literal
(`LogIndexTests`, `SystemPromptTests`, `SQLiteWikiStoreTests`) update in the
same commit as the fold.

Projection changes (deferred to late phases, per the draft): serve the
*active* content version (ref-resolved) for source nodes; byteless sources
project their active derived alternative; media siblings appear under their
group. The in-app reader is the primary surface first — confirmed.

## 11. Provider protocol (draft Layer 3, unchanged shape)

The `SourceProvider` protocol, `MaterializedSource`, provider list
(local/website/Zotero/git/Tavily/Slack/archive), config-in-JSON +
secrets-in-Keychain, and the two surfaces (UI panel + `wikictl provider`
verbs) carry over from the draft verbatim. Two grounding notes:

- Unifying the four ingest paths is a refactor of *entry points* only — all
  four already funnel through the single `addSource` seam, which becomes
  "create source + run + v1 version + blob" in one transaction.
- **URL provenance starts being recorded** the day the website provider
  lands (`provider_runs.query` = the URL) — today it is lost entirely, which
  is reason enough to sequence providers before "refresh" ships (refresh
  needs to know what to re-fetch).

## 12. Phases

Ordered by dependency; each gate is demoable.

| Phase | Contents | Gate |
|-------|----------|------|
| **0 — Concurrency substrate** *(this branch)* | Method-atomic store, `withTransaction` savepoints, atomic `renameSource`, `WikiReadPool`, off-main search, skill/AGENTS update | Full suite green; concurrent hammer test passes; searches don't touch the main-thread store |
| **1 — Objects & versions** | `blobs`, `source_versions`, `provider_runs` (empty), `refs`, content backfill, ref-resolved reads, byteless support, refresh-append write path | Re-ingesting an identical file adds one version row + zero new blob bytes; rollback = repoint; byteless YouTube source renders via transcript |
| **2 — Extraction alternatives** | technique + source-version columns, CAS extraction content, `source-derived` ref, compare/nominate UI, re-extract path (today none exists) | Two backends' extractions coexist; switch active; revert is a pointer copy |
| **3 — Providers & provenance** | `SourceProvider` protocol, four paths unified, runs recorded (URL provenance!), refresh verb, credentials UX | Drag-drop/URL/Zotero/folder all flow through providers; `wikictl source refresh` appends a version |
| **4 — Media & roles** | `source_links` rebuild (role/pin), `![[…]]` embeds, render-by-content-type, sibling `original_path` resolution, media filtering | Website snapshot renders with inline images; a YouTube embed plays; a json-render spec mounts |
| **5 — Link canonicalization** | Save-time ULID normalization, display-at-render, one-time body migration, `?id=` URL contract, rename = metadata-only | Rename a page with 50 inbound links: zero bodies rewritten, zero ghosts |
| **6 — Pinning** | `@vN` parse/resolve, `pinned_version_id`, quote-against-pinned-version | `[[source:X@v3#"quote"]]` highlights after X is reprocessed |
| **7 — New providers** | git@SHA, Tavily, Slack, archives — each a leaf | Each materializes a frozen, provenance-carrying source |

Phase 5 depends only on 0 (it can move earlier if rename pain dominates);
6 depends on 1+5; everything else is ordered as listed.

## 13. Open questions

1. **Blob GC trigger** — lazy `vacuum-blobs` only, or also opportunistic sweep
   on source delete? (Lazy-only is safe; sweep is an optimization.)
2. **Forward links** — unresolved link targets currently vanish from the
   graph; a `pending_links` table would make "pages wanting a source named X"
   queryable. Deferred; the save-time normalizer makes it easy to add.
3. **Editor ergonomics** for canonical links — pretty-display/edit affordance
   over `[[page:ULID|Title]]` in the raw TextEditor. Deferred until Phase 5
   feedback.
4. **Off-main bulk jobs** — with a method-atomic store the blocking-modal
   upgrade could become a background job with progress; needs a
   model-coordination design (who reloads, when) before any change.
5. **json-render runtime choice** — which renderer/spec dialect the WKWebView
   mounts; the schema is agnostic (it's a mime + a blob).

## 14. Explicitly deferred (unchanged from the draft)

Page versioning and wiki-level snapshots stay out of scope — but note the
model now makes them nearly free when wanted: pages become owners of version
rows with a `page-content` ref kind, and agent-vs-human edit conflicts become
divergent versions instead of clobbers. Vector search remains ancillary
derived data, never versioned. The File Provider projection overhaul remains a
late phase.
