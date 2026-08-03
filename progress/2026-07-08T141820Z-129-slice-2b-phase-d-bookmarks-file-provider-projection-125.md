---
timestamp: 2026-07-08T141820Z
title: "2026-07-08 — #129 slice 2b, Phase D: bookmarks File Provider projection (#125)"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-07-08 — #129 slice 2b, Phase D: bookmarks File Provider projection (#125)

## Progress


**Shipped (on `feature/129-2b-phase-d-bookmarks-projection`; tests green).**
Phase D: the capstone of the Resource abstraction. Bookmarks — which existed
in the store (`bookmark_nodes`, schema v16/v17) and UI (sidebar tree) since
early on but projected **nothing** to the File Provider mount — now appear as a
nested `bookmarks/` tree. Folders are directories; page/source refs are leaf
files serving the target's content. Stale refs (target deleted) render as a
small placeholder so the tree shape is preserved. This is the **nested-shape
proof** the descriptor model needed — it validates `NestedResourceProjection`
against arbitrary-depth folders + leaf refs, which the flat (Phase B) and
singleton-doc (Phase C) retrofits couldn't exercise.

**What shipped:**
- **`NestedResourceProjection` descriptor.** A value type holding `topLevel`,
  `owns`/`nodeFor`/`childrenOf`/`contentFor`/`allNodes` closures — mirrors
  `FlatResourceProjection` but handles arbitrary-depth nesting. One instance:
  `bookmarksProjection`. A `nestedProjections` registry drives every dispatch
  site (`node`/`children`/`contents`/working set), so a future nested kind is
  "add a descriptor".
- **Bookmark node builders.** `bookmarkNodeItem(for:in:)` resolves a
  `BookmarkNode` to a `ProjectedNode` — folders → directories; page refs →
  `<title>.md` serving `PageMarkdownFormat.fileContent`; source refs →
  `<filename>` serving `sourceContent`; stale refs → `Stale Reference.md/.txt`
  placeholder. All versioned by the change token so any mutation re-fetches.
  Identifier scheme: `bookmark-folder:<ULID>` / `bookmark-page-ref:<ULID>` /
  `bookmark-source-ref:<ULID>` (the bookmark-node ULID, not the target's).
- **changeToken `BookmarkTokenContributor`.** Appends a `bookmark_nodes` count
  fold to the token (now 12 fields). Every existing token literal assertion
  updated (`:0` appended). `ChangeTokenContributorTests` updated: `.bookmark`
  removed from `notYetFolded` (all kinds now contribute); order assertion
  extended.
- **Dispatch wiring.** Root children includes the `bookmarks` folder (after
  `sources`, before `indexes`). `children(of:)` default case dispatches to the
  nested projection for the topLevel or any owned folder. `node(for:)` /
  `contents(for:)` dispatch after flat projections. Working set emits all
  bookmark nodes at every depth.
- **8 new characterization tests** in `ProjectionTreeTests` (root children
  enumerate with position order, nested folder children, folder node resolves,
  page-ref serves target content, source-ref serves target content, stale-ref
  placeholder, working set includes all bookmark nodes, empty bookmarks folder
  still listed at root).
- **README bytes** updated to include `bookmarks/` in the useful-paths list.

**Gate:** full suite green — **1914 tests** (156 suites); all Phase B/C
`ProjectionTreeTests` pass (byte-identical for the existing kinds). Schema
unchanged (v26); `changeToken` format-extended (12th field).

**Slice 2b is now COMPLETE** (Phases A–D). The access layer is ready for MCP
(#124) and the daemon (#187) to build on. Phase E (model reload-on-self-write,
drops `origin`) remains deferred to its own slice.

## Verification

Historical verification remains in the progress record above.
