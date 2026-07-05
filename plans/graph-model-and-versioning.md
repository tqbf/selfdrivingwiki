# Graph model & versioning — objects, refs, and the concurrency substrate

**Status:** design accepted; Phase 0 (concurrency substrate) implemented on branch
`graph-model-and-versioning`. Successor to
`source-versioning-and-providers.md` (draft at `c80e566` on branch
`docs/source-versioning-and-providers` — view with
`git show c80e566:plans/source-versioning-and-providers.md`) — every decision
locked there is preserved unless explicitly amended in §2.

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
| A5 | **PROV-DM provenance vocabulary** — `agents` + `activities` (generalizing `provider_runs`); extraction becomes an Activity | `provider_runs` + string-typed `provider_kind` / `extraction_technique` | First-class Agents (`wasAssociatedWith`/`wasAttributedTo`) and a real extraction Activity (`used`/`wasGeneratedBy`) close the run-level provenance gap; "everything pdf2md produced" becomes a join; see §4.7 |

And one addition the draft explicitly deferred that this design treats as a
**prerequisite**, not a phase: the concurrency substrate (§8), because every
later phase multiplies writers (provider fetches, extraction runs, agent
ingests) and the current store crashes under a second thread.

## 3. Current state (grounded)

What the sweep of the code established, taken against the **pre-Phase-0 tree
(`92124bd`)** — line numbers below refer to that tree. Phase 0 (implemented
with this doc) changed the concurrency facts; those bullets are marked and §8
states the new reality.

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
  `activities` has nothing to backfill from; provenance starts at zero.
- Links are name-canonical in bodies. Page rename rewrites nothing; other
  pages' `[[Old Title]]` go ghost, and on their next save `replaceLinks`
  **silently drops** the row (unresolved targets are omitted, line 1165) — the
  `save()` comment's "self-heal" claim is wrong in the harmful direction.
  Source rename does rewrite bodies (`renameSource`, line 1372) and **was**
  deliberately non-transactional because `updatePage`/`replaceLinks` each owned
  `BEGIN IMMEDIATE` and raw `BEGIN` doesn't nest *(fixed by Phase 0, §8: now
  atomic via savepoint nesting)*.
- Two resolution tiebreaks coexist: pages pick lowest ULID (oldest), sources
  pick `updated_at DESC` (newest). `resolveSourceByName`'s fallback pass is a
  full-table scan run *inside* `replaceLinks`' write transaction.
- Quote fragments (`#"…"`) resolve against the HEAD extraction at scroll time;
  reprocessing a source silently kills existing highlights. `source_links`' PK
  `(from_page_id, to_source_id)` cannot represent a pinned or role-typed edge.
- `changeToken()` is an 8-field fold (`pages` count+sum, `sources` count+sum,
  `system_prompt` version, `log` count, `wiki_index` version,
  `source_markdown_versions` count). Tests hard-code the 8-field literal.
- The store **was** one connection + a prepared-statement cache keyed by SQL
  text, `@unchecked Sendable`, main-thread-only **by convention**; the six
  transaction sites used raw `BEGIN IMMEDIATE` and were not re-entrant
  *(all superseded by Phase 0, §8: method-atomic lock + `withTransaction`)*.
  Still true: `init(databaseURL:)` performs writes at open (migrations, search
  self-heal); only `init(readOnlyURL:)` is side-effect-free.

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

### 4.2 `agents` + `activities` + `source_versions` — the append-only history

