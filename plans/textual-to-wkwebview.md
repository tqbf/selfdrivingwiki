# Replace the vendored Textual reader with WKWebView everywhere

**Branch:** `feature/textual-to-wkwebview`.
**Status:** implemented (1022 tests green; manual gates AC.3/AC.5/AC.6/AC.7 pending).

## Goal

Replace the vendored Textual (`Packages/Textual/`, ~193 Swift files) reader with
the WKWebView + `MarkdownHTMLRenderer` path across **every** reader surface —
pages, sources, system prompt, changelog, and the agent transcript — then remove
the Textual dependency entirely. The agent transcript gains `[[wiki-link]]`
support as part of this migration (it was the original task).

## Implementation Summary

Textual is the app's only large vendored dependency, and we carry a **localized
fork** of it (touching `NSTextInteractionView`, `AppKitTextInteractionOverlay`,
`TextSelectionModel`, `LinkContextMenu.swift`, `View+Textual.swift`) solely to
get whole-link right-click selection + a link-context-menu seam — functionality
that WKWebView gives for free. Meanwhile we already built and shipped a
WKWebView reader (`SourceWebView` / `AgentTranscriptWebView`) that renders the
same markdown via `MarkdownHTMLRenderer` with measurable performance wins
(~130 ms vs ~10 s on 500 KB sources). Maintaining two rendering stacks doubles
the surface for every reader feature (find bar, zoom, anchors, ghost links,
context menus, quote highlight). Consolidating onto one eliminates the fork,
the ~193-file dependency, and the feature-divergence tax.

## Current state: two render paths

| | Textual reader (`MarkdownPreview`) | Web reader (`SourceWebView`) |
| --- | --- | --- |
| Backend | `StructuredText` + `WikiLinkStylingParser` (custom `MarkupParser`) | `MarkdownHTMLRenderer` (swift-markdown → HTML) in `WKWebView` |
| Markdown→render | `AttributedString` in a SwiftUI `ScrollView` | HTML in a single internally-scrolling `WKWebView` |
| Used by | PageDetailView, SourceDetailView (small), SystemPromptDetailView, ChangeLogDetailView | SourceDetailView (large, >96 KB) |
| Agent transcript | — | `AgentTranscriptWebView` (sidebar + Query chat) |

**Files that `import Textual` (the full removal target):**
- `MarkdownPreview.swift` — the reader view itself.
- `WikiLinkStylingParser.swift` — recolors missing links red + applies quote highlight.
- `NumberedParagraphStyle.swift` — `.id("p\(n)")` on paragraphs for anchor scroll.
- `LinkContextMenuItems.swift` — wires `WikiLinkMenuBuilder` actions into Textual's `LinkMenuItem`s.

**Pure (Textual-free) helpers that survive the migration:**
`WikiLinkMenuBuilder` (WikiFS — classifies URLs → actions), `ReaderMarkdown`
(shared linkify+footnote pre-pass), `WikiLinkMarkdown` (URL helpers:
`target(from:)`, `resolvedKind(from:)`, `fragment(from:)`, `isSamePageAnchor`),
`AnchorBlock` (heading/paragraph parsing for anchors).

## Feature-parity matrix

What the Textual reader does today, and how the web reader covers it:

