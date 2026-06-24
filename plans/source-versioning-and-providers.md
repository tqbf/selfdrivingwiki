# Source versioning & source providers

**Status:** Design phase — fleshing out before implementation.

## Overview

Three interlocking changes that turn "ingested files" into first-class,
**versioned, provider-backed, rich-media sources**:

1. **Source content versioning** — append-only chains of immutable provider-fetch
   snapshots; refresh appends a version, originals are never deleted; supports
   byteless/external sources.
2. **Source providers** — a unified `SourceProvider` protocol behind which all
   ingest origins live (Zotero, local folder, website/URL, git repo, Tavily
   search, Slack, ZIP/web-archive). Queryable from both the UI and the agent
   (`wikictl`).
3. **Derived/extraction alternatives** — the extracted/derived markdown (and
   transcripts) become a **family of technique-tagged alternatives** that coexist
   side by side, are comparable, and have an explicit active selection.

Plus provenance grouping (a website snapshot yields an HTML source + N image
sources, kept together and rendered inline) and page→source **version pinning**.

## Explicitly out of scope

- **Page versioning** and **whole-wiki snapshots/checkpoints.** The wiki is one
  SQLite file; external backups/copies handle wiki-level rollback. Per the
  operator, source versioning is complex enough on its own; page/wiki versioning
  is deferred indefinitely.
- **Vector search / `page_embeddings`** — ancillary, derivable, not versioned.

## Decisions locked in

| Decision | Choice | Rationale |
|---|---|---|
| Source freshness model | **Frozen materialized snapshot** at fetch time | A source stands alone; provenance is advisory metadata that survives provider deletion |
| Provider relationship | **Fetch-once, frozen** (no live sync) | Re-query with changed upstream content = a new source *version*, not a mutation |
| Refresh semantics | **Appends a new version; originals preserved; always rollback-able** | Append-only, mirrors existing git-lite philosophy |
| Rich media (images/audio/video) | **Distinct sources**, grouped by provenance | Uniform model; media get versioning/provenance/dedup for free |
| ZIP / web-archive as source | **No — they are providers** | Keeps the source unit simple (one primary document); the provider decomposes complex origins |
| Media reference resolution | **Provenance group + original-path resolution at render time** | Mirrors cite-by-quote: nothing stored in the source text; robust to re-snapshot |
| Media visibility in UI | **Grouped/hidden by default**, surfaced inline + under parent | A 30-image snapshot must not clutter the Sources list |
| Derived/extraction model | **Alternatives-family with active selection** (not linear HEAD) | Extraction is unreliable; keep pdf2md vs Claude vs whisper side by side, compare, nominate active |
| Byteless sources | **Yes** — provenance-only for impractical-to-store binaries (giant video); optional thumbnail/proxy that is *not* the source itself | YouTube etc.; the transcript (derived) is the working material |
| Provider scope | **Unify + replace existing ingest paths** (Zotero/folder/URL/drag-drop all become providers) | One origin model; cleaner long-term |
| Provider access | **Both UI and agent** (`wikictl`) | First-class app surface, not agent-only |
| Page→source linking | **Default HEAD; optional exact-version pin** | Reproducibility ("the webpage as I read it"); composes with cite-by-quote |
| Version-pin sigil | **`@`** (e.g. `[[source:Name@v3]]`) | `#` is already the fragment/quote sigil |

## Background — current state

- A source today is **one row** in `sources` with an **immutable `content` BLOB**;
  `version` is only a change counter (no history). `SourceSummary` carries
  filename/ext/mimeType/byteSize/displayName/zotero provenance.
- Derived markdown lives in `source_markdown_versions`: a **linear append-only**
  chain (ULID-sorted; HEAD = `MAX(id)`). Observed `origin` values in code:
  `extraction`, `user`, `revert`, `source` (markdown-native self-seed). Only HEAD
  is projected.
- Extraction is already pluggable: `MarkdownExtractor` protocol +
  `ExtractionBackend` enum + `ExtractionCoordinator`, with backends for local
  pdf2md / Anthropic / Gemini / Docling Serve. Storage is backend-agnostic.
- Four ingest origins exist independently: drag-drop (`addSource`), URL
  (`URLIngestService` + injected `URLResourceFetcher`), Zotero (`ZoteroClient` +
  `ingestFromZotero`), Markdown folder (`MarkdownFolderReader`). Each lands bytes
  through `addSource`.
- Wiki links: `WikiLinkParser` handles `[[source:Name]]`, `[[source:Name#"quote"]]`,
  `[[source:Name|alias]]`; `source_links` table records page→source edges
  (`PRIMARY KEY (from_page_id, to_source_id)`).
- Schema is a stepwise, idempotent `user_version` ladder at **v11**.

## The model

### Layer 1 — Source content versioning (provider-fetch snapshots)

