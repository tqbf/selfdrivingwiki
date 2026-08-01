---
timestamp: 2026-08-01T200000Z
title: Issue #219 deletion incoming-links warning
branch: deletion-incoming-links
status: complete
---

# Issue #219 — deleting a resource warns on incoming links

## Progress

Deleting a page or source that other pages link to or bookmarks point at now
opens a confirmation dialog instead of deleting silently. The dialog lists the
incoming links (by page title) and the incoming bookmarks (by folder path), and
offers two destructive choices plus cancel:

- **Unlink and Delete** — rewrites every incoming `[[wiki-link]]` in the linking
  pages to its plain display text (the authored alias, else the target name),
  removes the referencing bookmarks, then deletes the target.
- **Delete** — removes the referencing bookmarks and deletes the target; the
  incoming `[[…]]` syntax stays in place as a ghost link (it renders as a
  missing-link placeholder, consistent with forward links).

Bookmark removal is mandatory in both paths — a bookmark to a missing page or
source is invalid. When a target has no incoming links and no bookmarks, the
delete is immediate (no dialog), preserving the prior friction-free common case.

### Layered implementation

- **`LinkUnlinker`** (`Sources/WikiFSLinks/LinkUnlinker.swift`) — a pure,
  Foundation-only sibling of `WikiLinkRewriter.canonicalize`. It walks `[[…]]`
  spans right-to-left (code-fence-safe via `WikiLinkSpan`), classifies each via
  `WikiLinkParser`, and converts a span to plain text when its target is in the
  deleted-id set. Targets match two ways: a canonical ULID is tested for direct
  membership, and a name is resolved through injected closures then tested.
  Embed prefixes (`![[…]]`) are consumed with the span. Returns `nil` when
  nothing changed so callers skip the re-save. Chat links are never touched.
- **Store reads** — `pageLinkingPages(to:)` (new) and `sourceLinkingPages(to:)`
  (promoted from concrete-only to the `WikiStore` protocol) return the incoming
  page-link / source-link edge sets. Both are single `SELECT DISTINCT` reads.
- **`WikiStoreModel`** — `deletionImpact(forPage:)` /
  `deletionImpact(forSource:)` gather the linking page ids, bookmark folder
  paths, and (for sources) provenance blockers into a `DeletionImpact` snapshot
  for the UI. `delete(_:unlinkIncomingLinks:)` and
  `deleteSource(_:unlinkIncomingLinks:)` perform the confirmed delete: they
  unlink incoming bodies (via `LinkUnlinker` + `PageUpsert.upsert`, which drops
  the now-removed link edge through `replaceLinks`), remove referencing
  bookmarks, then delete the target. A source the agent has used to author
  pages is provenance-restricted (the store throws), so `deleteSource` checks
  the blockers FIRST and bails with a `storeError` before any destructive
  cleanup — citations and bookmarks survive, and the UI offers no delete button.
  This completes the scaffolded `Issue219DeletionAnalysisInput.provenance`
  design (a new public `sourceProvenanceBlockers(sourceID:)` store read backs
  it). `deleteSource` now surfaces store errors via `storeError` (previously
  swallowed) so a restricted source reports why instead of failing silently.
- **UI** — `PagesContainerView` and `SourcesContainerView` aggregate the
  per-selected-id impact, dedupe it, and either delete immediately (no
  references) or present a `.confirmationDialog` carrying the details. A
  provenance-blocked source batch shows a "Can't Delete Source" dialog (OK only)
  naming the pages that cite it as evidence.

The unlink rewrite runs BEFORE the target row is deleted, so name-based links
still resolve to the about-to-be-deleted id. Each rewritten page routes through
the shared `PageUpsert.upsert` seam, so the link graph (`page_links` /
`source_links`) stays consistent with the stored bytes exactly as an in-app or
`wikictl` edit would.

## Verification

- `make build` — full app + File Provider build, signed, green.
- `make test` — 2974 tests pass, including the 14 new `LinkUnlinkerTests`, the
  11 new `DeletionIncomingReferenceTests` (store `pageLinkingPages`, model
  `deletionImpact`, `delete(_:unlinkIncomingLinks:)` for both pages and sources,
  and the provenance-restriction bail-out), and the existing
  `StoreEmissionTests` / `SourceAPISignatureManifestTests` (no new public
  mutator was added to the store; `pageLinkingPages` /
  `sourceProvenanceBlockers` are reads, so neither guard needed updating).
