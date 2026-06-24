# Right-click external link → Add as Source

> **Status: implemented (`feat/url-context-menu-add`, PR #52).** Extends the
> link context menus (`plans/link-context-menus.md`) so right-clicking an
> external http(s) link offers **Add as Source**, which opens the existing "Add
> from URL" sheet pre-filled with the URL (the same Fetch + ingest path as the
> toolbar button). Works in **both** the native Textual reader (`MarkdownPreview`)
> and the WKWebView large-source reader (`SourceWebView`).

## Feature

Right-click an **external http(s)** link in any native reader (page, source,
system prompt, changelog) and the context menu now leads with **Add as Source**.
Choosing it opens `AddFromURLSheet` with the field pre-filled; the user hits
**Fetch** (or Enter) and the URL is fetched + ingested exactly like the
**Add from URL…** toolbar button (`store.ingestURL`).

It sits above the existing **Open in Browser** / **Copy Link** items, so the
menu for an external link is:

```
Add as Source        ← opens sheet pre-filled with the URL
Open in Browser
Copy Link
```

## Scope

- **Native Textual reader (`MarkdownPreview`)** — where the link context-menu
  feature already lives. The new item is available in every native reader
  (pages, sources, system prompt, changelog) because the handler reaches it via a
  SwiftUI environment value (see below).
- **WKWebView large-source reader (`SourceWebView`)** — the 500 KB+ path
  (`plans/source-web-reader.md`). WKWebView has no public macOS API for
  customizing its context menu (the `WKUIDelegate` `contextMenuConfiguration…`
  family is iOS/visionOS-only — confirmed in WebKit's `WKUIDelegate.h`), so a
  `SourceDetailWebView: WKWebView` subclass overrides `NSView.willOpenMenu`. It
  prepends **Add as Source** only when WebKit's menu contains a link item
  (`WKMenuItemIdentifierCopyLink`); on selection it hit-tests the captured
  right-click point in the DOM (`document.elementFromPoint` → walk to the `<a>`)
  and keeps only http(s) `href`s, then hands the URL to the **same**
  `\.addURLHandler` environment value — so both readers open the identical sheet.
  The AppKit→CSS coordinate flip + the hit-test JS are pure helpers
  (`cssHitTestPoint`, `linkHrefAtJS`), unit-tested.

## Design

The pure/view split mirrors the existing link-context-menu feature:

1. **Pure layer** (`WikiLinkMenuBuilder.actions(for:)`) gains an `.addAsSource`
   case. The external-link branch now returns `[.addAsSource, .openInBrowser,
   .copyLink]` **only for http/https**; other external schemes (mailto:, etc.)
   stay `[.openInBrowser, .copyLink]` — `URLIngestService.normalizeURL` only
   accepts http(s), so offering the item on a `mailto:` link would land the user
   on a sheet whose Fetch button is permanently disabled.

2. **Wiring** (`WikiLinkContextMenu.items(for:store:fileProvider:addURL:)`) gains
   an optional `addURL: ((String) -> Void)?`. The `.addAsSource` case calls
   `addURL(url.absoluteString)`; like `.copyFilePath` (which skips when no
   `FileProviderSpike` is wired), it omits itself when `addURL` is nil (e.g. the
   SwiftUI `#Preview`).

3. **Reaching the sheet without per-view plumbing.** The context menu lives deep
   in `MarkdownPreview`, but the "Add from URL" sheet is presented by
   `ContentView`. Rather than thread an `onAddURL` closure through
   `ContentView → WikiDetailView → {PageDetailView, SourceDetailView,
   SystemPromptDetailView, ChangeLogDetailView} → MarkdownPreview`, a single
   SwiftUI environment value carries the handler:

   ```swift
   extension EnvironmentValues {
       @Entry var addURLHandler: ((String) -> Void)? = nil
   }
   ```

   `ContentView` sets it to present the sheet; `MarkdownPreview` reads it and
   forwards it to `WikiLinkContextMenu`. This mirrors how `MarkdownPreview`
   already injects behavior via `\.openURL`, and makes the item work in **every**
   reader uniformly.

4. **Pre-fillable sheet.** `AddFromURLSheet(store:initialURL:)` seeds its
   `@State` URL field from `initialURL` in a custom init (so the field is
   populated on first paint, not via a racy `.onAppear` sync). `ContentView`
   drives the sheet with `.sheet(item: $pendingAddURL)` (an `Identifiable`
   `PendingAddURL` payload) instead of a plain `Bool`, so the presentation
   carries the pre-fill value and auto-clears on dismiss.

## Behavior choice

Two UX options were considered:

- **Ingest immediately** (fire `store.ingestURL` from the menu item, like the
  sibling "Open in Browser" item).
- **Open the Add URL sheet pre-filled** (same Fetch button + inline progress /
  error as the toolbar button).

Chosen: the sheet. A context-menu action that hits the network and writes to the
wiki benefits from the sheet's inline **Fetching…** progress and **error** row
(404, network failure, empty body), and a chance to confirm before the fetch.

## Files

- `Sources/WikiFSCore/WikiLinkMenuBuilder.swift` — `.addAsSource` case +
  http(s)-only external branch.
- `Sources/WikiFS/LinkContextMenuItems.swift` — `addURL` param + case wiring +
  `EnvironmentValues.addURLHandler` (`@Entry`).
- `Sources/WikiFS/MarkdownPreview.swift` — reads `\.addURLHandler`, passes it to
  `WikiLinkContextMenu.items`.
- `Sources/WikiFS/AddFromURLSheet.swift` — `initialURL` param + custom init.
- `Sources/WikiFS/ContentView.swift` — `pendingAddURL: PendingAddURL?` +
  `.sheet(item:)` + sets `\.addURLHandler` + `PendingAddURL` wrapper.
- `Sources/WikiFS/WikiDetailView.swift` — drops the `showingAddFromURL` binding;
  empty-state button calls `addURLHandler?("")`.
- `Sources/WikiFS/SourceWebView.swift` — `SourceDetailWebView` subclass
  (`willOpenMenu` + DOM hit-test) reads `\.addURLHandler` and threads it through
  `WebViewRep`.

## Tests

- `WikiLinkMenuBuilderTests` — http/https return `[.addAsSource, .openInBrowser,
  .copyLink]` (two cases); `mailto:` unchanged.
- `SourceDetailWebViewMenuTests` — `cssHitTestPoint` (AppKit→CSS flip + clamp)
  and `linkHrefAtJS` (coordinate embedding + http(s) filter + POSIX decimal).
  Full suite: 965 tests pass.
