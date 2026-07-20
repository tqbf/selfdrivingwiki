# Bug #1 — Transcript scrollbar crosses the traffic lights (WKWebView overlay-scroller fix)

> **Status:** Investigation + plan only. No repo files modified.
> **Scope:** Bug #1 ONLY. Bug #2 (left margin) ships separately — do NOT touch it.
> **Surface:** The **Agent / Extraction Queue window** (`ActivityWindowView`) — its transcript is a
> `ChatWebView` (`WKWebView`).
> **macOS 15 / Swift 6.0.**

---

## Why the previous Option A was a no-op (context, not the fix)

`MenuBarItemController` builds the queue window as `NSWindow(.titled, …)` +
`NSHostingController(rootView:)` + `toolbarStyle = .unified` + `titleVisibility = .hidden`
(`Sources/WikiFS/Window/MenuBarItemController.swift:402-409`). Because there is **no**
`.fullSizeContentView` in the style mask and **no** `titlebarAppearsTransparent`, AppKit already lays
the hosted SwiftUI content below the unified toolbar — so a SwiftUI-level
`.safeAreaInset(edge: .top)` / `contentLayoutGuide` constraint restates what AppKit already does. The
operator confirmed at runtime that the scrollbar thumb **still crosses the traffic lights**. So this
is **not** a content-inset problem; it is **WKWebView overlay-`NSScroller`-specific**.

---

## 1. Confirmed root cause

### The transcript is a bare `WKWebView`
`ChatWebView` is an `NSViewRepresentable` that returns a `WKWebView` from `makeNSView`
(`Sources/WikiFS/Chats/ChatWebView.swift:113-141`). It is created with **no scroll-view / scroller
configuration whatsoever**:

```swift
// Sources/WikiFS/Chats/ChatWebView.swift:129-134
let webView = WKWebView(frame: .zero, configuration: config)
webView.navigationDelegate = context.coordinator
webView.uiDelegate = context.coordinator
webView.underPageBackgroundColor = .clear
webView.pageZoom = zoom
webView.allowsBackForwardNavigationGestures = false
// ← no scrollerStyle, no contentInsets, no clipsToBounds, no _clipsToVisibleRect
```

`ActivityWindowView` then hosts it full-bleed
(`Sources/WikiFS/Queue/ActivityWindowView.swift:551-565`, `.frame(maxWidth: .infinity,
maxHeight: .infinity)`), so the WebView (and its internal overlay scroller) own the detail column's
full height right up under the unified toolbar.

### Why the overlay scroller reaches into the title-bar band
WKWebView on macOS manages its own `NSScrollView` + overlay `NSScroller` privately. Two WebKit
behaviors combine to leak the scroller over the traffic lights (confirmed against the WebKit source
via the `WebKit/WebKit` repo):

1. **`_automaticallyAdjustsContentInsets` defaults to `true`.** When on, WKWebView "adjusts its
   content to account for elements like the window title bar" and is explicitly aware of content
   scrolling under the title bar (WebKit `WebViewImpl.hasScrolledContentsUnderTitlebar()`). Because
   the WebView is full-bleed right up to the toolbar in this window, WebKit positions the overlay
   scroller against the **title-bar geometry** rather than the WebView's visible content rect — the
   scroller track extends into the title-bar band and the thumb crosses the traffic lights.