The source's *primary content* becomes a versioned chain, generalizing the
existing `source_markdown_versions` pattern to the verbatim bytes themselves:

- **`sources`** becomes the **logical identity** row: ULID id, `display_name`,
  provenance-group reference, `active_content_version_id` (HEAD), timestamps.
  The verbatim `content` BLOB **moves out** into the new versions table.
- **`source_versions`** (new) — append-only, one row per provider fetch:
  `id` (ULID), `source_id`, `parent_id` (lineage; nil for v1), `content` BLOB
  **nullable**, `mime_type`, `byte_size`, `storage_kind`
  (`'inline'` | `'external'`), `thumbnail` BLOB (nullable), `fetched_at`,
  provenance columns (provider kind/id, external identity). HEAD =
  `active_content_version_id` on `sources` (latest by ULID after a refresh).
- **Refresh appends** a new `source_versions` row and advances
  `active_content_version_id`. Earlier versions are never updated or deleted.
- **Byteless sources:** `storage_kind = 'external'`, `content IS NULL`,
  provenance points at the external object (e.g. YouTube URL + video id); an
  optional `thumbnail` may be stored but is presentation only. The **derived
  content (transcript) is the working material** — readers/projectors fall back
  to the active derived alternative when there are no bytes.

### Layer 2 — Derived/extraction alternatives-family

Generalize `source_markdown_versions` from a linear chain to a **family of
comparable alternatives**:

- Add `extraction_technique` (tag describing what produced it — e.g.
  `pdf2md`, `claude-opus-4-8`, `gemini-3.5-flash`, `whisper-large-v3`,
  `user-edit`) and `source_version_id` (which content snapshot it was derived
  from).
- Multiple alternatives **coexist** per `(source_version, technique)`. The
  `MarkdownExtractor`/`ExtractionBackend` abstraction already produces these;
  each backend run appends an alternative rather than replacing the chain head.
- **Active selection, not "latest = HEAD":** `sources` gains
  `active_markdown_version_id` (nullable → a default pick, e.g. most recent).
  Switching the active extraction does not delete alternatives. User edits can
  branch off a specific extraction (kept via `parent_id` lineage).
- **Compare:** list alternatives side by side in the detail view; nominate active.
- This is what makes "the transcript is bad, replace it; keep the old one to
  compare" first-class — and it is essential for video/audio/image extraction,
  which is explicitly error-prone and iteratable.

### Layer 3 — Source providers (unified ingest)

A single `SourceProvider` protocol absorbs every ingest origin:

```swift
public protocol SourceProvider: Sendable {
    var descriptor: ProviderDescriptor { get }      // id, kind, displayName
    func search(_ query: ProviderQuery) async throws -> [ProviderItem]   // discovery (UI + agent)
    func fetch(_ item: ProviderItem) async throws -> MaterializedSource  // produce frozen snapshot(s)
}
```

- A `MaterializedSource` carries the primary content (bytes **or** byteless with
  provenance + optional thumbnail), mime, `original_path`, plus any **child
  media** (images) that belong to the same provenance group.
- **Fetch is frozen-on-materialize:** the provider produces a self-contained
  snapshot; the wiki stores it. Provenance (provider kind/id + external identity +
  fetched-at) is recorded but **advisory** — deleting the provider never removes
  or orphans stored sources.
- **Implementations** (phased): `LocalProvider` (drag-drop + folder, wraps
  `MarkdownFolderReader`), `WebsiteProvider` (wraps `URLIngestService`; snapshot =
  HTML + images as a group), `ZoteroProvider` (wraps `ZoteroClient`), `GitProvider`
  (file@SHA/tag), `SearchProvider` (Tavily result → source), `SlackProvider`
  (message → source), `ArchiveProvider` (ZIP/web-archive → individual sources).
- **Config + secrets** mirror `ZoteroConfig`/`ExtractionConfig`: JSON for
  non-secret config, Keychain for credentials.
- **Two surfaces:** a UI browse/query panel per provider (Zotero-style), and
  `wikictl` commands the agent uses to query a provider and materialize a source.
- Re-querying the **same external object** with changed content creates a **new
  version** of the same logical source (keyed on provider + external identity),
  not a duplicate — tying providers directly into Layer 1 versioning.

### Provenance grouping + inline media rendering

A single provider fetch may produce several sources (an HTML page + its images):

- A **provenance group** (`provider_runs` table: id, provider kind, query,
  external_ref, timestamps) ties together the sources one fetch produced.
  `sources.group_id` → the run; each source carries `original_path` (its path
  within the origin) and `role` (`'primary'` | `'media'`).
- **Render-time path resolution:** the primary document keeps its original
  relative refs (`<img src="images/foo.png">`); the renderer resolves
  `images/foo.png` to the sibling source in the same group whose `original_path`
  matches. Nothing is stored in the document text — mirroring cite-by-quote.