```sql
CREATE TABLE agents (
    id           TEXT PRIMARY KEY,        -- ULID
    kind         TEXT NOT NULL,           -- 'software' | 'person' | 'organization'
    name         TEXT NOT NULL,           -- 'pdf2md', 'claude-opus-4-8', 'Apple Podcasts', 'Zotero', 'user'
    version      TEXT,                    -- tool/model version ('0.3.1', model-card id)
    external_ref TEXT                     -- provider identity, model-card URL, …
);

CREATE TABLE activities (
    id           TEXT PRIMARY KEY,        -- ULID
    kind         TEXT NOT NULL,           -- 'fetch' | 'extract' | 'edit' | 'import'
    agent_id     TEXT NOT NULL REFERENCES agents(id),  -- wasAssociatedWith
    plan         TEXT,                    -- the recipe: URL, query, model config, prompt template
    external_ref TEXT,                    -- provider-scoped stable identity of the fetched/used thing
    started_at   REAL NOT NULL,           -- activity startTime
    ended_at     REAL                     -- endTime (nullable; a single-shot fetch may set = started_at)
);

CREATE TABLE source_versions (
    id              TEXT PRIMARY KEY,        -- ULID; chain order = ULID order (existing convention)
    source_id       TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
    parent_id       TEXT,                    -- wasDerivedFrom (lineage; matches smv convention)
    blob_hash       TEXT REFERENCES blobs(hash),   -- NULL = byteless/external
    mime_type       TEXT,
    original_path   TEXT,                    -- path within the fetch (sibling resolution, §7)
    thumbnail_hash  TEXT REFERENCES blobs(hash),    -- presentation only
    activity_id     TEXT REFERENCES activities(id), -- wasGeneratedBy (the fetch activity)
    external_identity TEXT,                  -- e.g. the YouTube video id, the canonical URL
    fetched_at      REAL NOT NULL            -- generation time
);
CREATE INDEX source_versions_source ON source_versions(source_id, id);
```

`activities` **generalizes** the draft's `provider_runs` into the W3C PROV-DM
**Activity** type, and `agents` is the PROV **Agent** type (§4.7 has the full
mapping). This pulls two things out of opaque strings: the draft's
`provider_kind` and `extraction_technique` both become an `agents` row reached
through the activity's `agent_id` (`wasAssociatedWith`), so "everything pdf2md
produced" or "what claude-opus-4-8 extracted" is a join, not a string scan.

- **Refresh appends; nothing updates.** A re-fetch whose bytes are unchanged
  appends a version row pointing at the *same* `blob_hash` — history records
  "checked at T, unchanged" for the cost of a row.
- **Byteless sources** are `blob_hash IS NULL` + provenance
  (`external_identity`, `activity_id`) + optional thumbnail. Their working
  material is the active derived alternative (transcript), exactly per the
  draft — the Apple Podcasts case (§11) is the canonical example.
- `activity_id` lives on the **version** (`wasGeneratedBy` — each fetch is an
  activity), while the source-level `role` (`'primary' | 'media'`, §7 — distinct
  from the *edge* role on `source_links`, §4.4) lives on the **source** — a
  media child is media in every version. Sibling resolution joins versions
  through their shared activity's `plan` / `external_ref`.
- `sources` keeps identity + presentation: `id`, `filename`, `ext`,
  `display_name`, zotero columns (legacy provenance, retained), timestamps,
  `version` counter — and **gains** `role TEXT NOT NULL DEFAULT 'primary'`
  (`'primary' | 'media'`, added in the v20 step, §9). `content`, `byte_size`,
  `mime_type` migrate into v1 version rows (migration in §9).

### 4.3 `refs` — the only mutable pointer state (A2)

```sql
CREATE TABLE refs (
    kind       TEXT NOT NULL,     -- 'source-content' | 'source-derived'
    owner_id   TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
    version_id TEXT NOT NULL,     -- source_versions.id | source_markdown_versions.id
    generation INTEGER NOT NULL DEFAULT 1,   -- bumped on every repoint (changeToken fold)
    updated_at REAL NOT NULL,
    PRIMARY KEY (kind, owner_id)
);
```

Integrity: `owner_id` cascades on source delete via the existing
`foreign_keys=ON` discipline (matching `source_versions` and `source_links`),
so `deleteSource` needs no new code. `version_id` is **polymorphic**
(`source_versions` for `kind='source-content'`, `source_markdown_versions` for
`kind='source-derived'`), so it carries no FK; its consistency with `kind` and
`owner_id` is enforced by the store's single UPSERT write path inside the
repoint transaction — no other code ever writes `refs`.

> **Polymorphism trigger condition (adversarial hardening).** The un-FK'd
> `version_id` is justified *only* by the single-writer invariant. Today two
> kinds exist (`source-content`, `source-derived`); Phase 6 adds `page-content`
> → triply polymorphic. Phase-by-phase the "only one writer" guarantee erodes.
> **Trigger:** when a third ref kind lands, or when any non-repoint path needs
> to write `refs`, evaluate splitting `refs` per-kind into typed tables or
> adding a discriminator + `CHECK`-enforced `(kind, version_id)` consistency
> rule. Do not let the invariant decay silently past three kinds.

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
  (plus a `source_versions` count fold and an `activities` count fold; §10).

