---
timestamp: 2026-07-04T215127Z
title: "2026-07-04 — Sources default-open opens an in-app tab; \"Open With\" submenu for external editors (#139)"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-07-04 — Sources default-open opens an in-app tab; "Open With" submenu for external editors (#139)

## Progress


The default-open gestures on **sources** (double-click + the "Open" / "Open N
Sources" context-menu item) launched the file in its default external app
(Preview for a PDF), inconsistent with pages/bookmarks which open an in-app tab
on the same gestures. The external launch is a legitimate workflow but belongs
behind an explicit action. Fixes [#139](https://github.com/tqbf/selfdrivingwiki/issues/139).

- **Sources default-open → in-app tab.** `SourcesContainerView.onOpen` now calls
  `store.openTab(.source(id))` (matching `onOpenBackground` and the pages/bookmark
  path) instead of `fileProvider.openSource(id:)`. The old external behavior
  moves to a new `onOpenExternal` callback. The `SourcesListView` docstring
  (which documented the external double-click as intentional) is corrected.
- **Finder-style "Open With" submenu** on sources, pages, and bookmarks, listing
  the registered editors for the content type (default marked "(Default)",
  separator, then the rest, then "Other…"). `OpenWithMenu` (new) builds the
  submenu from `NSWorkspace.urlsForApplications(toOpen: UTType)` — discovery is
  **content-type based**, not URL based, so the menu builds synchronously from
  the source's MIME/extension (pages are always Markdown); the mount URL is only
  resolved at click time. "Other…" presents an `NSOpenPanel` app picker
  (`AppPicker`). Gated on the File Provider mount being up (same as "Reveal in
  Finder"). Single + batch on sources/pages.
- **`FileProviderSpike.openSource(id:with:)` / `openPage(id:with:)`** gain an
  optional `appURL: URL?`. With nil, the default handler launches (sync
  `NSWorkspace.open`); with an app URL, `open(_:withApplicationAt:configuration:)`
  launches that editor. Both share a private `launch(url:with:)` helper. `openPage`
  resolves via the existing `resolvePageByTitleURL` (same `page-by-title`
  identifier share/reveal use, so no drift) — mirroring `openSource`.
- **Bookmarks.** `FileProviderSpike` is threaded through `BookmarksContainerView`
  → `BookmarksOutlineView` → controller (which had no file-provider access
  before). The pageRef/sourceRef context menu gains the "Open With" submenu;
  `openWithAppAction` routes pageRef→`openPage`, sourceRef→`openSource`. Content
  type for a source bookmark is looked up from the store by id.
- **Drive-by:** dropped an unused `let callbacks` binding in
  `BookmarksOutlineView.acceptDrop` that SourceKit surfaced during the edit.

Not in scope for this cut: the "App Store…" item (Finder's deep-link format is
undocumented) and "Change All" (system default-app binding). Easy to add later.

Gates: `swift build` clean; `swift test` — 1365 tests in 104 suites pass (one
flaky timing test in `PipeDrainingTests.streamProcessCapturesStderrLines` fails
under full-suite load but passes 3/3 in isolation; pre-existing, unrelated).

## Verification

Historical verification remains in the progress record above.
