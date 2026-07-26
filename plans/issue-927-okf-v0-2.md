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

- No `verified` emission: there is no model-level verification history for
  pages or source markdown versions.
- No `status` or `stale_after`: the current page/source model does not encode
  lifecycle state or freshness deadlines.
- No source credibility signals (`author`, `usage_count`, `last_modified`):
  the current store does not carry objective per-source credibility facts in a
  shape that matches the OKF semantics.

## Implementation notes

- Core owns typed OKF value objects and deterministic YAML serialization.
- The File Provider projection owns bundle-relative resource paths, because that
  layout is projection-specific.
- Existing ad hoc page/source frontmatter keys (`date`, `created_by`,
  `last_edited_by`, `origin`, `technique`, `note`) are replaced in projected
  output; they are not retained as transitional duplicates.