| Feature | Textual (`MarkdownPreview`) | Web reader status | Porting approach |
| --- | --- | --- | --- |
| Markdown rendering | `StructuredText` | ✅ `MarkdownHTMLRenderer` (full GFM: tables, lists, code, blockquotes, images, inline) | Already shipped; no change |
| Wiki-link linkify | `ReaderMarkdown.prepared` | ✅ Same shared pre-pass | Already shipped |
| Footnote expansion | `ReaderMarkdown` | ✅ Same | Already shipped |
| External link open | `.environment(\.openURL)` | ✅ `decidePolicyFor` → `NSWorkspace` | Already shipped |
| `wiki://` click routing | `WikiLinkMarkdown.target/resolvedKind/fragment` | ⚠️ **Buggy** — `SourceWebView.route` reads `comps.path` (empty for query-encoded URLs) | Fix: use the query-based helpers (§3) |
| Find bar (⌘F) | `ScrollViewProxy.scrollTo` + `WikiLinkStylingParser` highlight | ✅ `window.find()` + `<mark>` | Already shipped |
| Quote highlight + scroll | `WikiLinkStylingParser.highlightQuote` (`.backgroundColor`) | ✅ `window.find` + `<mark>` + TreeWalker fallback | Already shipped |
| Anchor scroll (`[[Page#Section]]`) | `ScrollViewProxy.scrollTo(id)` | ✅ `getElementById(slug).scrollIntoView` | Already shipped |
| Text selection + copy | `.textual.textSelection(.enabled)` | ✅ Native WKWebView selection | Already shipped (and cross-paragraph — the reason the agent transcript moved to WKWebView) |
| Context menus (basic) | **Required a fork** (whole-link selection + menu builder) | ✅ **Free** — WKWebView ships Copy / Copy Link / Open Link / Look Up / Share | No code needed |
| Context menus (custom: Suggest, Find Similar, Copy as Wiki Link, Copy File Path, Add as Source) | `WikiLinkContextMenu` → `LinkMenuItem` | ⚠️ Only "Add as Source" ported (`SourceDetailWebView.willOpenMenu`) | Port remaining items via `willOpenMenu` (§5) |
| Ghost links (red missing) | `WikiLinkStylingParser.recolorLinks` | ❌ Constant `true` (no ghost coloring) | CSS rule on `wiki://missing` href (§2) |
| Zoom (⌘+/⌘−/⌘scroll) | `.textual.fontScale(readerZoom)` + `.zoomShortcuts/.zoomScroll` | ❌ **Missing** | `WKWebView.pageZoom` (§4) |
| Paragraph-id anchors | `NumberedParagraphStyle` (`.id("p\(n)")`) | N/A — web reader uses heading slugs + `window.find` for quotes | Not needed; heading slugs cover `#Section` |

**Two gaps + one bug** are the real work: ghost links, zoom, and the `wiki://`
routing fix. Everything else already ships.

## Implementation plan

### Phase 1 — Unify the web reader into a general-purpose `WikiReaderView`

