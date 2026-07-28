---
timestamp: 2026-06-29T032436Z
title: "2026-06-28 — Reveal in Finder for pages and sources"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-06-28 — Reveal in Finder for pages and sources

## Progress


Added a "Reveal in Finder" action on every page and source surface so users can
locate the File Provider-mounted file in Finder (to drag to other apps, open in
Terminal, etc.).

**New methods on `FileProviderSpike`.**  `revealPageInFinder(id:)` and
`revealSourceInFinder(id:)` resolve the item's user-visible URL via the daemon
(reusing the existing `resolvePageByTitleURL` / `resolveSourceByNameURL` helpers)
then call `NSWorkspace.shared.activateFileViewerSelecting([url])` — the same
call used by `VerificationPopover` for the wiki root.

**Surfaces:**
- **Page sidebar context menu** — "Reveal in Finder" after Share, single-select
  only (multi-select would open N Finder windows).
- **Page detail view** — button in the view-mode header row, after Share.
- **Source sidebar context menu** — wired via a new `onRevealInFinder` closure on
  `SourceRow`; single-select only.
- **Source detail view** — button in the view-mode header row, after Share.

All surfaces are guarded by `fileProvider.path != nil` so the item is hidden
until the domain is mounted. Branch `feature/add-reveal-in-finder`, PR #90.

## Verification

Historical verification remains in the progress record above.
