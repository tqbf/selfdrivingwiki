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

## Hardening follow-up (shared protected deletion contract)

The first implementation assembled the cleanup from separate store calls: the
model unlinked bodies with `PageUpsert`, removed bookmarks one by one, and then
called `deletePage` / `deleteSource`. That left bypasses, race windows, and
partial-write risks. A store-level contract now closes them.

### The contract

- **`ResourceDeletionRequest` / `ResourceDeletionResult`**
  (`Sources/WikiFSCore/Core/DeletionImpact.swift`) carry a typed target set
  (`ResourceDeletionTarget.page(PageID)` / `.source(SourceID)` — separate id
  namespaces share one request), a `ResourceDeletionLinkPolicy`
  (`.preserve` keeps ghost links, `.unlink` converts matching spans to plain
  display text), and the committed outcome: deleted targets, rewritten pages,
  removed bookmark ids, and the incoming-link count.
- **`DeletionImpact`** now carries stable identities (linking page ids with
  titles, bookmark node ids with folder paths) plus presentation strings, a
  deterministic order, and the incoming-link edge count.
- **`WikiStore.deleteResources(_:)`** is the one deletion seam. Impact
  recheck, provenance validation, optional rewrites, mandatory bookmark
  cleanup with sibling renumbering, and target deletion all run in ONE
  `mutateBatch` transaction. Events are buffered and emitted strictly after
  commit: `.page .updated` per rewritten page, `.bookmark .deleted` per
  removed leaf, one `.deleted` event per target row that existed. A rollback
  emits nothing. `deletePage(id:)` and `deleteSource(id:)` are compatibility
  forwarders into the `.preserve` request, so no supported caller can leave
  invalid bookmarks.
- **Atomicity seam for tests** — an internal `ProtectedDeletionFailurePoint`
  on the store (production default `.none`) throws after the rewrite, after
  bookmark cleanup, or before target deletion, so the rollback contract is
  deterministic and string-free.
- **Batch semantics** — each linking page rewrites at most once through the
  internal `createPageVersionWithProvenance` + `replaceLinksLocked` helpers
  (same version/provenance rules as `updatePage`, no amend coalescing); pages
  in the deletion set are never rewritten; one blocked source stops the whole
  batch before the first mutation; duplicate ids have one effect; missing
  targets are idempotent no-ops that still remove stale bookmarks and emit no
  false target event.

### Callers

- **`WikiStoreModel`** — one protected delete per resource type
  (`delete(_:unlinkIncomingLinks:)`, `deleteSource(_:unlinkIncomingLinks:)`);
  the model-side bookmark loops and unlink orchestration are gone. Model-side
  history, tab, and error handling run only after the store operation
  succeeds. A provenance blocker surfaces as the friendly "Can't Delete
  Source" alert from the typed catch.
- **UI** — both container views share `DeletionConfirmationCoordinator`
  (`Sources/WikiFS/Deletion/`), which produces the finite typed outcome:
  `.deleteImmediately`, `.confirm(presentation)`, `.blocked(presentation)`,
  or `.failed(presentation)`. A failed impact read routes to `.failed` and
  exposes no dialog actions, so it can never invoke deletion. The shared
  `DeletionOutcomeDialog` modifier renders the one confirmation surface. A
  provenance-blocked source shows "Source Is In Use" with each blocking page
  as a clickable "Open …" action — the user opens the page, removes the
  reference, then retries the delete (operator-directed change from the
  earlier OK-only "Can't Delete Source" alert).
- **`wikictl page delete`** — routes through the same contract. New
  `--unlink-incoming` flag chooses the policy. Stdout stays the deleted page
  id; a stderr notice reports the bookmark and link counts.

### Verification

- `swift test --filter DeletionIncomingReferenceTests` — 27 tests: atomic
  batches, batch rewrite-once, provenance gate, the three rollback failure
  points (state compared before/after), the post-commit event batch, sibling
  renumbering after a deleted bookmark event, dedup, missing targets, the
  legacy forwarders, and the model batch path (one request per selection; a
  blocked multi-source batch changes nothing and surfaces the error).
- `swift test --filter StoreEmissionExhaustivenessTests` — guards
  `deleteResources` on `mutateBatch` and both forwarders on forwarding.
- `WIKIFS_APP_TESTS=1 swift test --filter DeletionConfirmationCoordinatorTests`
  — 8 tests: every impact state, typed decision mapping, batch aggregation,
  impact-read failure, and the container wiring source contract.
- `WIKIFS_APP_TESTS=1 swift test --filter EnumeratorDeletionTests` — one
  protected delete reports the target and the bookmark leaf deletions.
- `swift test --filter WikiCtlCommandTests` — parser flags, stdout contract,
  ghost links vs unlinked bodies, bookmark cleanup counts.
- `make build` and `make test` — full gates, warnings as errors.

### Independent review outcome

An independent review (different model family) verified the transaction
boundaries, event timing, typed id separation, and SwiftUI blocked/failed
flows as clean, and raised three fixes, all applied:

1. **HIGH — batch UI path.** The containers looped single-target model calls
   for a multi-selection, so the store's all-or-nothing batch guarantee did
   not reach the UI. The model now exposes one-request-per-selection entries
   (`delete(_:unlinkIncomingLinks:)` for pages, `deleteSources(...)` and the
   error-decorating `performPageDeletion` / `performSourceDeletion` for the
   views), and both containers send the whole selection at once.
2. **HIGH — home-page cleanup on failure.** The containers cleared the home
   page even when the deletion failed. Cleanup now keys off
   `result.deletedTargets` from the committed result, so metadata survives a
   failed delete untouched.
3. **MEDIUM — CLI `didCommit` on a no-op.** `wikictl page delete` on a
   missing target reported `didCommit: true` and woke the app. `didCommit`
   now reflects actual committed change; the stdout id contract is unchanged
   (pinned by `wikictlPageDeleteMissingTargetIsIdempotentNoCommit`).

The review also noted that the stderr notice counts incoming link EDGES, not
Markdown span occurrences (`[[B]] … [[B]]` from one page counts as one).
That is deliberate: the edge count is the store's deterministic measure, the
ghost-link placeholder renders per target rather than per span, and the
contract documents the semantics. No change made.

## Verification

- `make build` — full app + File Provider build, signed, green.
- `make test` — 2974 tests pass, including the 14 new `LinkUnlinkerTests`, the
  11 new `DeletionIncomingReferenceTests` (store `pageLinkingPages`, model
  `deletionImpact`, `delete(_:unlinkIncomingLinks:)` for both pages and sources,
  and the provenance-restriction bail-out), and the existing
  `StoreEmissionTests` / `SourceAPISignatureManifestTests` (no new public
  mutator was added to the store; `pageLinkingPages` /
  `sourceProvenanceBlockers` are reads, so neither guard needed updating).