`SourceWebView` is currently source-specific (its `.task` consumes the store's
pending anchor keyed on a `WikiSelection`). Generalize it into a `WikiReaderView`
usable by all four `MarkdownPreview` call sites, parameterized by:
- `markdown: String` (already there)
- `store: WikiStoreModel` (already there)
- `currentSelection: WikiSelection?` (already there)
- `fileProvider: FileProviderSpike?` (new — for "Copy File Path" context menu; pages pass it, others don't)
- find-bar params (already there)
- `addURLHandler` — **already** environment-injected via `@Environment(\.addURLHandler)` in `SourceWebView`. Keep it as-is; it feeds the http(s) "Add as Source" context-menu item through the new `WikiLinkMenuNSItems` builder (Phase 4), paralleling how `fileProvider` feeds "Copy File Path". Don't add a new param — it's already wired.

The async load (`WebViewRep.startLoad` → `Task.detached` → `ReaderMarkdown.prepared`
→ `MarkdownHTMLRenderer.render` → `SourceWebView.documentHTML`) is already
general. The `.task` anchor-consume logic is already `WikiSelection`-generic.

`SourceWebView` is renamed `WikiReaderView`; `SourceDetailWebView` (the WKWebView
subclass with `willOpenMenu`) becomes `WikiReaderWebView`; and the private
`WebViewRep` (the `NSViewRepresentable` that owns `documentHTML`, `route(_:)`,
and `highlightJS`) is renamed `WikiReaderRep` to match — so Phase 7's test target
`WebViewRep.highlightJS` becomes `WikiReaderRep.highlightJS`. The document HTML
(`documentHTML`) and theme CSS are reused as-is.

### Phase 2 — Fill the feature gaps

**§2.1 Ghost-link coloring (CSS, no JS).** `WikiLinkMarkdown.linkified` already
encodes resolution into the URL host: missing → `wiki://missing?title=…`,
resolved → `wiki://page?title=…` / `wiki://source?title=…`. After HTML render
these are `<a href="wiki://missing?…">`. A single CSS rule colors them red:

```css
a[href^="wiki://missing"] { color: #ff453a; }
```

To make `isResolved` work off the main actor (the convert runs in
`Task.detached`), compute lightweight existence sets on the main actor before
the task and pass them in:

```swift
let pageTitles = Set(store.summaries.map { $0.title })
let sourceNames = Set(store.sources.compactMap { $0.displayName ?? $0.filename })
let prepared = ReaderMarkdown.prepared(markdown) { name, kind in
    kind == .source ? sourceNames.contains(name) : pageTitles.contains(name)
}
```

This replaces the constant `{ _, _ in true }` and gives real ghost links.

**Field-name note (verified):** `SourceSummary` has `displayName: String?` and
`filename: String` (confirmed in `Sources/WikiFSCore/SourceSummary.swift`), and
`store.summaries` elements have `.title` — so the accessors above are correct.
One nuance: the proven `@MainActor` helper `sourceExists(displayName:)` delegates
to `store.resolveSourceByName`, which may match by **either** display name or
filename. The snapshot above keys on `displayName ?? filename` only, so a link
targeting the raw `filename` of a source that has a *separate* display name
would be treated as missing. To match the proven API exactly, build the set from
**both**: `Set(sources.flatMap { [$0.displayName, $0.filename].compactMap { $0 } })`.
Confirm `resolveSourceByName`'s exact matching rule during execution and mirror
it.

**§2.2 Zoom (`WKWebView.pageZoom`).** The existing `.zoomShortcuts($readerZoom)`
and `.zoomScroll($readerZoom)` modifiers only update an `@AppStorage("reader.zoom")`
double — they're view-tree modifiers, not Textual-specific. Feed that value into
the WKWebView in `updateNSView`:

```swift
func updateNSView(_ webView: WikiReaderWebView, context: Context) {
    webView.pageZoom = readerZoom   // WKWebView API, macOS 11+
    …
}
```

The `.zoomShortcuts`/`.zoomScroll` modifiers attach to the `WikiReaderView`
exactly as they attach to `MarkdownPreview` today — no change to those
modifiers. (The agent transcript does not need zoom — it's a fixed-size chat
feed — so it skips this.)

### Phase 3 — Fix `wiki://` routing

Replace the buggy `comps.path` extraction in `route(_:)` with the proven
query-based helpers (the same `MarkdownPreview` uses):

```swift
private func route(_ url: URL) {
    if WikiLinkMarkdown.isSamePageAnchor(url),
       let frag = WikiLinkMarkdown.fragment(from: url) {
        // scroll within the document via getElementById / window.find
        return
    }
    guard let title = WikiLinkMarkdown.target(from: url) else { return }
    let frag = WikiLinkMarkdown.fragment(from: url)
    switch WikiLinkMarkdown.resolvedKind(from: url) {
    case .page:   store?.selectPage(byTitle: title, anchor: frag)
    case .source: store?.selectSource(byDisplayName: title, anchor: frag)
    case nil:     break
    }
}
```

**Why `comps.path` is wrong:** `WikiLinkMarkdown` encodes the target as
`wiki://page?title=Encoded`. `URLComponents(…).path` is `""` for a
query-encoded URL with no path component — so every `wiki://` click resolved
to an empty title (silent no-op). Went unnoticed because sources rarely embed
page links and the source-reader's anchor/quote work flows through the store's
pending-anchor path, not link clicks.

### Phase 4 — Port custom context menus via `willOpenMenu`

WKWebView's default context menu already covers Copy, Copy Link, Open Link, Look
Up, and Share — **no fork needed** (the entire reason Textual was forked). The
custom wiki-link items port onto the same `willOpenMenu(_:with:)` override that
`SourceDetailWebView` already uses for "Add as Source".

The hit-test JS (`linkHrefAtJS`, already shipped) returns the `<a>` href under
the cursor. **Note:** the current `linkHrefAtJS` hard-filters to http(s) only
(`el.protocol==="http:"||el.protocol==="https:"`), so it returns `""` for
`wiki://` hrefs. It must be extended (or a sibling `wikiHrefAtJS` added) to also
return `wiki://` hrefs before the custom wiki-link items can work — otherwise the
menu would be silently empty for wiki links. Then build `NSMenuItem`s from the
**Textual-free** `WikiLinkMenuBuilder.actions(for:)`:

| URL kind | `WikiLinkMenuBuilder` actions | Menu items |
| --- | --- | --- |
| `wiki://missing` | `.suggest`, `.copyWikiLink` | Suggest… (semantic submenu), Copy as Wiki Link |
| `wiki://page` / `wiki://source` | `.findSimilar`, `.copyWikiLink`, `.copyFilePath` | Find Similar…, Copy as Wiki Link, Copy File Path (if spike) |
| `http(s)` | `.addAsSource`, `.openInBrowser`, `.copyLink` | Add as Source, Open in Browser, Copy Link (already shipped for Add-as-Source) |

The wiring closures (`store.selectPage`, `store.searchSimilar`, pasteboard,
`NSWorkspace`) are extracted from `WikiLinkContextMenu` into a new
`WikiLinkMenuNSItems` (AppKit, no Textual) that returns `[NSMenuItem]` instead
of `[LinkMenuItem]`. The pure `WikiLinkMenuBuilder` is unchanged.

### Phase 5 — Replace `MarkdownPreview` call sites

Swap each of the four `MarkdownPreview(…)` call sites to `WikiReaderView(…)`:

| Call site | Notes |
| --- | --- |
| `PageDetailView.swift:88` | Add `.zoomShortcuts($readerZoom).zoomScroll($readerZoom)`; pass `fileProvider` |
| `SourceDetailView.swift:413` | Merge with the large-source branch into one `WikiReaderView` — it handles **all** sizes (the size threshold that gated `SourceWebView` vs `MarkdownPreview` is no longer needed; the web reader is faster at every size). **Must add** `.zoomShortcuts($readerZoom).zoomScroll($readerZoom)` — the current web branch (line 407) has none; zoom is only on the native branch (416-417), so it would be lost in the merge if copied blindly |
| `SystemPromptDetailView.swift:66` | No `fileProvider`; no `currentSelection` |
| `ChangeLogDetailView.swift:35` | No `fileProvider` |

The size threshold (`@AppStorage reader.webThresholdKB`) is removed — the web
reader becomes the only reader, so the gate is obsolete.

### Phase 6 — Agent transcript wikilinks (the original task)

`AgentTranscriptWebView` already renders via `MarkdownHTMLRenderer` but skips
the linkify pre-pass. Add it for `.assistantText` and `.result` rows (`.userText`
stays literal — a user typing `[[Foo]]` is not a link):

```swift
MarkdownHTMLRenderer.render(ReaderMarkdown.prepared(text) { _, _ in true })
```

Constant `true` is fine here: the agent references pages it just wrote, and the
transcript has no store to check existence. For routing, add an optional
`onWikiLink: ((URL) -> Void)?` to **both** `AgentTranscriptWebView` and its
intermediate parent views (stored on the Coordinator, refreshed in
`updateNSView`). Handle `wiki://` in the existing `decidePolicyFor`: when
`navigationType == .linkActivated` and `url.scheme == "wiki"`, invoke
`onWikiLink?(url)` then `decisionHandler(.cancel)` — do **not** fall through to
`.allow`, or WKWebView will try to load the `wiki://` URL into the web view (a
broken-navigation error page). Mirror the existing http(s) branch, which already
does `NSWorkspace.open` + `.cancel`.

**Threading — three paths, not one.** The store does NOT live at the
`AgentTranscriptWebView` instantiation site; it lives two levels up. The
intermediate views hold only `@Bindable var launcher: AgentLauncher` (no store),
so they must each gain a new `onWikiLink: ((URL) -> Void)?` parameter that they
forward unchanged to their child:

- **Query/chat path:** `QueryConversationView` (`@Bindable var store`) constructs
  the closure → forwards it through `QueryTranscriptView` (new param) → which
  forwards it to `AgentTranscriptWebView` (new param). `QueryTranscriptView`
  itself has no store; it is a pure passthrough.
- **Activity-feed / sidebar path:** `AgentTranscriptSidebar` (no store) →
  `AgentActivityView` (no store) → `AgentTranscriptWebView`. Both gain the param.
  The closure is constructed where the store lives: `ContentView` and `LintView`
  both own `@Bindable var store` and construct `AgentTranscriptSidebar`, so they
  supply the closure. (Both views were verified to have the store.)
- **Query-internals path:** `QueryConversationView` *also* constructs
  `AgentActivityView` directly at line 71 (the "Show internals" debug branch),
  which builds `AgentTranscriptWebView` at `AgentActivityView.swift:48`. That
  call site must pass the same closure — and since `QueryConversationView` owns
  the store, it constructs it there. (Without this, the new `onWikiLink` param
  on `AgentActivityView` is a compile error at line 71.)
- **No detail column (e.g. a context where navigation is impossible):** pass
  `nil` — links render but don't navigate (still a strict improvement over
  literal brackets).

