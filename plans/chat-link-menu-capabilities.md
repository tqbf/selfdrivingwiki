# Chat link-menu capabilities seam (`WikiLinkMenuCapabilities`)

**Status:** Implemented on `bugfix/1315-chat-source-menu` (PR #1318), follow-up to #1315.
The seam decision was made with a cross-family advisor review and operator approval.

## Problem

#1318 gave chat transcripts a native wiki-link context menu, but only the two
actions drivable from the URL alone (Open in New Tab / Open in Background).
The reader's menu also offers Add Bookmark…, Add as Source, Suggest…, Find
Similar…, and Share…. All of those need authorities the chat view layer does
not hold: the store (resolution, search, tab opening) and the File Provider
facade (shareable URLs). The question: how do we give chat menu parity without
handing `WikiStoreModel` to the chat view?

## Decision: a capability value struct, not Environment, not store-holding

`WikiLinkMenuCapabilities` (`Sources/WikiFS/Reader/WikiLinkMenuCapabilities.swift`)
is a `@MainActor` struct of optional closures. `WikiLinkMenuNSItems.items(for:
actions:capabilities:anchorView:anchorRect:)` builds menu items from the struct
alone. `.full(store:fileProvider:addURL:addBookmark:)` is the ONLY place menu
construction meets `WikiStoreModel`; hosts with full authority call it, and
everything downstream sees closures. `.none` is the degraded value.

Rejected alternatives, so they stay rejected:

- **SwiftUI Environment** (generalizing the `addURLHandler` /
  `addBookmarkHandler` pattern). Rejected on scene topology, not taste: those
  environment values are installed in `ContentView`, the root of a wiki
  window. The Activity window is a separate scene that never passes through
  `ContentView`, and its tree hosts transcripts from several wikis in one
  subtree, each resolved per row. Environment is a per-scope mechanism; this
  capability is per-instance. Environment would work in the chat pane and
  silently do nothing in the Activity window — the invisible degradation the
  codebase rejects.
- **Store-holding on the chat web view** (the reader's own pattern). A store
  reference is all-or-nothing and cannot express "can resolve links but has no
  bookmark sheet" — exactly the Activity window (store present, sheet handlers
  structurally unreachable). It would also forfeit the store-free test seam
  the menu builder now has.

The rule on `ChatTranscriptIntent` was reworded to name the actual invariant:
the transcript view layer holds **no authority**. It may carry references and
closures its host supplies (a blob store for scheme serving, link-menu
capabilities for the context menu), but it never calls a store method, reads
store state to decide, or mutates store state. Navigation flows through typed
intents. A missing capability omits its UI — never shown inert.

## Build time vs click time

AppKit assembles context menus synchronously, so the split is:

- **Build time answers "can this action exist?"** — capability presence and a
  synchronous resolution probe. Two distinct nils, both omitting: the host
  lacks the capability, or the link resolves to nothing (dead target). This
  preserves the #188 convention.
- **Click time answers "what does it act on?"** — actions RE-RESOLVE through
  the capabilities. A target deleted between right-click and click no-ops
  instead of opening a dead tab. Add Bookmark… is the one exception: its
  picker context wants the target resolved at build time, and the bookmark
  path already tolerates a just-deleted target.

Share… additionally does no File Provider work at build time — the presenter
resolves and presents only on click. This fixes the reader's eager resolution
Task (the same defect #925 fixed for the similar-pages search).

## Omission matrix

| Capability absent (or resolution nil) | Item omitted |
| --- | --- |
| `selection` nil, or `selection(url)` nil | Add Bookmark…, Open in Background |
| `openInBackground` nil | Open in Background |
| `similarPages` or `navigateToPage` nil | Suggest…, Find Similar… |
| `addURL` nil | Add as Source |
| `addBookmark` nil | Add Bookmark… |
| `sharePresent` nil (no facade) or no anchor facts | Share… |
| all (`.none`) | only the URL-only tab actions remain |

Per host: `ChatDetailView` (chat pane + internals pane) supplies `.full` from
its store, facade, and environment handlers. `ActivityWindowView` supplies
`.full(store:, fileProvider: nil)` while the row's wiki window is open and
`.none` once it closes — Add as Source / Add Bookmark… stay nil there because
the sheet-hosting environment handlers are unreachable from that scene.
`AgentQueueView` defaults to `.none`. Capabilities are refreshed on every
`updateNSView` (like `blobStore`), or a row's menu would freeze against a
store that closed.

## Share extraction

`Share…` moved from inline construction in `WikiReaderView.willOpenMenu` into
the shared builder as a `.share` action, routed through `bottomActions(for:)`
for resolved page, source, and chat links. Chat targets have no File Provider
URL yet, so their Share… click is a deliberate no-op — the reader's existing
behavior, inherited for parity; wiring chat-share is a future task. Unresolved
and anchor links lost the dead Share… item the reader used to build (its task
always resolved nil). External links keep the reader's inline raw-URL Share
untouched; chat external links keep WebKit's native Share.

## Testing

`WikiLinkMenuNSItemsTests` builds menus with hand-rolled stub capabilities —
no store in scope — and pins the golden per-URL-kind titles, the omission
matrix, payload routing, Share's click-time-only work, and the deleted-target
no-op. Chat-side tests cover the composed menu per link kind, the degraded
`.none` menu, and capabilities-swap retargeting. The `updateNSView` write
itself is a one-line property assignment (reviewed, not hosted-tested);
on-screen menu rendering is a manual check.
