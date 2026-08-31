---
timestamp: 2026-08-31T010000Z
title: OKF v0.2 source credibility signals in the File Provider projection
branch: feature/okf-source-credibility-signals
status: complete
---

# OKF v0.2 source credibility signals in the File Provider projection

Issue #927 (final piece). References: PR #939 (`7802dd57`), PR #1148
(`5aa4e8d6`, issue #940).

## Progress

Page `.md` frontmatter `sources` entries and the source-markdown
self-reference now carry the OKF v0.2 §5.1 credibility signals. Every entry
carries `id` (the `SourceID` raw value) and `last_modified`
(`sources.updated_at`). Every entry carries `usage_count` when the count is
known, including zero. The count is producer-defined: the number of distinct
pages that cite the source through a `cite`-role `source_links` row, not
reads and not views. An entry carries `usage_window`
(`{ from: <source.created_at>, to: <latest citing page's updated_at> }`)
only when the count is known and greater than zero.

`author` emits the producer recorded on the head markdown version
(`<name>/<version>` or `process:<name>`). Page entries point at the source
concept, so they carry the producer when one is recorded. The
source-markdown self-reference points at the raw ingested artifact. The
store does not know its author, so that entry omits `author`. A new
optional-returning factory, `OKFActor.producerActor(name:version:)`, keeps
the omission truthful. The existing `sourceActor` fallbacks stay in use for
`generated.by` only.

Emission is truthful-omissive: a key whose value is unknown is absent from
the YAML. Exact-string serializer tests freeze the key order
(`id`, `resource`, `title`, `author`, `usage_count`, `last_modified`,
`usage_window`) and the one-line flow-style window.

The store gained two read-only aggregates on `GRDBWikiStore`:
`sourceUsageSignals(sourceIDs:)` (chunked `source_links` → `pages` GROUP BY,
cite role only, distinct citing pages) and
`sourceHeadProducers(sourceIDs:)` (the same head resolution the `.md`
serving path uses, joined through activities to agents). Both are plain
SELECTs that work on read-only connections. No schema change.

Item-version coordination: projected page and source-markdown nodes append
`:prov:<digest>` to their content versions on both node paths, leaf and
enumerated. The digest is SHA-256 over every emitted signal, folded over the
deduped, ordered entry list. It includes `last_modified`, so a same-producer
re-ingest advances versions by construction. A co-citing page edit now
changes both the bytes and the item version of every sibling page that cites
the same source. Enumeration prefetches the signal maps once per read scope
(grow-only, token-invalidated caches on `ReadScope`), so per-page derivation
adds no per-page queries. The global change token already covers the feeding
row families through the existing pages and sources contributors.

`pageNodes` enumeration now derives each page's OKF content for both views,
so enumerated `documentSize` matches the bytes `contents(for:)` serves (the
by-id view previously fell back to a sources-less render). Bookmark page
refs fold the same digest into their change-token version, because their
bytes embed the same signals and a standalone `replaceLinks` can move those
signals without advancing the token.

## Verification

- `make build` passes.
- `make test` passes: 4055 tests in 432 suites.
- `WIKIFS_APP_TESTS=1 swift test --filter ProjectionTreeTests` passes: 50
  tests, including the co-citing and re-ingest staleness regressions on both
  node paths and both aliases.
- `WIKIFS_APP_TESTS=1 swift test --filter WikiFSAppTests.ProjectionTests`
  passes: 17 tests, pinning the `:prov:` content-version formulas and the
  digest sensitivity to every signal family.
- `swift test --filter SourceUsageSignalTests` passes: 6 tests (counts,
  embed exclusion, deletion, empty input, producer nils, read-only
  connection).
- The full `WIKIFS_APP_TESTS=1` run has two known environmental failures:
  `YouTubeEmbedWebViewTests.hostedYouTubeEmbedLoadsUnderRealOriginWithMatchingEmbedURL`
  fails identically on clean `main`, and `xpcRegisterEventSinkRoundTrip`
  passes in isolation (parallel-run flakiness, see #754, #949).
