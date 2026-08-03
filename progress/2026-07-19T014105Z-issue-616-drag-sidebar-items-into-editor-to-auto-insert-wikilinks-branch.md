---
timestamp: 2026-07-19T014105Z
title: "2026-07-18 — Issue #616: drag sidebar items into editor to auto-insert wikilinks (branch `feature/drag-wikilinks`, PR #623)"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-07-18 — Issue #616: drag sidebar items into editor to auto-insert wikilinks (branch `feature/drag-wikilinks`, PR #623)

## Progress


**Problem:** When editing a page or source in markdown edit mode, the user wanted
to drag a sidebar row (Page/Source/Chat/Bookmark folder) into the editor and
have a canonical wikilink inserted at the drop point — instead of typing
`[[page:Some Title]]` by hand. The sidebar drag-vending side was already
complete (every sidebar list vends a `wikiSidebarItem` pasteboard item); the
editor side needed wiring.

**Solution (v1, in-app sidebar→editor drag only; per `plans/drag-wikilinks.md`):**

- `Sources/WikiFSLinks/DroppedLinkFormatter.swift` — pure, Foundation-only
  mapper (`link(for:id:displayName:)`, `markdownList(for: [Item])`) that
  emits the canonical ULID-pinned `[[kind:<ULID>|<alias>]]` form. The alias
  is cosmetic (Phase 5 display-at-render resolves the ULID regardless of
  alias text), and falls back to the raw ULID when the target is stale
  (`displayName == nil` OR empty). Lives in `WikiFSLinks` (depends only on
  `WikiFSTypes`) so unit tests can hit it without AppKit. Takes
  `ParsedLink.LinkType` (not `SidebarDragPayload.Kind` — that lives in
  `WikiFSCore`) to keep the formatter module-graph-clean; the kind→LinkType
  mapping is a 1:1 switch on the @MainActor builder.
- `Sources/WikiFS/Editor/DropLinkTextView.swift` — `NSTextView` subclass that
  accepts `wikiSidebarItem` drops and inserts the builder's text at the
  visual drop point (`characterIndexForInsertion`). **Load-bearing
  divergence from `WikiReaderView`:** the override registers the sidebar
  type ALONGSIDE the inherited text types (`string`/`RTF`/`filenames`),
  NOT instead of them (the #133/#385 competing-subview concern doesn't
  apply — the editor is a terminal NSTextView with no WKWebView child
  below it). Forcing sidebar-only would have silently broken
  drag-selected-text-to-move within the editor. Falls through to `super`
  for non-sidebar drags so NSTextView's default text-drop behavior is
  preserved.
- `Sources/WikiFS/Editor/SidebarDropBuilder.swift` — `@MainActor` factory
  that closes the loop: resolves display names via
  `WikiStoreModel.resolveAttachmentName`, routes single-vs-multiline, and
  guards on `store.agentRunCount > 0` (Step 4 protection — never silently
  insert into a buffer an agent is about to overwrite).
- `Sources/WikiFS/Editor/ScrollableTextEditor.swift` — new `sidebarDropBuilder`
  field on the `NSViewRepresentable`; `makeConfiguredTextView` now returns a
  `DropLinkTextView` (subclassed); `updateNSView` re-wires the builder on
  every SwiftUI evaluation.
- `Sources/WikiFS/Pages/PageDetailView.swift`,
  `Sources/WikiFS/Sources/SourceDetailView.swift` — pass `sidebarDropBuilder`
  closure to `ScrollableTextEditor` in both edit-mode surfaces.
- `Sources/WikiFSTypes/DebugLog.swift` — new `editor` os_log channel
  (subsystem `com.selfdrivingwiki.debug`) for drop/agent-guard events.

**v1 scope tradeoff:** ships Option B (flat depth-0 list for bookmark folders)
rather than nested indentation (Option A — depth-aware drag payloads). The
`DroppedLinkFormatter.markdownList(for:)` signature already accepts
`(depth, kind, id, displayName)` tuples so the data shape is forward-compatible
with the follow-up PR; v1 passes `depth: 0` for every leaf (the bookmark drag
source's `leafPayloads(under:)` already flattens a folder into a leaf list, so
the drop builder can't recover original tree depth without depth-aware payloads
or a bookmark-tree re-walk — both documented as follow-ups in the plan).

**Tests:** `DroppedLinkFormatterTests` (16 tests — pure-function correctness
for all 4 kinds + nil/empty displayName fallback + multi-depth list formatting
+ empty list + ULID canonicity + tuple-overload parity);
`DroppedLinkRoundTripTests` (11 tests — `WikiLinkParser.parse(_:)` accepts
every formatter output AND `WikiLinkRewriter.canonicalize(...)` is a **no-op**
on every formatter output, proving the drop-inserted link is already canonical
and save won't rewrite it — the idempotency fast-path that makes inserting the
canonical form strictly better than inserting `[[source:Name]]`);
`DropLinkTextViewDropTests` (5 tests — wiring: `makeConfiguredTextView`
returns `DropLinkTextView`; `sidebarDropBuilder` storage + invocation;
`registerForDraggedTypes` registers sidebar ALONGSIDE `.string` — the
divergence regression guard; `linkType(for:)` is the 1:1 inverse of
`BookmarksOutlineView.dragKind`);
`SidebarDropBuilderIntegrationTests` (5 tests, tagged `.integration` — store-side
builder against a real `GRDBWikiStore`: page drop resolves title; multi-payload
produces a flat depth-0 list; stale target falls back to raw ULID alias; empty
payload list rejected). The fast-tier `--skip` regex in
`.github/workflows/ci.yml` was extended to include the integration suite name
(per AGENTS.md convention).

**Status:** PR open (#623), not merged.

## Verification

Historical verification remains in the progress record above.
