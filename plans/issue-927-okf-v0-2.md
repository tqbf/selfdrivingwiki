# Issue #927 — OKF v0.2 frontmatter in the File Provider projection

## Scope

Bring the projected concept documents up to the OKF v0.2 contract for:

- required `type`
- provenance via `sources`
- trust metadata via `generated`
- bundle-root `okf_version: "0.2"`

Out of scope:

- `verified`
- `status`
- `stale_after`
- attested computation

Those fields remain absent unless the model grows truthful semantics for them.

## Decisions

### 1. Concept types

- Pages emit `type: "Page"`.
- Source markdown siblings emit `type: "Source"`.

These are descriptive, local producer-defined type names, which OKF allows.

### 2. Actor mapping

Existing stored provenance is not migrated. It is mapped at projection time to
the OKF actor convention:

- `user` -> `human:user`
- `chat:<ulid>` -> `process:chat:<ulid>`
- `agent:<kind>` -> `process:agent:<kind>`
- legacy / unknown page authors -> `process:legacy-import` or `process:<raw>`
- source markdown producers with explicit `(agent name, version)` -> `<name>/<version>`
- source markdown rows without explicit producer info fall back to the typed
  `SourceMarkdownOrigin` as `process:<origin>`

This keeps emission truthful without rewriting historical rows.

### 3. Page provenance sources

Page frontmatter `sources` comes from persisted `source_links`, not from
rescanning raw markdown bodies.

- only `role == cite` is emitted
- links are deduplicated by `sourceID`
- ordering is deterministic by `to_source_id`
- resources point to the related source concepts at
  `/sources/by-id/<source-id>.md`

### 4. Source provenance sources

A source markdown sibling represents derived knowledge about the raw source
artifact. Its `sources` list therefore points at the raw projected source file:

- `/sources/by-id/<source-id>.<ext>`

This is always a truthful, followable bundle-relative resource, even when the
original ingest came from a local file, Zotero item, or non-URL external
identity.

### 5. Root index versioning

The persisted root `wiki_index` body is wrapped at projection time with:

```yaml
---
okf_version: "0.2"
---
```

If the stored body already has leading frontmatter, it is stripped before the
OKF wrapper is applied so the root index exposes only the spec-allowed
frontmatter family.

## Constraints and limits

- Trust metadata (`verified`, `status`, `stale_after`) emits when an author has
  recorded it (schema v52, issue #940). A key stays absent while no author has
  recorded a claim.
- Attested computation stays out of scope.

### Source credibility signals (OKF v0.2 §5.1)

The projection emits these signals from facts the store already holds. No
schema change was needed.

- `id` — the `SourceID` raw value. Every entry carries it. It is the stable
  attribution key.
- `last_modified` — the `sources.updated_at` timestamp. Every entry carries it.
- `usage_count` — the number of distinct pages that cite the source through a
  `cite`-role `source_links` row. This is a producer-defined meaning:
  cited-by-N-pages, not reads and not views. A known count of zero is emitted.
- `usage_window` — `{ from: <source.created_at>, to: <latest citing page's
  updated_at> }`. The window is emitted only when `usage_count` is known and
  greater than zero.
- `author` — the producer recorded on the head markdown version, as
  `<name>/<version>` or `process:<name>`. Page `sources` entries point at the
  source concept, so they carry this producer when one is recorded. The
  source-markdown self-reference points at the raw ingested artifact, and the
  store does not know its author, so that entry omits `author`. A derivation
  origin such as `process:extraction` tells how bytes were derived. The
  projection never emits a derivation origin as an author, because that would
  fabricate a claim.

Truthful omission: a key whose value is unknown is absent from the YAML. The
projection never emits a placeholder or a guessed value.

Determinism: every signal value derives from stored rows. No signal reads the
wall clock. Identical database state produces byte-identical projected bytes
across reads and across process launches.

Item-version coordination: page and source-markdown nodes append
`:prov:<digest>` to their content versions on both node paths, leaf and
enumerated. The digest folds every emitted signal, including `last_modified`.
So a citation edit on one page, or a re-ingest of a cited source, advances the
item versions of every co-citing concept. The global change token already
covers the feeding row families through the pages and sources contributors.

## Implementation notes

- Core owns typed OKF value objects and deterministic YAML serialization.
- The File Provider projection owns bundle-relative resource paths, because that
  layout is projection-specific.
- Existing ad hoc page/source frontmatter keys (`date`, `created_by`,
  `last_edited_by`, `origin`, `technique`, `note`) are replaced in projected
  output; they are not retained as transitional duplicates.
