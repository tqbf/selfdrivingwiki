# Phase 3a — Provider protocol & real source provenance

**Status:** shipped (2026-07-05). Design authority: `plans/graph-model-and-versioning.md`
§4.7 (PROV-DM), §4.8 (PROV-DC boundary), §11 (provider protocol), §3 (the gap:
URL-ingested sources did not persist their origin URL).

## Goal

Introduce a `SourceProvider` protocol that owns *materialization* (bytes +
filename + mime + PROV provenance), unify the four ingest entry points
(drag-drop, URL, Zotero, Markdown-folder) behind it, and record **real
provider/URL provenance** in the existing Phase-1 PROV substrate — so the origin
of every fetched source is recoverable instead of lost. **No schema migration.**

## What changed

### New file: `Sources/WikiFSCore/SourceProvider.swift`

- **`SourceProvenance`** (Sendable, Equatable) — the PROV descriptor threaded
  into the store: `agentName`, `agentKind` (default `"software"`),
  `agentVersion?`, `activityKind` (`"fetch"` / `"import"`), `plan?`
  (`activities.plan`, the request URL for website), `externalRef?`
  (`activities.external_ref`, per-ingest identity), `externalIdentity?`
  (`source_versions.external_identity`, the canonical external id).
- **`MaterializedSource`** (Sendable) — the provider's output: `filename`,
  `data`, `mimeType?`, retained Zotero legacy columns, and `provenance?`.
  Carries no store handle (single-writer discipline).
- **`protocol SourceProvider: Sendable`** — `var agentName`, `func materialize()
  async throws -> MaterializedSource`. Providers never write the store.
- **`SourceOrigin`** (Sendable, Equatable) — the read-side projection:
  `agentName`, `activityKind`, `plan?`, `externalRef?`, `externalIdentity?`,
  `fetchedAt`.
- **Four providers:**
  - `LocalFileProvider(fileURL:)` — reads off-main, dispatches via
    `URLFetchService.plan(for:)` (preserving the pre-Phase-3 behavior), agent
    `"local-file"`, activity `"import"`.
  - `WebsiteProvider(rawInput:fetcher:)` — normalize→fetch→dispatch, agent
    `"website"`, activity `"fetch"`, `plan` = request URL, `externalRef`/
    `externalIdentity` = resolved final URL. `materializeWithPlan()` returns the
    dispatch `StorePlan` alongside so `addURL` can build its `FetchOutcome`.
  - `ZoteroProvider(attachment:parentItem:zoteroDir:)` — `ZoteroLocalStorage.
    resolve` + off-main read, agent `"zotero"`, activity `"import"`,
    `externalIdentity` = parent item key, also populates the retained legacy
    `zoteroItemKey`/`zoteroItemTitle` columns.
  - `MarkdownFolderProvider(filename:data:mimeType:)` — adapts each walked file
    from `MarkdownFolderReader.walk` (which does the batch off-main read), agent
    `"markdown-folder"`, activity `"import"`.

### `SQLiteWikiStore.swift`

- `addSource` gains `provenance: SourceProvenance? = nil`. When present, it seeds
  a real provider agent (`ensureAgent`, deduped on `(name, kind)`) + an activity
  carrying `plan`/`external_ref`, and binds `external_identity` on the v1
  version. When nil, the legacy-import agent + bare `import` activity path is
  byte-identical to pre-Phase-3.
- `appendContentVersion` gains `provenance: SourceProvenance? = nil`
  (forward-compat substrate — refresh UI/verb stays unwired; the nil path stays
  byte-identical).
- New `sourceOrigin(sourceID:) throws -> SourceOrigin?` — joins active content
  version (ref → else `MAX(id)`) → its `activities` row → the joined `agents`
  row. `plan`/`external_ref` read from the **activity** (per-ingest), `agentName`
  from the **agent**.

### `WikiStore.swift` (protocol)

- `addSource` signature extended with `provenance: SourceProvenance?` (no
  default — protocol requirements can't carry defaults; the concrete impl has
  the default so existing 2-arg callers compile).
- New `sourceOrigin(sourceID:)` requirement.

### `WikiStoreModel.swift`

- New `storeMaterialized(_:)` seam — the single store-write call every
  provider-backed ingest flows through.
- `addFiles` / `addURL` / `ingestFromZotero` / `importFromMarkdownFolder` all
  rebuilt on their provider + `storeMaterialized`. Behavior (directory-skip,
  batch duplicate reporting, `FetchOutcome` return, off-actor fetch) preserved.
- New `sourceOrigin(for:)` accessor for the UI.

### `SourceDetailView.swift`

- An "Origin" row: website → "Website" label + "Open original" clickable link;
  markdown-folder → "From Markdown folder"; local → "Added from file". Zotero
  sources keep their existing dedicated `zoteroOriginRow`.

### `wikictl`

- New `source info (--id | --name)` subcommand: prints identity (id, filename,
  display name, mime, size) + origin (provider, activity, plan/URL, external
  identity, external_ref, fetched-at).

## What did NOT change

- **No schema migration** — every populated PROV column (`activities.plan`/
  `external_ref`, `agents.version`/`external_ref`, `source_versions.
  external_identity`) already existed and was stubbed NULL. No `user_version` bump.
- **`changeToken`** — unchanged (no new fold; agents are slow-changing reference
  data, `actCount`/`refsGenSum` already exist).
- **Refresh / credentials UX** — deferred to Phase 3b.
- **New providers** (git/Tavily/Slack/Apple Podcasts) — Phase 7 leaves; PR #106
  (Apple Podcasts) re-models as `ApplePodcastProvider`, the first consumer of
  this protocol, after Phase 3a lands.

## Sequencing note (PR #106)

PR #106 (Apple Podcasts transcripts) is `mergeable: CONFLICTING`, built against
the dead flat model. It re-models as the **`ApplePodcastProvider`** — the natural
first consumer of this plan's `SourceProvider` protocol: a byteless source
(`external_identity` = episode ID, `activities.plan` = URL) whose derived
alternative is the TTML→markdown transcript. **Do not merge/rebase #106 before
this plan lands** — it needs the protocol + byteless-source + PROV plumbing.

## Test coverage

`Tests/WikiFSTests/SourceProviderTests.swift` (13 tests): provider unit tests
(fake fetcher / temp files), store integration (website/Zotero/local/folder
provenance via `sourceOrigin`), agent idempotency (two website ingests → one
agent, two activities), two-distinct-URLs, legacy nil-provenance fallback
regression, `appendContentVersion` nil + provenance paths, unknown-id nil.
`Tests/WikiFSTests/WikiCtlCommandTests.swift`: `source info` website + legacy.
Existing `appendContentVersionDedupsBlob` + `freshFastPathMatchesStepwiseLadder`
+ changeToken tests pass unmodified (regression). Full suite: 1503 tests green.