The closure body (built where the store is in scope):
```swift
{ url in
    guard let title = WikiLinkMarkdown.target(from: url) else { return }
    let frag = WikiLinkMarkdown.fragment(from: url)
    switch WikiLinkMarkdown.resolvedKind(from: url) {
    case .page:   store.selectPage(byTitle: title, anchor: frag)
    case .source: store.selectSource(byDisplayName: title, anchor: frag)
    case nil:     break
    }
}
```

Same-page `[[#anchor]]` links are inert in the transcript (it's a chat feed, not
a single document).

### Phase 7 — Remove Textual

After all call sites are migrated and tests pass:

1. Delete `MarkdownPreview.swift`, `WikiLinkStylingParser.swift`,
   `NumberedParagraphStyle.swift`, `LinkContextMenuItems.swift`.
2. Remove `.package(path: "Packages/Textual")` and
   `.product(name: "Textual", …)` from `Package.swift`.
3. Delete `Packages/Textual/`.
4. Update `Package.swift` comment (currently explains the fork rationale).
5. Update `ISSUES.md` (remove the "Vendored Textual fork" entry).
6. Update `SWIFTUI-RULES.md` / docs referencing Textual.

`WikiLinkStylingParser.quoteRange` has 17 tests (`QuoteHighlightTests`) covering
pure-Swift quote-matching edge cases (whitespace collapse, occurrence stepping,
partial/multiline matches). These are **not** dropped without replacement: the
web reader's equivalent logic lives in `WikiReaderRep.highlightJS` (a pure static
func that emits a JS string — mark it `nonisolated` during the rename so tests
can call it off the main actor). Add a new test suite
(`QuoteHighlightJSTests`) that asserts against the **emitted JS string output**
for representative quotes — whitespace-collapsed, multi-occurrence, and
special-character cases — guarding the escaping and the match/occurrence logic
that replaces `quoteRange`. This is cheap (string assertions, no JSContext
needed) and catches regressions in the logic that the retired Swift tests
covered. The actual `<mark>` placement in a live WKWebView remains a manual gate
(AC.7), since it requires a rendered document.