### 4.4 Edges — roles and pins (A3)

`page_links` is untouched. `source_links` is rebuilt (v11-style
rename→create→copy→drop) as:

```sql
CREATE TABLE source_links (
    from_page_id      TEXT NOT NULL REFERENCES pages(id),
    to_source_id      TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
    link_text         TEXT NOT NULL,
    role              TEXT NOT NULL DEFAULT 'cite',   -- 'cite' | 'embed' | 'render'
    pinned_version_id TEXT                            -- NULL = follow the active ref
);
CREATE UNIQUE INDEX source_links_edge
    ON source_links(from_page_id, to_source_id, role, COALESCE(pinned_version_id, ''));
```

The **pin is part of edge identity**: `[[source:X@v1|then]]` and
`[[source:X@v3|now]]` on one page are two distinct edges (without this, §5's
pin queries would collapse them and return wrong answers). A rowid table + a
`COALESCE`'d unique index is used instead of a wider PRIMARY KEY because
SQLite treats NULLs as distinct in unique constraints — the `COALESCE` makes
duplicate *unpinned* links to one source still collapse under the existing
`INSERT OR IGNORE` replaceLinks convention, byte-identical to today.

- `cite` — today's `[[source:…]]`: a reference, rendered as a link.
- `embed` — `![[source:…]]` (Obsidian's embed sigil): the renderer inlines the
  content — `<img>` for images, `<video>`/player for media, an iframe/player
  keyed on `external_identity` for byteless YouTube-style sources.
- `render` — an embed whose target's active derived alternative is a
  generative-UI spec (§7); the renderer mounts the interactive artifact.
- Existing rows copy over with `role='cite'`, `pinned_version_id=NULL` —
  byte-identical behavior.

### 4.5 Extraction alternatives (draft Layer 2, + CAS)

`source_markdown_versions` keeps its table name (three renames is enough). It
gains `source_version_id TEXT` (`wasDerivedFrom` — backfilled to the source's
v1 content version) and `activity_id TEXT REFERENCES activities(id)`
(`wasGeneratedBy` — the extraction activity that produced it). The draft's
`extraction_technique` string is **superseded**: the technique is now the
extraction activity's associated **agent** (`activities.agent_id → agents`,
e.g. the `pdf2md` / `claude-opus-4-8` / `whisper-large-v3` / `apple-ttml` /
`user` agent) — see §4.7. PROV gain: an extraction is now a real Activity that
**used** the content version (`source_version_id`) and generated the markdown
version, so "which run extracted this, and when" is recoverable — today it is
lost. Two amendments:

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

### 4.6 Why `pages` and `sources` stay distinct (adversarial review)

A natural challenge to this schema is "pages and sources are both graph nodes
(§5); why not one storage table with a `type` discriminator?" The convergence
the challenge senses is real, but it belongs at the **addressing layer (§6), not
the node-storage layer**. Recorded here so it isn't relitigated without new
facts:

- **Opposite mutability models.** The organizing idea (§intro) is git's storage
  discipline — immutable content-addressed blobs, append-only versions, one
  mutation seam in `refs`. That discipline is for *fetched bytes*. A page is the
  inverse: authored text that changes on every save. Routing page bodies through
  `blobs` would mint a new SHA-256 on every keystroke-save — the *destruction*
  of dedup, not its generalization.
- **Table-per-class is the only honest unification, and it's worse than two
  tables.** A flat `nodes` merge is a mostly-NULL sparse table (pages need
  `slug`/`title`/`body_markdown`; sources need `filename`/`ext`/`mime_type`/
  `byte_size`/`role`/`zotero_*`/`ingested_at`). A subtype split (`nodes` +
  `pages` + `sources`) buys four shared columns (`id`, `created_at`,
  `updated_at`, `version`) at the cost of a JOIN on every read. The dedup isn't
  worth the join.
- **Page versioning is a hook, not a commitment.** §14's "pages become owners of
  version rows with a `page-content` ref kind… nearly free when wanted" means the
  architecture *accommodates* page versioning later — not that it is imminent,
  wanted, or shaped this way. Page history may never ship, or may ship only for
  agent-vs-human conflict (divergent versions), not full provenance. Paying the
  storage-unification tax now for a maybe-future is a bad trade; the
  `refs`/`blobs` design defers it cheaply and additively.