- **UI:** media sources are hidden from the main Sources list by default
  (`role = 'media'` filtered out), surfacing inline in their parent document and
  under a collapsible "assets" disclosure. Groups are navigable as a unit.
- **Rendering MIMEs:** extend the reader (the WKWebView path already used for
  large sources handles images/audio/video natively) to inline image/audio/video
  sources resolved through the group.

### Page→source version pinning

- Syntax: **`@`** for the version, composing with the existing `#` fragment:
  `[[source:Name@v3]]` (exact version) or `[[source:Name@v3#"quote"]]`.
  Default (no `@`) resolves to the source's active content version (HEAD).
- `WikiLinkParser.splitFragment` already splits on the first `#`; a new
  `splitVersion` splits `@` from the classified *base* (before the fragment), so
  `Name@v3#quote` → name `Name`, version `v3`, fragment `quote`.
- `source_links` gains a nullable `source_version_id` column (NULL → HEAD). A
  pinned link + `#"quote"` resolves the quote against *that* version's content
  (or its active derived alternative).

## Schema / migration (v11 → )

Additive, stepwise, following the existing ladder in `SQLiteWikiStore.bootstrapSchema()`:

1. **`source_versions`** (new) — content-snapshot chain; `content` nullable;
   `storage_kind`; `thumbnail`; provenance columns; `parent_id` lineage.
2. **`provider_runs`** (new) — one row per provider fetch/group.
3. **`sources`** — add `group_id`, `original_path`, `role`,
   `active_content_version_id`, `active_markdown_version_id`; **migrate** the
   existing `content` BLOB + metadata into a v1 `source_versions` row per source
   (backfill, single transaction per source), then drop `content` from `sources`
   (or leave nullable during a deprecation window).
4. **`source_markdown_versions`** — add `extraction_technique` and
   `source_version_id`; existing rows backfill `source_version_id` = the source's
   single (v1) content version.
5. **`source_links`** — add nullable `source_version_id`.

Migration notes / risks:
- The `content`-BLOB move is the riskiest step: backfill into `source_versions`
  before removing the column; keep a nullable `content` during a transition build
  if needed. Each source's single existing snapshot becomes its v1 content
  version (parent_id NULL).
- `changeToken()` must fold `source_versions` row count and the active-version
  pointers so the File Provider projection refreshes on refresh/re-extract.
- Pre-migration read connections must fall back gracefully (existing pattern).

## File Provider projection implications (later phase)

Today the projection serves verbatim bytes + a `.md` sibling (HEAD extraction).
Under the new model it must serve: the **active content version** (or fall back to
the **active derived alternative** for byteless sources), plus media sources
within a group. This is a substantial projection change and is deferred to a late
phase; the in-app reader is the primary surface first.

## Implementation phasing (proposal)

- **Phase 1 — Source content versioning + byteless.** `source_versions` table,
  migrate existing `content` into v1, active-version pointer, store/protocol API,
  byteless (`storage_kind = 'external'`). Gate: refresh appends a version;
  originals intact; byteless source renders via derived content.
- **Phase 2 — Derived alternatives-family.** Generalize `source_markdown_versions`
  with `extraction_technique` + `source_version_id`, active-selection pointer,
  compare UI. Gate: two extractions coexist; switch active; old preserved.
- **Phase 3 — Provider protocol + unify ingest.** `SourceProvider` protocol;
  refactor Zotero/folder/URL/drag-drop into providers; UI + `wikictl` surfaces.
  Gate: drag-drop/URL/Zotero/folder all flow through one provider abstraction.
- **Phase 4 — Provenance grouping + inline media.** `provider_runs`, group/path
  resolution, media-role filtering, inline image/audio/video rendering.
  Gate: website snapshot → HTML + images grouped, images inline.
- **Phase 5 — New providers.** Website snapshot, git@SHA, Tavily search, Slack,
  ZIP/archive. Gate: each provider materializes a frozen source with provenance.
- **Phase 6 — Page→source version pinning.** `@version` syntax, `source_links`
  version column, pinned quote resolution. Gate: `[[source:Name@v3#"quote"]]`
  resolves against the pinned version.

## Open questions / risks

- **`content` BLOB migration** is the highest-risk step (see Schema). Decide:
  drop the column in one migration, or keep a nullable copy during a transition
  build.
- **Active-selection default** when multiple alternatives exist and none chosen
  (most-recent? first?). Needs a concrete rule.
- **Projection scope/sequencing** — the File Provider changes are large; confirm
  the in-app reader is the only required surface for early phases.
- **Provider credential UX** — how provider configs/secrets are surfaced in
  Settings (likely a tab-per-provider or a providers list, mirroring Zotero/
  Extraction).
- **`original_path` collision** within a group (two media with the same path) —
  disambiguation rule needed.
