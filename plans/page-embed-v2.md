# Plan v2: Generalized `![[X]]` Embed (Pages + Sources)

> **Status:** Unified implementer brief. Merges `page-embed-transclusion.md`
> (page-only) + `page-embed-sources-extension.md` (source extension), and applies
> the v1 plan-review fixes + baked-in decisions. Every claim cites a file:line;
> all seams confirmed current against the working tree.
>
> **Non-goals (explicitly deferred to a follow-up):** any `page_links` graph
> edge / `role` schema bump for *page* transclusions; lifting the parser reject
> gate; a name→id reverse map on `WikiRenderContext`; render-on-demand
> extraction. v2 is **render-only**.

---

## 0. TL;DR

Generalize `![[X]]` so it embeds **pages and non-media sources** in a
collapsed `<details>` disclosure, lazily fetched + rendered on expand through
the **same** `ReaderMarkdown.prepared` + `MarkdownHTMLRenderer.render` +
`evaluateJavaScript` seam the reader already uses. Media sources
(image/video/audio/mermaid/**PDF**) keep rendering inline via the existing
`WikiLinkMarkdown.embedHTML` path **unchanged**.

The entire feature is implemented by:

1. **Linkify layer (pure):** a new `transclusionEmbedHTML(…)` helper in
   `WikiLinkMarkdown.linkified`, dispatched at **both** embed call sites
   (L193 canonical, L242 name) **before** the media `embedHTML` dispatch.
   Pages always transclude; non-media sources transclude; media sources fall
   through to `embedHTML`.
2. **Expand layer (lazy, off-main):** one `WKScriptMessageHandler`
   (`embedFetchName`) keyed by `data-sdw-embed-kind` that fetches the body via
   `WikiReadPool.asyncRead` (page → `getPage`; source → `sourceEmbedBody`),
   renders through the shared pipeline, and **injects via `innerHTML` using a
   JS function that takes the HTML as a parameter** (never string-concatenated).
3. **Cycle safety:** lazy-collapse is the primary bound (bodies are not fetched
   until expanded ⇒ no eager recursion); a **required** JS-side visited-set
   (ancestor `data-sdw-embed-path` chain) renders a `↩ cycle` marker and is
   unit-tested.

---

## 1. Goal

Support:

```
![[PageName]]            → page transclusion (collapsed <details>)
![[page:PageName]]       → page transclusion (escape hatch; never source)
![[source:SourceName]]   → source embed — media inline (unchanged) OR non-media transclusion
![[<ULID>]]              → canonical by id; kind inferred from which table owns it
![[Target|Header Label]] → alias as the <summary> header text
```

Bodies are rendered markdown (pages → `bodyMarkdown`; sources → head markdown
or raw UTF-8 for native text). Expanding is lazy (fetch+render only on first
open); embeds *inside* an embedded body are themselves collapsed — so the tree
only deepens on explicit user action and cycles cannot infinite-loop.

### Why this works (feasibility)

The reader renders to **HTML into a `WKWebView`** (`WikiReaderView.swift:9`,
the `NSViewRepresentable` wrapping `WKWebView`), **not** to a flat
`AttributedString` or native SwiftUI views. HTML's `<details>`/`<summary>` is
collapsed-by-default by spec — exactly the disclosure semantics wanted, with
**no pipeline change**. The `!` embed-prefix detection already exists
(`WikiLinkSpan.isEmbedPrefix`, `WikiLinkSpan.swift:128`), and the renderer is a
pure, off-main `MarkupVisitor` (`MarkdownHTMLRenderer: MarkupVisitor`,
`MarkdownHTMLRenderer.swift:19`).

---

## 2. Syntax spec

| Form | Resolution |
|---|---|
| `![[PageName]]` (bare) | **Page namespace first.** If `isResolved(name, .page)` → page transclusion. **Else** try source namespace: `embedInfo(name)` non-nil → source transclusion (media sources still go inline; see §3). On collision (both exist) → **page wins**. |
| `![[page:PageName]]` | Always page. Never consults source namespace (escape hatch). |
| `![[source:SourceName]]` | Always source (existing prefix; unchanged resolution). Content-type dispatch decides inline-vs-`<details>` (§3). |
| `![[<ULID>]]` | Canonical by id: `pageIDToName[id]` first → `.page`; else source lookup → `.source`; else broken. |
| `![[Target\|Alias]]` | `Alias` is the `<summary>` header text; resolution uses `Target`. |

- `[[X]]` (no `!`) remains an ordinary navigable cite link — **unaffected**.
- The `!` prefix detection already guards against `\![[` and `!![[`
  (`WikiLinkSpan.swift:128`); embeds inside backtick code spans are literal
  (protected ranges, `WikiLinkSpan.protectedCodeRanges`).
- **Ambiguous source** (loose-key non-unique): `embedInfo` returns `nil`
  (render context excludes ambiguous loose keys via `uniqueSourceLooseKeys`) →
  broken embed. No disambiguation UI in v2.

---

## 3. Content-type render dispatch

At linkify time, for every **resolved** `![[…]]` embed, dispatch BEFORE the
media `embedHTML` returns `nil`:

```
if target is a SOURCE:
    info = embedInfo(name)                         // SourceEmbedInfo(id, mimeType, target)
    if info.target != nil:                         // external media / diagram
        → existing embedHTML (inline)              // UNCHANGED
    else if mimeType is media (image/|video/|audio/|pdf):  // PDF = media (DECISION §11.1)
        → existing embedHTML (inline)              // UNCHANGED
    else:                                          // non-media source
        → transclusionEmbedHTML(kind:.source)      // §3.1
else if target is a PAGE:
    → transclusionEmbedHTML(kind:.page)            // always (pages are non-media)
else:
    → broken embed                                 // §7
```

**Media predicate = image/ + video/ + audio/ + `MimeType.isPDF` + Mermaid +
external `EmbedTarget`.** This reuses the exact predicate order `embedHTML`
already encodes (`WikiLinkMarkdown.swift:398-473`); the `<details>` branch is
the *fallback* when `embedHTML` would return `nil` (`:474`).

### 3.1 The shared transclusion `<details>`

One helper, `transclusionEmbedHTML(display:id:kind:target:fragment:) -> String`,
emits (the only addition over a plain link is the kind discriminator + empty
body state):

```html
<details class="sdw-transclusion" data-sdw-embed-kind="page|source"
         data-sdw-embed-id="<ULID if canonical, else empty>"
         data-sdw-embed-target="<urlenc name when name-based, else empty>"
         data-sdw-embed-fragment="<fragment or empty>"
         data-sdw-embed-path="<ancestor id chain for cycle check>">
  <summary><span class="sdw-embed-title">Resolved Title</span></summary>
  <div class="sdw-embed-body" data-sdw-state="empty">
    <span class="sdw-embed-placeholder">Loading…</span>
  </div>
</details>
```

- `<details>` is collapsed-by-default per HTML spec ⇒ AC: collapsed unless opened. No `open` attribute is emitted.
- Header = embedded page's **current** title via `displayName(id, .page)`
  (self-heals on rename) — or alias if provided.
- `data-sdw-embed-id` (canonical ULID) and `data-sdw-embed-target` (name) carry
  resolution into the DOM so the JS bridge can request the body (§6). See §5
  for which is carried when.

---

## 4. The unified render seam (lazy expand)

### 4.1 The pure fetch+render function (TESTABILITY — §8)

Factor the expand-time work into a **pure, side-effect-free** function:

```swift
/// Pure: given a read-only store view (WikiReadPool member or in-memory fixture
/// store) and a render context, return the rendered HTML for one embed body.
/// Resolves the id, fetches the body, runs the shared pipeline. Never touches
/// the main actor, the WebView, or evaluateJavaScript. Fully unit-testable.
static func renderEmbedBody(
    store: GRDBWikiStore,          // read-only member, query_only=ON
    id: PageID,
    kind: ParsedLink.LinkType,
    context: WikiRenderContext     // fresh from store.renderContext() at expand
) throws -> String                 // "" / sentinel for missing; see §7
```

Body:

```swift
// 1. Fetch raw content off-main (method-atomic, no transaction, no inference):
let raw: String? = switch kind {
case .page:
    let page = try store.getPage(id: id)               // GRDBWikiStore.swift:2817
    PageMarkdownFormat.stripped(body: page.bodyMarkdown, title: page.title)
case .source:
    try Self.sourceEmbedBody(store: store, id: id)     // §4.2
default:
    nil
}
// 2. Shared render pipeline (identical to top-level pages):
guard let raw else { return "" }                        // caller renders placeholder §7
let prepared = ReaderMarkdown.prepared(
    markdown: raw,
    isResolved: context.isResolved,
    embedInfo: context.embedInfo,
    displayName: context.displayName,
    pinnedExtractionID: context.pinnedExtractionID)
return MarkdownHTMLRenderer.render(Document(parsing: prepared))
```

This is the single reuse point guaranteeing nested `![[…]]` collapse and
`[[…]]` link. It is pure given an in-memory store (the `#658` in-memory SQLite
fixtures support this) — **unit-test THAT** (§8).

### 4.2 `sourceEmbedBody` (new off-main read helper)

```swift
/// Pure read against a read-only store. Never triggers extraction.
static func sourceEmbedBody(store: GRDBWikiStore, id: PageID) throws -> String? {
    // 1. Preferred: extracted markdown HEAD.
    if let head = try store.processedMarkdownHead(sourceID: id) { return head.content } // :3607
    // 2. Native text source: raw UTF-8 bytes are readable text.
    let src = try store.getSource(id: id)                                   // :7084
    if MimeType.isText(src.mimeType),
       let data = try store.sourceContent(id: id),                          // :3335
       let text = String(data: data, encoding: .utf8) { return text }
    // 3. Not extractable here (binary/PDF-unless-media, no extraction yet).
    return nil   // caller injects placeholder §7 — NO extraction is triggered
}
```

Runs **inside** `readPool.asyncRead { … }` (`WikiReadPool.swift:43`):
`query_only=ON`, no transaction, no inference. Mirrors `SourceDetailView`'s
`currentMarkdownContent` (which deliberately returns `nil` for `isHTMLSource`
until a head version exists — `SourceDetailView.swift:347`). Do **not** decode
raw bytes for HTML/PDF.

### 4.3 The expand handler (Coordinator, `@MainActor`)

On first open of a `.sdw-transclusion`, the injected `WKUserScript` posts
`{kind, id, target, path}` to the `embedFetchName` handler. The Coordinator:

1. Resolves the id: use `data-sdw-embed-id` if present; **else**
   `MainActor.assumeIsolated { store.pageID(forTitle:) }` for a name-based
   page embed (`WikiStoreModel.pageID(forTitle:)`, `WikiStoreModel.swift:680`).
   (Sources are always id-resolved at linkify via `embedInfo`, so this branch is
   page-only.)
2. Obtains a **fresh** `WikiRenderContext` from `store.renderContext()`
   (`WikiStoreModel.swift:2852`, memoized + event-bus-invalidated) — **not** the
   load-time snapshot — so nested link/embed resolution reflects current state.
3. Hops **off-main** into `readPool.asyncRead { roStore in
   try renderEmbedBody(store: roStore, id: id, kind: kind, context: context) }`.
4. Hops back to the main actor (`WebKit is main-thread`) and injects via the
   **safe JS function** (§4.4).

No transaction, no extraction on this path (hard invariant). Surface failures
via `DebugLog`, never `try?` (house rule).

### 4.4 Safe JS injection (SECURITY — MANDATORY)

**Inject a JS function that takes the HTML as a parameter and assigns via
`element.innerHTML = html`** — do NOT string-concatenate the HTML into the
`evaluateJavaScript` source. Use `WikiReaderRep.jsString(html)`
(`WikiReaderView.swift:1233`) to escape the HTML argument into a JS
double-quoted literal, then call a predefined setter:

```swift
let escaped = WikiReaderRep.jsString(html)
webView.evaluateJavaScript(
    "sdwInjectEmbed(\"\(selectorId)\", \"\(escaped)\")"
)
```

where `sdwInjectEmbed` is injected once (a `WKUserScript` at document start)
and defined as:

```js
function sdwInjectEmbed(embedId, html) {
  const body = document.querySelector('[data-sdw-node="' + embedId + '"] .sdw-embed-body');
  if (body) {
    body.innerHTML = html;            // parameter, not concatenated source
    body.setAttribute('data-sdw-state', 'loaded');
  }
}
```

The embed `<details>` carries a per-node id (`data-sdw-node="<ULID-or-uuid>"]`)
so the setter finds the right body even with multiple expands in flight.

**Security note (CONSCIOUS decision):** the pipeline does **ZERO** HTML
sanitization — `MarkdownHTMLRenderer.visitHTMLBlock`/`visitInlineHTML` return
`rawHTML` verbatim (`MarkdownHTMLRenderer.swift:80,112`). Embedding a target is
therefore **XSS-equivalent to viewing that target page directly**. That is
acceptable for a **local single-user wiki** (the threat model is the user's own
content), but it must be a stated, conscious decision. The parameter-based
injection keeps the attack surface equal to a normal page view (no new
injection vector) and avoids the classic string-concat `</script>` breakout.
Note: `innerHTML` does **not** execute `<script>` tags (HTML spec), but **does**
fire `onerror`/`onload` handlers on injected elements — identical to normal
page rendering.

---

## 5. Name→PageID clarity (linkify vs expand)

| Embed form | What `linkified` carries | How the header/body resolve |
|---|---|---|
| **Canonical ULID** `![[01H…]]` | `data-sdw-embed-id="<ULID>"` (target empty) | Header healed via `displayName(id, .page)`; expand fetches by `id` directly. |
| **Name-based page** `![[Foo]]` | `data-sdw-embed-target="Foo"` (id empty) | Header = `display` (alias or `Foo`); at **expand** the id is resolved via `store.pageID(forTitle:)`. |
| **Source** `![[source:Foo]]` | `data-sdw-embed-id="<srcULID>"` (from `embedInfo`) | Resolved to id at linkify; expand fetches by id. |

- The **missing-page** branch uses `isResolved(name, .page)` (already captured
  in `WikiRenderContext.isResolved`, `WikiRenderContext.swift:238`) → emits the
  broken embed (§7) with **no fetch metadata** (no expand ever fires).
- **Do NOT** add a name→id reverse map to `WikiRenderContext` for v2. Resolve
  name→id at expand time on the main actor.

---

## 6. Fresh context at expand (DECISION)

At expand, obtain a **fresh** `WikiRenderContext` from `store.renderContext()`
(`WikiStoreModel.swift:2852` — memoized, invalidated by `WikiEventBus`-driven
reloads) rather than reusing the load-time snapshot the top-level render built
(`WikiReaderView.swift:853`). This ensures nested link/embed resolution inside
the embedded body reflects current state (a page renamed, a source re-ingested
since page load). `renderContext()` is cheap after the first build (cached).

---

## 7. Broken / missing / not-yet-extracted embed

### 7.1 Missing page or source
Render a `<details>` (collapsed, inert — no fetch metadata) whose header is
muted/red and whose body says "Page not found" / "Source not found":

```html
<details class="sdw-transclusion" data-sdw-state="missing">
  <summary><span class="sdw-embed-title">Page not found: Ghost</span></summary>
</details>
```

**CSS (NEW rule — the existing `a[href^="wiki://missing"]` selector at
`WikiReaderView.swift:243` is an `<a>` attribute selector and does NOT apply to
a `<details>`):** add its own rule reusing the same red:

```css
.sdw-transclusion[data-sdw-state="missing"] .sdw-embed-title { color: #ff453a; }
```

### 7.2 Not-yet-extracted source (`renderEmbedBody` returns `nil`)
A source with no head markdown and no decodable text bytes (binary; PDF is media
and never reaches here). Render a muted placeholder + an open link — **no
extraction is triggered** (hard read-path invariant):

```html
<div class="sdw-embed-body sdw-embed-empty">
  <span class="sdw-embed-placeholder">Source not yet extracted.</span>
  <a href="wiki://source?id=<ULID>&title=<name>">Open “Foo.doc”</a>
</div>
```

Render-on-demand extraction is **rejected** — it violates "NO inference on the
read path" and would block the embed on a multi-second pdf2md run.

---

## 8. Cycle safety (lazy-collapse PRIMARY + visited-set REQUIRED + tested)

### Why cycles can't infinite-loop (primary bound)
A cycle `A → B → A` cannot infinite-loop because:
1. The body of any embed is fetched **only when that specific `<details>` is
   opened** (user action), never at load and never recursively.
2. When B's body is rendered, the `![[A]]` inside it becomes its **own
   collapsed** `<details>` — A's content is not fetched at that point.
3. Re-expanding A-inside-B renders a fresh collapsed `<details>` for B; the
   chain is finite at any moment and only lengthens on explicit user action.

### Visited-set (REQUIRED defense-in-depth — cheap + tested)
Track a per-branch ancestor chain via `data-sdw-embed-path` (a space- or
comma-separated id list carried on each `<details>`). At expand time, before
fetching, the JS (or the Swift handler reading the attribute) checks whether
the target id is **already in its own ancestor chain**:

- **If yes** → render a muted marker instead of fetching:
  ```html
  <div class="sdw-embed-body sdw-embed-cycle">
    <span class="sdw-embed-placeholder">↩ PageName (cycle)</span>
  </div>
  ```
  The `<details>` gets `data-sdw-state="cycle"` and no fetch fires.
- **If no** → proceed with the fetch; the new `<details>` emitted inside the
  body inherits `data-sdw-embed-path` = parent's path + this embed's id.

Key the visited-set on `(kind, id)` so a page and a source with the same
ULID-ish string don't false-positive. The check is a string-contains on a
`data-` attribute — no store work, no Swift recursion. This gives the user a
**signal** that they've cycled rather than silently nesting A→B→A→B arbitrarily
deep (each level is a real fetch + render = real memory).

**Do NOT** add a render-time graph walk that pre-walks the tree — that would
eagerly fetch at load, violating the lazy requirement and the off-main read
invariant.

---

## 9. The PDF = media decision (DECISION, §11.1)

`![[source:foo.pdf]]` stays **inline media** via the existing
`<iframe src="wiki-blob://source/<id>" class="wiki-embed-pdf">` branch
(`WikiLinkMarkdown.swift:471-473`). PDF is classified as **media** for embed
dispatch (the media predicate includes `MimeType.isPDF`). **No regression.**

The content-type taxonomy:
- **Media (inline, UNCHANGED):** image, video, audio, Mermaid, **PDF-as-`<iframe>`**, external `EmbedTarget` providers.
- **Non-media (`<details>` transclusion):** pages (always), and sources with text/markdown/doc MIME (text/* non-mermaid, markdown, HTML-converted, unknown, documents) — provided they have head markdown or decodable UTF-8 bytes.

If a future operator wants PDF→`<details>`, it's a one-line change to the media
predicate (move `MimeType.isPDF` out of the media set) plus a placeholder test
for the not-yet-extracted case. Out of scope for v2.

---

## 10. Exact files to modify (delta over current)

| File | Change |
|---|---|
| `Sources/WikiFSLinks/WikiLinkMarkdown.swift` | (a) Add pure helper `transclusionEmbedHTML(display:id:kind:target:fragment:) -> String` (§3.1). (b) Insert the transclusion dispatch **before** the media `embedHTML` call at **both** L193 (canonical) and L242 (name): pages → transclusion; non-media sources → transclusion; media sources fall through to `embedHTML` (unchanged). **NOTE / correction:** the existing embed dispatch sites are gated `isEmbedPrefix && kind == .source` — they do NOT fire for `kind == .page`. Add a SEPARATE dispatch branch gated on `isEmbedPrefix && kind == .page` (or restructure into `if isEmbedPrefix { switch kind {…} }`) so bare `![[PageName]]` actually reaches the transclusion helper. Non-media sources route to `transclusionEmbedHTML` WITHIN the existing source guard (before `embedHTML`); media (image/video/audio/mermaid/PDF-iframe) stays inline via `embedHTML`. (c) **Fix the stale header docstring** (currently says "Foundation's `AttributedString(markdown:)`" — it's actually HTML/WKWebView; the comment block at L3-23). |
| `Sources/WikiFS/Reader/WikiReaderView.swift` | (a) New `WKScriptMessageHandler` (`embedFetchName`) alongside `LinkHoverMessageHandler` (~L738), registered in `WikiReaderWebView.init()` (~L355-373). (b) Injected `WKUserScript` for `<details>` toggle + `sdwInjectEmbed` setter (~L364). (c) Coordinator expand method: resolve id → fresh `store.renderContext()` → off-main `readPool.asyncRead { renderEmbedBody }` → main-actor safe-inject (§4.3, §4.4). (d) CSS for `.sdw-transclusion` / `.sdw-embed-placeholder` / `.sdw-embed-empty` / `.sdw-embed-cycle` / **broken-state** rule §7.1 in `documentHTML` (L191-330). |
| `Sources/WikiFSCore/…` (new, small) | The pure `renderEmbedBody(store:id:kind:context:)` (§4.1) + `sourceEmbedBody(store:id:)` (§4.2) helpers. Lives where the read/render plumbing is shared (alongside the existing `ReaderMarkdown`/`MarkdownHTMLRenderer` usage). |
| `Tests/WikiFSTests/TransclusionEmbedTests.swift` *(new)* | Pure parser/renderer tests + the pure fetch+render test + the Coordinator stub test (§12). |

**No change to:** `WikiLinkParser.swift` (the L184 reject gate **stays in place**
— page embeds stay out of the link graph), `MarkdownHTMLRenderer.swift`
(`visitHTMLBlock`/`visitInlineHTML` already pass `rawHTML` verbatim — the
`<details>` is emitted as inline HTML at the span site, same as `embedHTML`),
`EmbedTarget.swift`, `MimeType.swift`, `SourceSummary.swift`,
`SourceMarkdownVersion.swift`, the materializer path, `BlobSchemeHandler`,
the DB schema.

> **Render-only v2:** the feature detects the embed prefix **locally** via
> `WikiLinkSpan.isEmbedPrefix` inside `WikiLinkMarkdown.linkified` — it does
> **not** consume `WikiLinkParser.parse()`. Leave `WikiLinkParser.swift:184`
> (`if isEmbed && kind != .source { continue }`) **in place**. Any
> `page_links` embed-role / graph-edge work is a **clearly-deferred follow-up**.

---

## 11. Baked-in decisions (summary)

1. **PDF = media (inline `<iframe>`), no regression.** Media predicate includes
   `MimeType.isPDF`; PDF never reaches the `<details>` path.
2. **Disambiguation:** bare `![[Foo]]` → page first, fall back to source,
   page wins on collision. `source:`/`page:` prefixes force the namespace.
3. **Unified seam:** one lazy-fetch handler keyed by `kind` — page →
   `getPage(id:).bodyMarkdown`; source → `sourceEmbedBody` (head markdown →
   raw UTF-8 for text → nil/placeholder); both run shared
   `ReaderMarkdown.prepared` + `MarkdownHTMLRenderer.render` + safe
   `evaluateJavaScript`. Media branches off **before** the seam.

---

## 12. Swift Testing plan (`@Test`, `#expect`)

Mirror `Tests/WikiFSTests/WikiLinkMarkdownTests.swift` (injected closures, no
store). Use Swift Testing, not XCTest.

### 12.1 Pure linkify dispatch (`WikiLinkMarkdown.linkified`)
- `pageEmbedEmitsDetailsBlock` — `![[Home]]`, `isResolved={_ in true}` → output
  contains `<details class="sdw-transclusion" data-sdw-embed-kind="page"` and
  `Home` in `<summary>`.
- `pageEmbedIsDistinctFromCiteLink` — `![[Home]]` vs `[[Home]]` → one
  `<details>`, one `<a href="wiki://page…">`.
- `pageEmbedAliasBecomesSummaryHeader` — `![[Cycle|the cycle]]` → `<summary>`
  shows `the cycle`.
- `pageEmbedCanonicalULIDUsesCurrentName` — `![[<ULID>]]` with `displayName`
  returning a fresh title → header is the fresh title.
- `nonMediaSourceEmbedEmitsDetails` — `![[source:notes.txt]]`, `embedInfo`
  `(id, mimeType:"text/plain", target:nil)` →
  `<details … data-sdw-embed-kind="source"`; no `<img>`/`<video>`.
- `mediaSourceEmbedStillInline` — `![[source:pic.png]]` mime `image/png` →
  `<img>` (regression).
- `pdfSourceEmbedFollowsPolicy` — `![[source:doc.pdf]]` → `<iframe>` (DECISION
  §9; PDF=media).
- `mermaidSourceEmbedStillFenced` — `![[source:d.mmd]]` → fenced ```mermaid
  (regression).
- `bareNameFallsBackToSource` — `isResolved(Foo,.page)==false`,
  `embedInfo("Foo")` non-nil → `data-sdw-embed-kind="source"`.
- `pageWinsOnCollision` — both page and source "Foo" →
  `data-sdw-embed-kind="page"`.
- `explicitPagePrefixNeverSource` — `![[page:Foo]]` with a source "Foo" → kind page.
- `explicitSourcePrefixAlwaysSource` — `![[source:Foo]]` with a page "Foo" →
  kind source (media dispatch if media).
- `canonicalULIDSourceTransclusion` — ULID owned by source → kind source.
- `missingPageEmbedRendersBrokenHeader` — unresolved → header contains "not
  found", muted class, **no fetch metadata** (no `data-sdw-embed-target` that
  would trigger a load).
- `missingSourceEmbedBrokenHeader` — `![[source:ghost]]` unresolved → same.
- `pageEmbedInsideCodeSpanIsLiteral` — `` `![[Home]]` `` → literal (protected range).
- `escapedEmbedPrefixIsLiteral` — `\![[Home]]` → literal (escape guard regression).

### 12.2 Pure fetch+render (`renderEmbedBody`) — the TESTABILITY fix
These run against an **in-memory** store (the `#658` in-memory SQLite fixtures)
+ a temp `WikiReadPool`, both supported:
- `renderEmbedBodyResolvesAndRenders` — a page with body markdown → returned
  HTML contains the rendered content.
- `renderEmbedBodyNestedEmbedsCollapse` — the page body contains `![[Inner]]` →
  the rendered HTML contains a nested `<details … data-sdw-embed-kind="page"`
  with **no `open`** (collapsed).
- `renderEmbedBodyMissingReturnsEmpty` — unknown id → returns empty/sentinel
  (caller renders the muted placeholder §7).
- `renderEmbedBodySourcePrefersHeadMarkdown` — source with an extraction row →
  `head.content`.
- `renderEmbedBodySourceFallsBackToRawText` — `text/plain` source, no
  extraction → decoded UTF-8.
- `renderEmbedBodySourceNilForUnextractedBinary` — `application/pdf` (or
  octet-stream), no extraction → `nil`, and assert **no extraction was
  triggered** (hard constraint).

### 12.3 Coordinator handler (Swift-level, stubbed webView)
- `embedFetchHandlerCallsEvaluateJavaScriptWithEscapedPayload` — a stub
  `WKWebView` subclass recording the `evaluateJavaScript` call; assert it is
  called with `sdwInjectEmbed("<nodeId>", "<jsString-escaped html>")` and that
  the HTML is a **parameter** (not concatenated into the source). This proves
  the safe-injection mandate at the Swift level.
- `embedFetchHandlerSetsCycleMarker` — set the embed's `data-sdw-embed-path` to
  already contain the target id → handler emits the `↩ cycle` marker and does
  NOT fetch (maps to AC: cycle marker).

### 12.4 Live WKWebView (NOT drivable in-process — manual validation)
Live `WKWebView` JS execution cannot be driven in a unit test. **Manual
validation procedure (call out in the plan, document in the PR):**
1. Add `DebugLog.store(…, "embed-fetch kind=\(kind) id=\(id)")` at the
   `renderEmbedBody` call site (the fetch seam).
2. Build (`make build`), open the app, load a page with `![[Other]]`, expand it.
3. `log show --predicate 'subsystem == "com.selfdrivingwiki.debug"' --info |
   grep embed-fetch` → confirm the fetch fired on expand (not on load), the
   rendered body appeared, nested `![[…]]` are collapsed, and the cycle marker
   appears on an A↔B embed pair.

---

## 13. Acceptance criteria (with AC→test mapping)

- [ ] `![[PageName]]` renders an inline **collapsed** disclosure whose header is
      the embedded page's (current) title. → `pageEmbedEmitsDetailsBlock`,
      `pageEmbedCanonicalULIDUsesCurrentName`.
- [ ] `![[source:notes.txt]]` (non-media) renders a collapsed `<details>` whose
      body shows the source's markdown/text on expand via the **same** pipeline.
      → `nonMediaSourceEmbedEmitsDetails`, `renderEmbedBodySourcePrefersHeadMarkdown`.
- [ ] Media source embeds (`![[source:pic.png]]` image / `.mp3` audio / `.mp4`
      video / `.mmd` mermaid / `.pdf` **PDF**) still render inline — regression-safe.
      → `mediaSourceEmbedStillInline`, `pdfSourceEmbedFollowsPolicy`,
      `mermaidSourceEmbedStillFenced`.
- [ ] Bare `![[Foo]]` with no page "Foo" but a source "Foo" → source transclusion
      (fallback). Both exist → page wins. → `bareNameFallsBackToSource`,
      `pageWinsOnCollision`.
- [ ] `![[page:Foo]]` never source; `![[source:Foo]]` always source. →
      `explicitPagePrefixNeverSource`, `explicitSourcePrefixAlwaysSource`.
- [ ] `[[PageName]]` (link) unaffected — navigable `wiki://` link.
- [ ] At page load, **no** embedded body is fetched (headers only). →
      `renderEmbedBodyMissingReturnsEmpty` shape + the manual `log show` check.
- [ ] Expanding fetches via `WikiReadPool` (off-main) and renders through the
      shared pipeline; links inside work; nested `![[…]]` are collapsed. →
      `renderEmbedBodyResolvesAndRenders`, `renderEmbedBodyNestedEmbedsCollapse`.
- [ ] Expanding a source embed does NOT trigger extraction (read-only). →
      `renderEmbedBodySourceNilForUnextractedBinary`.
- [ ] A cycle (A↔B) never infinite-loops; expanding down a loop shows the
      `↩ cycle` marker. → `embedFetchHandlerSetsCycleMarker`.
- [ ] Missing target → muted "Page not found: X" header, inert (own red CSS
      rule, not the `<a>` selector). → `missingPageEmbedRendersBrokenHeader`.
- [ ] Not-yet-extracted source → placeholder + open link, no extraction. →
      `renderEmbedBodySourceNilForUnextractedBinary`.
- [ ] Injection is parameter-based (`sdwInjectEmbed(id, html)`), not
      string-concatenated. → `embedFetchHandlerCallsEvaluateJavaScriptWithEscapedPayload`.
- [ ] No `print`; failures route to `DebugLog`; no bare `try?`; macOS 15 / Swift 6.0.
- [ ] `make build` / `make test` pass; new Swift Testing tests green.
- [ ] No commits to `main`; PR on a feature branch.

---

## 14. Review Strategy

1. **Diff walk the linkify dispatch order** in `WikiLinkMarkdown.linkified` at
   both L193 and L242: confirm media (`embedHTML`) is reached for media
   sources, the transclusion branch is reached for pages + non-media sources,
   and the cite-link fallback is unchanged for non-embeds.
2. **Confirm the parser gate is untouched:** `WikiLinkParser.swift:184` still
   reads `if isEmbed && kind != .source { continue }` — page embeds stay out of
   the link graph (render-only v2).
3. **Grep for forbidden patterns:** no `print(`, no bare `try?` in new code; no
   `BEGIN`/transaction in the expand path; no extraction call inside
   `readPool.asyncRead`.
4. **Inspect the JS:** confirm the HTML is a **parameter** to `sdwInjectEmbed`
   (escaped via `jsString`), never concatenated into the `evaluateJavaScript`
   source string.
5. **Inspect the CSS:** confirm `.sdw-transclusion[data-sdw-state="missing"]`
   is a NEW rule reusing `#ff453a`, and that the `a[href^="wiki://missing"]`
   rule is untouched.
6. **Run the suite:** `make build && make test` — all green, including the new
   `TransclusionEmbedTests`.
7. **Manual live validation** (§12.4): `log show` confirms fetch-on-expand and
   the cycle marker on a real A↔B pair.

---

## 15. Gotchas

1. **Render-only — do not touch the link graph.** The feature detects the embed
   prefix locally in `WikiLinkMarkdown.linkified`; it does not consume
   `WikiLinkParser.parse()`. The L184 reject gate stays. Any `page_links`
   embed-role / schema-bump work is a follow-up.
2. **Media classification must run BEFORE the `<details>` branch**, consulting
   BOTH `target` (external media/diagram) AND `mimeType` (byteful media). A
   byteless provider source with no `target` must still NOT reach the
   `<details>` path — it falls through to a cite link as today
   (`WikiLinkMarkdown.swift:461`). Reuse the exact predicate order `embedHTML`
   encodes; the `<details>` branch is the fallback when `embedHTML` returns `nil`.
3. **The bare→source fallback must NOT fire for `source:`-prefixed links** —
   `classify`'s prefix peeling is authoritative; the fallback is only for bare
   names whose page resolution failed.
4. **Safe injection is mandatory, not optional.** String-concatenating rendered
   HTML into `evaluateJavaScript` source is the classic XSS/`</script>`-breakout
   bug. Always pass HTML as a parameter through `jsString` into `sdwInjectEmbed`.
   innerHTML won't run `<script>`, but WILL fire `onerror`/`onload` — equal to a
   normal page view (no new vector).
5. **Fresh context at expand.** Use `store.renderContext()` (memoized,
   event-bus-invalidated), not the load-time snapshot, so nested resolution
   reflects current state.
6. **Name→id resolution happens at EXPAND for name-based page embeds** (main
   actor, `store.pageID(forTitle:)`), NOT at linkify. Do not add a reverse map
   to `WikiRenderContext`.
7. **Off-main read discipline.** `getPage`/`processedMarkdownHead`/
   `sourceContent` run inside `readPool.asyncRead` against a
   `GRDBWikiStore(readOnlyURL:)` member (`query_only=ON`). No transaction, no
   inference/extraction, no `WikiRenderContext` closure touching the store.
   Surface failures via `DebugLog`, not `try?`.
8. **Kit is main-thread.** `evaluateJavaScript` hops back to the main actor —
   mirror the `MainActor.run` hop the top-level render uses
   (`WikiReaderView.swift:912`).
9. **swift-markdown HTML-block rule.** Emit the `<details>` as inline HTML at
   the span site (as `embedHTML` does); ensure the block starts on its own line
   (prefix `\n` if needed — `embedHTML` already emits a leading `\n` for
   mermaid fences, `WikiLinkMarkdown.swift:450`).
10. **Cycle signal is REQUIRED + tested**, not just "recommended." The
    visited-set (ancestor `data-sdw-embed-path`) must be emitted and a
    same-ancestor target must render the `↩` marker — mapped to a test.
11. **Broken-embed CSS is a NEW rule.** The existing `a[href^="wiki://missing"]`
    (`WikiReaderView.swift:243`) is an `<a>` selector; it does not style a
    `<details>`. Add `.sdw-transclusion[data-sdw-state="missing"]
    .sdw-embed-title { color:#ff453a }`.
12. **Footnotes inside an embedded body** get their own footnote section —
    acceptable for v2, possibly surprising; document it.
13. **`source_links` already records source embeds** with an `embed` role
    (`source_links_edge`, `GRDBWikiStore.swift:2270`) for `![[source:…]]`. A
    bare `![[Foo]]` that falls back to a source should ideally record a
    `source_links` edge resolved at save time — confirm `replaceLinks` resolves
    bare embed targets through both namespaces, or document the gap. (Out of
    scope for the render-only deliverable; note for the graph follow-up.)
14. **The `WikiLinkMarkdown.swift` header docstring is stale** (says
    `AttributedString`; it's HTML/WKWebView). Fix it opportunistically as part
    of the linkify change.