**Where they *do* converge — and already have:** the addressing layer. §6 makes
both `[[page:01H…|Title]]` and `[[source:01J…|Name]]` ULID-canonical. This is the
correct unification point: it is where the two node types are semantically
identical (linkable, addressable targets), and it kills the bug class §3
catalogs (divergent tiebreaks, rename-drops-links, full-table scans in write
transactions) — bugs that existed because display names were identity, *not*
because storage was split. A reviewer reaching for storage unification is
correctly sensing convergence but mislocating it; it is captured at the link
layer.

**Edge tables stay separate too** (`page_links` vs `source_links`): merging into
one `edges(from_node, to_node)` table would lose the FK to the parent table. The
plan accepts exactly one polymorphic column (`refs.version_id`, §4.3) because it
has a single write path; edge rows are written from body-parsing at many call
sites, where the single-writer justification is weaker. FK integrity wins over
DRY here.

### 4.7 PROV-DM alignment (A5)

The provenance tables adopt the W3C PROV-DM core vocabulary
([prov-dm](https://www.w3.org/TR/prov-dm/)) — types and relations as schema,
without the qualified/n-ary machinery (overkill for a wiki). This makes
agent-responsibility first-class and closes the single biggest provenance gap
today: an extraction's *run* is recoverable, not just implied.

**Type mapping:**

| PROV type | Table / column | Notes |
|---|---|---|
| **Entity** | `source_versions`, `source_markdown_versions` | versioned artifacts with fixed aspects |
| **Activity** | `activities` | `kind ∈ {fetch, extract, edit, import}` |
| **Agent** | `agents` | `kind ∈ {software, person, organization}` |
| **Plan** | `activities.plan` | the recipe (URL, query, model config, prompt) |

**Relation mapping** (denormalized into columns — one write path per relation,
the same discipline as `refs`):

| PROV relation | Column | Where |
|---|---|---|
| **wasGeneratedBy** | `source_versions.activity_id`, `source_markdown_versions.activity_id` | entity → the activity that created it |
| **used** | *derivable* (see below) | activity ↔ the input entity it consumed |
| **wasDerivedFrom** | `source_versions.parent_id`, `source_markdown_versions.source_version_id` | entity → entity lineage |
| **wasAssociatedWith** | `activities.agent_id` | activity → responsible agent |
| **wasAttributedTo** | derivable (generation + association); optional explicit `source_versions.attributed_to_agent_id` for content *origin* (author/publisher), distinct from the fetcher | entity → agent responsible for the content |
| **actedOnBehalfOf** | deferred | provider-on-behalf-of-user; expressible later if needed |

**Why `used` is derivable, not stored.** PROV's
`wasDerivedFrom(e2, e1, a, …)` already names the activity `a`, the input `e1`,
and the output `e2`. For an extraction, `e2` = the smv (`activity_id` → `a`),
`e1` = `source_version_id`. So `used(a, e1)` is the join `smv.activity_id` ∩
`smv.source_version_id` — no redundant column. (A future activity that consumes
*multiple* inputs would need an explicit `used` relation table; none exists
today.)

**What PROV needs that is NOT yet captured** (metadata gaps, by phase):

- **URL/source provenance** — lost entirely today (§3); starts when the website
  provider lands (`activities.plan` = the URL). Phase 3.
- **Content attribution** (`wasAttributedTo` to author/publisher) — not captured;
  the publisher/author of a fetched source is metadata a provider must extract,
  distinct from the software that fetched it. Phase 3+.
- **Activity duration** — `ended_at` is nullable; a fast fetch sets it =
  `started_at`. A long extraction that should record its runtime writes both.
  Phase 2.

**Backfill:** the migration (§9) seeds one `agents` row per distinct legacy
`extraction_technique` / `provider_kind` string and one `activities` row
(`kind='fetch'`) per existing `provider_run`, then repoints `source_versions`
and `source_markdown_versions` at them. No provenance is lost in the move.

### 4.8 Descriptive metadata & the PROV–Dublin Core boundary (context, not schema)

[PROV-DC](https://www.w3.org/TR/prov-dc/) is the W3C mapping between Dublin Core
and PROV. It clarifies exactly where the provenance substrate (§4.7) stops and
where descriptive metadata — the "what is this thing" a provider must capture —
begins. This orients source-provider design (Phase 3); **nothing here is a
schema commitment**, only context for `SourceProvider.materialize`'s return
shape and the fields a provider should extract.

**Already covered by the PROV substrate — no new modeling needed:**
- *Responsibility terms* — `dc:creator`, `dc:contributor`, `dc:publisher`,
  `dc:rightsHolder` — all map to **`wasAttributedTo`**, distinguished only by
  agent *role*. The §4.7 `agents` table + attribution is the home for all four;
  providers populate agents with roles, not new relation tables.
- *Derivation terms* — `dc:source`, `dc:references`, `dc:isFormatOf`,
  `dc:isVersionOf` — map to **`wasDerivedFrom`** / `alternateOf`, which
  `parent_id` and `source_version_id` already express. Notably `dc:isFormatOf` →
  `alternateOf` is the "same resource, another format" relation — precisely a
  PDF ↔ its extracted markdown, or a video ↔ its transcript (validating the
  derived-alternative model).
- *Date terms* — `dc:created`, `dc:issued`, `dc:modified` — map to
  **`generatedAtTime`**, each implying a *distinct* activity (Create / Publish /
  Modify). Lesson for providers: "date published" is not one timestamp; creation
  and publication are separate activities, recorded as such.

**The descriptive residue PROV does not cover** (PROV-DC lists these as "not
mapped" — they answer *what*, not *how*): `title`, `description`, `subject`,
`type`, `format`, `identifier`, `language`, `coverage`, `extent`,
`isPartOf`/`hasPart`, `bibliographicCitation`. These are plain attributes a
provider extracts and attaches to the entity. The high-value ones for
*determining* sources (identity, dedup, grouping, citation): canonical
**identifier(s)** (DOI/ISBN/URL/arXiv/episode-id — a source can have several),
**type/subtype** (Article, VideoObject, Thesis… — drives §7 rendering and
citation formatting), **isPartOf** (chapter-in-book, episode-in-show — feeds §7
provenance grouping), **title**, and **language**.

**Pragmatic lesson from PROV-DC's complex-mapping caveat:** mechanically
expanding a DC record into full PROV n-ary form is lossy and mints blank nodes
for every resource state. The takeaway: keep descriptive metadata as
*attributes*; model only the provenance relations (attribution, derivation,
generation) as first-class — exactly the split §4.7 already makes. When Phase 3
designs `SourceProvider.materialize`, its returned `MaterializedSource` should
carry the descriptive fields above as plain properties, and the store maps the
responsibility / derivation / date fields onto the existing `agents` /
`activities`.

## 5. The graph, named

With the tables above, the wiki *is* this typed property graph — queryable
with plain SQL and recursive CTEs, no engine required:

```
nodes:  page · source · source_version · smv (derived alternative) · activity · agent · blob
edges:  page        —links(link_text)→                    page          (page_links)
        page        —refers(role, pin)→                   source        (source_links)
        source      —has-version→                          source_version (FK)
        source_ver  —wasDerivedFrom(lineage)→             source_version (parent_id)
        smv         —wasDerivedFrom→                      source_version (source_version_id)
        activity    —used→                                source_version (the extraction input; derivable, §4.7)
        source_ver  —wasGeneratedBy→                      activity      (FK)
        smv         —wasGeneratedBy→                      activity      (FK)
        activity    —wasAssociatedWith→                   agent         (FK)
        refs        —active→                               version rows   (the only mutable edges)
        version/smv —content→                              blob          (hash)
```

Example queries this unlocks (candidates for a `wikictl graph` verb, later):
"pages citing any version derived from this activity" (join through
`activity_id`), "everything the pdf2md agent produced" (`wasAssociatedWith` +
`wasGeneratedBy`), "orphan sources" (anti-join on `source_links`), "what did
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
lands in `source_links.pinned_version_id` (pin-distinct edges, §4.4). No `@` =
follow the ref. Render-time pin/quote resolution uses each occurrence's own
`@vN` **as stored in the canonical body** — the body is the per-occurrence
source of truth; `source_links` is the graph *index*, never the resolver
input. Quote fragments resolve against the *pinned* version's content —
fixing today's silent highlight loss on reprocess for pinned links, and
giving "the webpage as I read it" reproducibility.

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
block extends in parity, enforced by the existing test.

> **Numbering reconciliation (Phase 1 implemented).** §9 originally numbered
> the objects step "v18"; v18/v19 are taken (v18 = name sanitization, v19 =
> `content_hash`). The objects & versioning step shipped as **v20**. The later
> phases renumber accordingly: extraction columns **v21**, `source_links`
> rebuild + `sources.role` **v22**. The step descriptions below are updated to
> the shipped/renumbered sequence.

1. **Phase 0 — no schema step.** (Concurrency is code-only; `user_version`
   stays at the ladder head.)
2. **v18: name sanitization** (data-only sweep), **v19: `content_hash`** — both
   shipped before Phase 1.
3. **v20: `blobs`, `agents`, `activities`, `source_versions`, `refs`** (Phase 1,
   implemented) — create the tables, then a **one-shot migration**: for each
   source, **reuse the existing v19 `content_hash`** as the blob hash (same
   SHA-256 — no re-hash) → `INSERT OR IGNORE` blob → seed one legacy `agents`
   row (`'software'`/`'legacy-import'`) → per-source import `activities` row →
   insert a v1 version row (`parent_id NULL`, `fetched_at = created_at`) → write
   the `source-content` ref (generation 1) → **drop the `sources.content`
   column** in the same transaction (`ALTER TABLE … DROP COLUMN`; macOS 15 ships
   SQLite ≥ 3.43). All inside one `withTransaction`; a pre-migration assertion
   guarantees no source lacks a `content_hash` (silent-data-loss guard).

   **No soak, no dual-write, no read-fallback.** The defensive soak machinery
   this plan once carried existed for *binary skew across live users* — three
   separately-compiled processes (app, `wikictl`, FP extension) plus stale
   binaries sharing one file at different schema versions. The app is
   **pre-launch**: there are no users with stale binaries, and "skew" during
   development means "rebuild all three," the normal dev loop, not something to
   design migrations around. So `sources.content` is dropped outright in v20, not
   kept nullable through a transition release. The developer's own existing DB
   (real data) migrates once, in place, via this step; it is restorable from
   VCS if the one-shot ever misbehaves during development. Byteless sources
   (`blob_hash IS NULL`) are legal from v20 onward — no gating.

   Reads go through `sourceContent(id:)` which resolves ref → version → blob, so
   the call-site surface (wikictl `cat`/`export`, FP projection, agent staging)
   doesn't change signatures.

   > **Deviation from §4.2 (decided, flagged).** §4.2 migrates `byte_size` and
   > `mime_type` onto the version rows. Phase 1 **keeps them as denormalized
   > columns on `sources`** mirroring the active version's blob, dropping only
   > `content`. In Phase 1 every source has exactly one version, so the mirror
   > is trivially correct and never drifts; it avoids reworking `SourceSummary`,
   > `getSource`/`listSources`, the FP `node(for:)` size, and
   > `indexes/sources.jsonl` in this foundational migration. Phase 3's repoint
   > path reconciles the mirror; a later phase may collapse the denorm columns
   > onto the version.

4. **v21: extraction columns** (`activity_id REFERENCES activities(id)`,
   `source_version_id`, `blob_hash`, `mime_type`) + backfills (one
   `kind='extract'` activity per legacy row, associated with the matching agent;
   v1 version id).
   > **Phase 2 implemented (v21).** CAS-moves each legacy row's inline `content`
   > into a blob (reusing the SHA-256 as `blob_hash`), seeds one
   > `legacy-extraction` agent + a per-row `extract` activity, backfills
   > `source_version_id` to the source's active content version, and clears the
   > inline column to `''`. New extractions go through `recordMarkdownExtraction`
   > (provenance-carrying, CAS'd); the `source-derived` ref makes "switch active
   > extraction" a one-row repoint; `revert` is a pointer copy. Default-active
   > rule keeps HEAD = MAX(id) byte-identical until a ref is written. Tracks A+B
   > shipped; track C (compare/nominate UI) deferred to a follow-on plan.
5. **v22: `source_links` rebuild** as the rowid table + `COALESCE`'d unique
   index of §4.4 (copy-over `role='cite'`, `pinned_version_id=NULL` — still
   unique, byte-identical behavior), **plus**
   `ALTER TABLE sources ADD COLUMN role TEXT NOT NULL DEFAULT 'primary'`
   (`'primary' | 'media'`, per the draft's provenance grouping) — the default
   is the backfill; only new provider fetches ever write `'media'`.
6. **Link canonicalization** (Phase D) is a *data* migration, not schema: a
   guarded one-time body rewrite (dry-runnable via lint), then the save-path
   normalizer keeps it invariant.

**File Provider projection.** The projection's size==content invariant holds
trivially: with `sources.content` gone, `documentSize` and `contents(for:)` both
derive from the active version's blob (`blobs.byte_size` joined through the ref).
**Byteless sources** (active version `blob_hash IS NULL`) project as a
**zero-byte verbatim node** — `sourceContent(id:)` returns empty `Data` (never
throws), the enumerator reports size 0 — and the `.md` transcript sibling is the
useful surface. The late-phase projection overhaul later replaces this with
projecting the active derived alternative.

## 10. changeToken & File Provider

The token grows three folds (11 fields):
`… : svCount : refsGenSum : actCount` — `COUNT(*)` of `source_versions`,
`COALESCE(SUM(generation),0)` of `refs`, `COUNT(*)` of `activities`. (`agents`
are slowly-changing reference data and need no fold.) A
ref repoint *must* move the token (it changes the bytes the projection
serves for `sources/by-*` and the `.md` sibling); version appends must move it
(new rows change `sources.jsonl`). Tests hard-coding the 8-field literal
(`LogIndexTests`, `SystemPromptTests`, `SQLiteWikiStoreTests`) update in the
same commit as the fold.

> **Token is monotone non-decreasing *except for deletes* (adversarial hardening,
> reconciled in Phase 1).** `source_versions` and `activities` are append-only
> *counts*, and `refs.generation` only increments — so a *rollback* (a repoint)
> moves the token *forward* (generation+1), never back. **But** `deleteSource`
> cascades `source_versions` and `refs` rows, which legitimately *lowers*
> `svCount` and `refsGenSum` (and `activities` rows persist — no cascade from
> sources). The token only needs to *change* on any mutation, which it does; the
> strict "never decreases" framing holds for appends/repoints but NOT deletes.
> This is intentional: rollback changes the bytes the projection serves, so
> consumers must refresh. Consequence: the token can never express "the wiki
> returned to a previous state" via a rollback (a decrease); a delete does lower
> it, but that still forces a refresh. Any future feature wanting "changed since
> snapshot X" semantics where rollback-to-prior should *decrease* the token is
> foreclosed by this design and would need a different change-detection
> mechanism. Recorded so the constraint is stated correctly.

Projection changes (deferred to late phases, per the draft): serve the
*active* content version (ref-resolved) for source nodes; byteless sources
project their active derived alternative; media siblings appear under their
group. The in-app reader is the primary surface first — confirmed.

## 11. Provider protocol (draft Layer 3, unchanged shape)

The `SourceProvider` protocol, `MaterializedSource`, provider list
(local/website/Zotero/git/Tavily/Slack/archive/Apple Podcasts), config-in-JSON +
secrets-in-Keychain, and the two surfaces (UI panel + `wikictl provider`
verbs) carry over from the draft verbatim. Two grounding notes:

- Unifying the four ingest paths is a refactor of *entry points* only — all
  four already funnel through the single `addSource` seam, which becomes
  "create source + run + v1 version + blob" in one transaction.
- **URL provenance starts being recorded** the day the website provider
  lands (`activities.plan` = the URL) — today it is lost entirely, which
  is reason enough to sequence providers before "refresh" ships (refresh
  needs to know what to re-fetch).

> **Apple Podcasts provider (PR #106).** Podcast transcript ingest already
> exists as a special case on the URL path (`PodcastEpisodeURL.parse` →
> `ApplePodcastTranscriptService`), built against today's flat source model: it
> stores the transcript `.md` as source `content` and bakes the episode ID into
> the filename. When Phase 1–3 land it re-models cleanly — a **byteless source**
> (`external_identity` = episode ID, `activities.plan` = the URL) whose
> **derived alternative** is the TTML→markdown transcript (an extract activity
> associated with the `apple-ttml` agent, §4.7); the recognizer + service
> become a `SourceProvider` (the `apple-podcast` agent), and refresh appends a
> version instead of overwriting. The risky private-API bits (`PodcastsFoundation`
> dlopen, forked helper, signed requests) are compiled out for App Store builds
> (`#if PODCAST_TRANSCRIPTS`) and stay on the user-initiated UI path — they do
> not move into the agent surface. Ships independently of this plan; tracked
> here so it is unified when providers land.

## 12. Phases

Ordered by dependency; each gate is demoable.

| Phase | Contents | Gate |
|-------|----------|------|
| **0 — Concurrency substrate** *(this branch)* | Method-atomic store, `withTransaction` savepoints, atomic `renameSource`, `WikiReadPool`, off-main search, skill/AGENTS update | Full suite green; concurrent hammer test passes; searches don't touch the main-thread store |
| **1 — Objects & versions** | `blobs`, `agents`, `activities`, `source_versions`, `refs`, one-shot content migration (drop `sources.content`), ref-resolved reads, byteless support, refresh-append write path | Re-ingesting an identical file adds one version row + zero new blob bytes; rollback = repoint; byteless YouTube source renders via transcript |
| **2 — Extraction alternatives** | extraction-as-Activity (`activity_id` on smv + `used` the content version, §4.7), CAS extraction content, `source-derived` ref, compare/nominate UI, re-extract path (today none exists) | Two backends' extractions coexist; switch active; revert is a pointer copy |
| ↳ *Phase 2 tracks A+B implemented (v21).* CAS'd/provenance-carrying extractions via `recordMarkdownExtraction`, `source-derived` ref + `setActiveMarkdown`, `revert` pointer copy, re-extract path, `wikictl source set-active`, minimal alternatives Menu. Gate met (AC.1–AC.9, 1488 tests green). *Track C (full compare/nominate UI) deferred to a follow-on plan.* | | |
| **3 — Providers & provenance** | `SourceProvider` protocol, four paths unified, runs recorded (URL provenance!), refresh verb, credentials UX, **website provider writes disambiguated `original_path` per sibling rule (§7)** | Drag-drop/URL/Zotero/folder all flow through providers; `wikictl source refresh` appends a version |
| **4 — Media & roles** | `source_links` rebuild (role/pin), `![[…]]` embeds, render-by-content-type, sibling `original_path` resolution, media filtering | Website snapshot renders with inline images; a YouTube embed plays; a json-render spec mounts |
| **5 — Link canonicalization** | Save-time ULID normalization, display-at-render, one-time body migration, `?id=` URL contract, rename = metadata-only | Rename a page with 50 inbound links: zero bodies rewritten, zero ghosts |
| **6 — Pinning** | `@vN` parse/resolve, `pinned_version_id`, quote-against-pinned-version | `[[source:X@v3#"quote"]]` highlights after X is reprocessed |
| **7 — New providers** | git@SHA, Tavily, Slack, archives, Apple Podcasts — each a leaf | Each materializes a frozen, provenance-carrying source |

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
6. **Activity lifecycle on source delete (revisit at Phase 2/3).** `activities`
   has no FK to `sources` (it references `agents`), so `deleteSource` cascades
   `source_versions` + `refs` but **leaves activities orphaned** — they persist
   as durable PROV-DM history (Model A, §4.7). Consequence: `activities` grows
   unbounded on source deletes, and the `actCount` changeToken fold is monotone
   (only `svCount`/`refsGenSum` drop on delete — see the §10 caveat). In Phase 1
   this is harmless: every activity is a synthetic `'legacy-import'`/`'import'`/
   `'fetch'` stub carrying no real provenance (§3), so the orphans are pure dead
   weight. **Revisit when real provenance lands (Phase 2 extraction activities,
   Phase 3 provider fetches):** if provenance turns out worth keeping, keep Model
   A and add an activity-GC pass that sweeps only synthetic legacy activities; if
   not, add an explicit cascade in `deleteSource` (delete activities referenced
   solely by the source's versions — a 5–10 line explicit delete, *not* a FK
   change, since the FK runs `source_versions → activities` child→parent and
   SQLite cannot auto-cascade it; a future multi-input extraction activity also
   makes a single `activities.source_id` FK wrong).

## 14. Explicitly deferred (unchanged from the draft)

Page versioning and wiki-level snapshots stay out of scope — but note the
model now makes them nearly free when wanted: pages become owners of version
rows with a `page-content` ref kind, and agent-vs-human edit conflicts become
divergent versions instead of clobbers. Vector search remains ancillary
derived data, never versioned. The File Provider projection overhaul remains a
late phase.