## What changes (summary)

| File | Change |
| --- | --- |
| `SourceWebView.swift` → `WikiReaderView.swift` | Rename; generalize; add `fileProvider` param; fix `route(_:)`; add zoom; ghost-link CSS |
| `SourceDetailWebView` → `WikiReaderWebView` | Rename; extend `willOpenMenu` for all custom wiki-link items |
| `LinkContextMenuItems.swift` → `WikiLinkMenuNSItems` | Rewrite to return `[NSMenuItem]` (drop `LinkMenuItem`) |
| `AgentTranscriptWebView.swift` | Linkify assistant/result text; add `onWikiLink`; handle `wiki://` |
| `AgentActivityView.swift`, `QueryTranscriptView.swift`, `AgentTranscriptSidebar.swift`, `ContentView.swift`, `LintView.swift` | Thread `onWikiLink` closure from the store |
| `PageDetailView.swift`, `SourceDetailView.swift`, `SystemPromptDetailView.swift`, `ChangeLogDetailView.swift` | Swap `MarkdownPreview` → `WikiReaderView` |
| `SourceDetailView.swift` | Remove the size-threshold web/native gate |
| `Package.swift` | Remove Textual dependency + product |
| **Delete** | `MarkdownPreview.swift`, `WikiLinkStylingParser.swift`, `NumberedParagraphStyle.swift`, old `LinkContextMenuItems.swift`, `Packages/Textual/` |

## Acceptance criteria

- **AC.1** Every reader surface (pages, sources, system prompt, changelog, agent
  transcript) renders markdown via `WikiReaderView` / `AgentTranscriptWebView`.
  `grep -r "MarkdownPreview\|import Textual\|StructuredText\|SourceWebView\|SourceDetailWebView" Sources/`
  returns nothing (the rename to `WikiReaderView`/`WikiReaderWebView` is complete).
- **AC.2** `Package.swift` has no Textual dependency; `Packages/Textual/` is
  deleted; `swift build` succeeds.
- **AC.3** `[[wiki-links]]` render as clickable links in the agent transcript;
  clicking a `[[Page]]` in a Query response navigates to that page.
- **AC.4** Ghost links (missing targets) render red in `WikiReaderView`.
- **AC.5** ⌘+/⌘−/⌘0/⌘scroll zoom works in `WikiReaderView` (page + source
  readers).
