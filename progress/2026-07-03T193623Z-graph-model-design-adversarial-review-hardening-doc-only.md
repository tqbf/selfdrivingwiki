---
timestamp: 2026-07-03T193623Z
title: "2026-07-03 — Graph-model design: adversarial review hardening (doc-only)"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-07-03 — Graph-model design: adversarial review hardening (doc-only)

## Progress


Second-pass adversarial review of [`plans/graph-model-and-versioning.md`](plans/graph-model-and-versioning.md),
prompted by the "should sources and pages be one data model?" question. No code
or schema change — five amendments hardening the design of record:

- **New §4.6 — why `pages` and `sources` stay distinct.** Records the verdict
  that the convergence the unification challenge senses is real but belongs at
  the addressing/link layer (§6, already done via ULID-canonical links), *not*
  the node-storage layer. The three rebuttals: opposite mutability models
  (page bodies through `blobs` would destroy dedup), table-per-class
  unification is worse than two tables (a JOIN on every read for four shared
  columns), and page versioning is a forward-compatibility hook (§14) not a
  commitment. Edge tables stay separate too — FK integrity beats DRY.
- **§4.3 — `refs.version_id` polymorphism trigger condition.** The un-FK'd
  polymorphic column is justified only by the single-writer invariant; Phase 6's
  `page-content` ref makes it triply polymorphic. Added an explicit trigger:
  re-evaluate (split per-kind, or add a discriminator + CHECK) when a third kind
  lands or any non-repoint path writes `refs`. Don't let it decay silently.
- **§9 — migration simplified for pre-launch.** The app has no live users, so
  the soak/dual-write/read-fallback machinery that existed for binary skew
  across stale binaries is unnecessary. v18 is now a clean one-shot migration:
  create tables → hash `content` into blobs + v1 versions + refs → **drop
  `sources.content` in the same step**. Byteless sources are legal from v18 with
  no gating (the byteless sequencing caveat added earlier is superseded). The
  developer's own DB migrates once in place; restorable from VCS.
- **§10 — changeToken is monotone non-decreasing by design.** All three new
  folds grow monotonically (`generation` only increments), so a rollback moves
  the token *forward*, never back. Recorded as an explicit constraint: any
  future "changed since snapshot X" feature that needs rollback-to-prior to
  *decrease* the token is foreclosed and would need a different mechanism.
- **§12 Phase 3 — `original_path` disambiguation is a Phase-3 deliverable.**
  §7's sibling-resolution collision rule (suffixing on `original_path`) was
  forward-referencing the unimplemented website provider. Added it to Phase 3's
  contents (the website provider writes disambiguated `original_path`); Phase 4's
  rendering consumes it.
- **§11/§12 — Apple Podcasts added as a tracked provider (PR #106).** Podcast
  transcript ingest already exists as a URL-path special case (`PodcastEpisodeURL`
  → `ApplePodcastTranscriptService`) against the flat source model. Added to the
  provider list (§11) with a note on how it re-models when Phase 1–3 land
  (byteless source, transcript as derived alternative, recognizer+service become
  a `SourceProvider`), and to Phase 7's leaf providers. Ships independently.
- **§4.7 + A5 — W3C PROV-DM provenance vocabulary (Full alignment).** Adopted
  the PROV-DM core types/relations as schema: new **`agents`** table (PROV
  Agent; normalizes the `provider_kind`/`extraction_technique` strings into
  first-class agents) and **`activities`** table (PROV Activity; generalizes
  `provider_runs`, broadens `kind` to `fetch|extract|edit|import` so extraction
  becomes a real Activity). Relations mapped: `wasGeneratedBy`
  (`activity_id` on both version tables), `wasDerivedFrom` (`parent_id` /
  `source_version_id`), `wasAssociatedWith` (`activities.agent_id`), `used`
  (derivable from derivation+generation, §4.7). Closes the run-level provenance
  gap (an extraction's run is now recoverable, not just implied). Token fold
  renamed `runCount`→`actCount`; §5 graph, §9 migration, §11/§12 phases, and
  all `provider_run`/`extraction_technique` references updated to match.
- **§4.8 — PROV–Dublin Core boundary (context note, no schema).** Recorded the
  [PROV-DC](https://www.w3.org/TR/prov-dc/) mapping as orientation for Phase 3
  provider design: DC responsibility terms (creator/publisher/contributor/
  rightsHolder) → `wasAttributedTo` (already the `agents` table); derivation
  terms → `wasDerivedFrom` (already `parent_id`/`source_version_id`); date terms
  → distinct Create/Publish activities. The "not mapped" descriptive residue
  (title/type/identifier/isPartOf/language/…) is what a provider must capture as
  plain attributes — the high-value ones for determining sources are canonical
  identifiers, type/subtype, isPartOf, title, language. Non-normative context
  for `SourceProvider.materialize`'s return shape.

## Verification

Historical verification remains in the progress record above.