2. **The scroller is not clipped to the visible rect.** WebKit offers a private
   `_clipsToVisibleRect` ("the most direct way to ensure content, including scrollers, is clipped to
   the visible bounds") which, by default, is **not** engaged here. With it off, the overlay scroller
   is free to paint beyond the WebView's visible content area.

### Why the app's other scroll views don't have this bug
Every hand-rolled `NSScrollView` in this codebase disables the auto-inset and pins the scroller
style:

```swift
// e.g. Sources/WikiFS/Chats/ChatsListView.swift:83-102  (also PagesListView, SourcesListView, BookmarksOutlineView)
scrollView.scrollerStyle = .overlay
scrollView.drawsBackground = false
scrollView.contentView.automaticallyAdjustsContentInsets = false
```

`ChatWebView`'s `WKWebView` is the **only scrollable surface in the app that skips this**, so it is
the only one whose scroller leaks over the title bar.

> Note on accessibility of the inner scroll view: on **macOS**, `WKWebView` does **not** expose
> `scrollView` publicly (that property is iOS-only). The `ChatsListView` pattern
> (`contentView.automaticallyAdjustsContentInsets = false`) therefore cannot be applied by reaching
> into the WKWebView's `NSScrollView`. The fix must go through `WKWebView`'s own SPI
> (`_clipsToVisibleRect` / `_automaticallyAdjustsContentInsets`), as WebKit itself prescribes.

---

## 2. Targeted fix

Configure the `WKWebView` in `ChatWebView.makeNSView` so its overlay scroller is clipped to the
visible bounds and not positioned against the title bar. All on the `WKWebView` instance — **no**
CSS change, **no** window change, **no** autosave-frame change.

**Before** (`Sources/WikiFS/Chats/ChatWebView.swift:129-134`):
```swift
let webView = WKWebView(frame: .zero, configuration: config)
webView.navigationDelegate = context.coordinator
webView.uiDelegate = context.coordinator
webView.underPageBackgroundColor = .clear
webView.pageZoom = zoom
webView.allowsBackForwardNavigationGestures = false
```

**After:**
```swift
let webView = WKWebView(frame: .zero, configuration: config)
webView.navigationDelegate = context.coordinator
webView.uiDelegate = context.coordinator
webView.underPageBackgroundColor = .clear
webView.pageZoom = zoom
webView.allowsBackForwardNavigationGestures = false

// Bug #1: keep the overlay scroller inside the WebView's visible bounds so it can
// no longer paint over the window's traffic lights. WKWebView manages its own
// NSScrollView privately (no public `scrollView` on macOS), so this goes through
// the SPI WebKit itself exposes for exactly this:
//  • _clipsToVisibleRect — clips drawing (incl. the scroller) to the visible rect.
//  • _automaticallyAdjustsContentInsets — off, so the scroller is NOT positioned
//    against the title-bar band.
webView.setValue(true,  forKey: "_clipsToVisibleRect")              // SPI
webView.setValue(false, forKey: "_automaticallyAdjustsContentInsets") // SPI
```

If the SPI keys ever reject (older/newer WebKit), guard them so a future OS can't crash the view:
```swift
// Safer variant (use this if you prefer belt-and-suspenders):
@discardableResult private func setSPI(_ key: String, _ value: Any, on webView: WKWebView) -> Bool {
    guard webView.responds(to: NSSelectorFromString("setValue:forKey:")) else { return false }
    webView.setValue(value, forKey: key); return true
}
// then:
setSPI("_clipsToVisibleRect", true, on: webView)
setSPI("_automaticallyAdjustsContentInsets", false, on: webView)
```

(`setValue(_:forKey:)` will throw if the key is unknown; the guarded variant only matters if you want
to be defensive. These two keys are long-stable across the macOS versions this app targets.)

### Why both properties
- `_clipsToVisibleRect = true` is the **direct** remedy the operator asked for ("keep the scroller
  within bounds") — it makes WebKit clip the scroller to the visible rect instead of letting it leak
  above the content area.
- `_automaticallyAdjustsContentInsets = false` removes the title-bar-aware scroller positioning that
  put the track up in the title-bar band in the first place. Set both; either alone may leave the
  thumb misplaced depending on the WebKit build.

### What is NOT changed
- The shared `ChatWebView` body CSS (`padding: 10px 12px 10px 0`, `ChatWebView.swift:773`) is
  **untouched** — the in-wiki `ChatView` depends on it (bug #2 territory).
- `MenuBarItemController` window creation / autosave (#635/#645) is untouched.
- The fix applies to **every** `ChatWebView` instance (in-wiki chat, the Activity window, and the
  `AgentQueueView` internals feed) — which is correct: none of them should leak a scroller over a
  title bar. In the main window the in-wiki chat sits below the toolbar in the detail column, so this
  is a no-op-visible there; it only changes behavior where the WebView reaches a title bar (the
  Activity window).

---

## 3. Acceptance criteria (operator-visual)

> The implementer is headless and **cannot** visually verify. Build/test only; **visual verification
> is deferred to the operator.**

- [ ] **Operator:** Open the **Agent Queue** window, select an item with a long transcript, scroll.
      The scrollbar thumb **no longer crosses / overlaps** the close/minimize/maximize buttons at the
      top-left. The scroller track stays within the transcript content area.
- [ ] **Operator:** Resize the window smaller (toward the 640×400 min) and scroll — still no overlap.
- [ ] **Operator:** Repeat in the **Extraction Queue** window — same result.
- [ ] **Operator:** In-wiki **Chat** tab — transcript still scrolls normally; scroller still appears
      on the right; no visual regression (this surface was already below the toolbar).
- [ ] **Operator:** The queue windows' unified toolbar (pause/resume/halt menu) and traffic lights
      are fully visible and clickable at all times; window frame/position persistence (#635) intact.

---

## 4. Risks / what not to break

- **Private SPI usage.** `_clipsToVisibleRect` and `_automaticallyAdjustsContentInsets` are
  underscore-prefixed SPI. They are long-stable on macOS (used widely for exactly this) and present
  on macOS 15, but a future OS could rename/remove them. **Mitigation:** use the guarded
  `setSPI(…)` variant so a missing key can't crash; the view still works (just without the clip) and
  the regression is caught at visual-QA. (Private SPI is acceptable here per the project's existing
  stance on pragmatic native behavior; if a fully-public approach is later required, fall back to the
  SwiftPM `@_spi` import of WebKit, but that's heavier than warranted today.)
- **In-wiki `ChatView`.** The fix is on `WKWebView` config only, not CSS — the chat's left margin,
  right-scrollbar clearance, and zoom are untouched. Verify the in-wiki chat scrolls normally (it
  should be a no-op-visible since it's already below the toolbar).
- **Autosave-frame handling (#635/#645).** Untouched — the change is in `ChatWebView.makeNSView`,
  not `MenuBarItemController`.
- **Shared queue-window path.** Both the Agent and Extraction queue windows share
  `showQueueWindow(for:)` and the same `ActivityWindowView`; the fix applies uniformly, which is
  intended.
- **App Review (if ever shipped).** Private SPI is flagged by some review processes. This project is
  currently local-only / dev-signed (see loaded context), so this is not a blocker now; flag for the
  future shipping path.

---

## 5. Build / test commands

```bash
swift build                                   # compile (must succeed — SPI selectors exist on macOS 15)
swift test                                    # full suite (~1.5 min, in-memory SQLite fixtures) — run before PR
swift test --filter ChatWebViewLinkifyTests   # the only test touching ChatWebView (linkify logic; no layout test exists)
```
Per `AGENTS.md`: CI runs a single `swift` job over the full suite. Run `swift test` before opening a
PR. Work on a feature branch; never push/merge to `main`. There is no automated layout test for this
bug — it is verify-by-eye (operator), per §3.

---

## 6. Evidence index (file:line)

| Claim | Location |
| --- | --- |
| `ChatWebView.makeNSView` — bare `WKWebView`, no scroller config | `Sources/WikiFS/Chats/ChatWebView.swift:113-141` (esp. 129-134) |
| `ChatWebView` body CSS (do NOT touch) | `Sources/WikiFS/Chats/ChatWebView.swift:773` |
| `ActivityWindowView` hosts the WebView full-bleed | `Sources/WikiFS/Queue/ActivityWindowView.swift:551-565` |
| Queue window = manual `NSWindow` + `NSHostingController`, `.unified`, `titleVisibility = .hidden` | `Sources/WikiFS/Window/MenuBarItemController.swift:402-409` |
| Codebase pattern: every other `NSScrollView` sets `.overlay` + `automaticallyAdjustsContentInsets = false` | `Sources/WikiFS/Chats/ChatsListView.swift:83-102` (also `PagesListView.swift`, `SourcesListView.swift`, `BookmarksOutlineView.swift`) |
| macOS `WKWebView.scrollView` is **not** public (iOS-only) — confirmed via Apple forums / docs | (see WebKit/WebKit deepwiki: `WebViewImpl`) |
| Fix properties: `_clipsToVisibleRect`, `_automaticallyAdjustsContentInsets` | WebKit source (`WebKit/WebKit`, `WebViewImpl`) — confirmed via deepwiki |