- **AC.6** Right-clicking a wiki link in `WikiReaderView` shows the custom menu
  (Suggest / Find Similar / Copy as Wiki Link / Copy File Path) **plus**
  WKWebView's native Copy / Copy Link / Look Up / Share.
- **AC.7** Find bar (⌘F), quote highlight, and anchor scroll
  (`[[Page#Section]]`) all work in `WikiReaderView`.
- **AC.8** `swift test` passes (existing tests updated; no new failures).

## Test strategy

- **`WikiReaderView` routing (pure):** extract the `route(_:)` URL→selection
  classification into a pure `nonisolated static` helper (like
  `SourceWebView.resolveScrollTarget`) and test: page link → `selectPage`,
  source link → `selectSource`, missing link → inert, same-page anchor → scroll,
  http(s) → external. This guards the `comps.path` fix.
- **Ghost-link CSS:** test that `WikiLinkMarkdown.linkified` with a real
  `isResolved` closure produces `wiki://missing` hrefs for nonexistent targets
  (already testable via `WikiLinkMarkdown` tests; add CSS-selector assertion).
- **`AgentTranscriptWebView` linkify (pure):** row HTML for `.assistantText`
  with `[[Page]]` produces `<a href="wiki://…">`; `.userText` stays literal.
  Extract `feedRowHTML`/`chatRowHTML` visibility to `internal static` for testing
  (they're already `private static`).
- **Context menu (manual):** right-click each link kind; verify the correct
  items appear and the native items are present. Hard to unit-test (NSView
  menu path); mirror `SourceDetailWebView`'s approach (pure hit-test helpers
  already tested).
- **Regression:** find bar, quote highlight, anchor scroll tests pass on the
  unified reader. `QuoteHighlightTests` (17) are retired, replaced by the new
  `QuoteHighlightJSTests` (JS-string assertions against `highlightJS` output —
  see Phase 7).

## Review strategy

**Plan-mode review:** dispatch `plan-reviewer` before handoff; fix/rebut all
critical/high findings; re-run if any remain.

**Implementation review:** after all phases + `swift test` green, dispatch
`general-purpose` subagent to review. Verify no `import Textual` remains, all
call sites migrated, no dead code from the old reader. Manual gates: AC.3, AC.5,
AC.6, AC.7 (interactivity / live-WKWebView behavior not unit-testable).

## Documentation strategy

- Update `PLAN.md` doc-index (the broadened row) + `PROGRESS.md` entry.
- Update `ISSUES.md` (remove "Vendored Textual fork" entry).
- Update `Package.swift` comment (remove fork rationale).
- `SWIFTUI-RULES.md`: no change (rules are framework-agnostic), but verify no
  Textual-specific guidance lingers.

## Risks, blockers, and required decisions

- **WKWebView instance overhead:** each `WKWebView` is a heavyweight view
  (spawns a WebKit content process). Currently 1–2 are visible at once (a detail
  reader + the agent transcript sidebar). Post-migration that's unchanged — tabs
  show one detail at a time. The sidebar's `AgentTranscriptWebView` already
  coexists with a detail reader today. Low risk.
- **`WikiLinkStylingParser.quoteRange` tests (17):** the pure-Swift quote-range
  logic is replaced by JS `window.find` + TreeWalker. Those tests are retired
  (the web path has equivalent coverage). Confirm the operator is OK losing
  Swift-level unit coverage of quote matching in favor of JS-level + manual.
- **Agent transcript streaming + linkify cost:** `appendRows` builds HTML
  synchronously on the main actor. `ReaderMarkdown.prepared` is ~24 ms on 513
  KB; agent turns are small, so acceptable. If a large turn stalls, move to
  `Task.detached` — but that complicates the append-only streaming model (DOM
  splicing preserves in-progress selection). Defer unless profiling demands.
- **Decision needed:** confirm the operator wants a **clean cut-over** (remove
  `MarkdownPreview` and the size threshold in one migration) rather than keeping
  it as a temporary fallback. The plan assumes clean cut-over; the threshold gate
  is removed in Phase 5.

## Out of scope

- Same-page `[[#anchor]]` scroll within the agent transcript (chat feed, not a
  single document).
- Syntax highlighting in code blocks (neither reader does this today).
- Math/LaTeX rendering (not in either reader today).
