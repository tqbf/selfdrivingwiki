---
timestamp: 2026-07-05T004720Z
title: "2026-07-04 — Drag sidebar rows onto the welcome screen or any detail tab to open it (#133)"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-07-04 — Drag sidebar rows onto the welcome screen or any detail tab to open it (#133)

## Progress


Sidebar rows (pages, sources, bookmarks) weren't draggable. Now any of them can
be dragged onto the welcome screen **or onto any open detail tab** (including
the rendered markdown body) to open its target as a new focused tab.
Implements [#133](https://github.com/tqbf/selfdrivingwiki/issues/133).

- **`SidebarDragPayload`** (`WikiFSCore`, new) — a `Codable` value carrying a
  `kind` (page/source) + id, with a computed `selection: WikiSelection`. Kept in
  the model layer (no `Transferable`) so it's unit-testable; the app layer adds
  `Transferable` + a `UTType.wikiSidebarItem` declared in the app's Info.plist
  (`UTExportedTypeDeclarations`, conforms to `public.item`). The Info.plist
  declaration is mandatory — without it, AppKit can't match the drag to the drop
  target and the gesture silently no-ops.
- **Drag sources** — `PagesListView`/`SourcesListView` gain
  `pasteboardWriterForRow` (a custom `NSPasteboardWriting` carrying the payload
  JSON) + `.copy` local drag-source mask. `BookmarksOutlineView` dual-registers
  the `.string` node id (intra-tree **reorder** still works) AND the
  resolved-target payload (`pageRef`→page, `sourceRef`→source); folders carry
  the node id only. Bookmarks resolve at drag-start, so the drop target is
  bookmark-agnostic.
- **Drop target — SwiftUI chrome** — `WikiDetailView` wraps its whole
  `detailContent` in `.dropDestination(for: SidebarDragPayload.self)` →
  `store.openTab(payload.selection)`. Covers the welcome screen, header, and
  banners. Innermost target, so URL/file drops still fall through to the
  window-level ingest destination.
- **Drop target — WKWebView body** — the rendered markdown is a `WKWebView`, and
  SwiftUI's `.dropDestination` does NOT receive drags over an embedded
  `NSViewRepresentable`'s NSView (AppKit delivers them into the web view's own
  subtree). So `WikiReaderWebView` is itself the `NSDraggingDestination` for its
  body: it overrides `registerForDraggedTypes` to register ONLY the sidebar-item
  type, plus `draggingEntered`/`draggingUpdated`/`performDragOperation` to decode
  the payload and call `store.openTab`. WebKit's internal subviews still register
  their own broad types for web-content drag/drop, but a sidebar payload doesn't
  conform to those, so AppKit walks up to the WKWebView subclass. This is the
  fix that made drops work on the markdown body, not just the top portion.
- **Tests** — `SidebarDragPayloadTests` (Codable round-trip + selection mapping)
  and `SidebarDragPasteboardBridgeTests` (pasteboard-level bridge: writer →
  `NSPasteboard` → decodable JSON, including the bookmark dual-representation and
  folder node-id-only cases). Full 1378-test suite green. Live DnD verified via
  `os_log` traces: drops land on the welcome screen, the SwiftUI chrome, and the
  WKWebView markdown body.

## Verification

Historical verification remains in the progress record above.
