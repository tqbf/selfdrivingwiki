---
timestamp: 2026-07-20T152209Z
title: "2026-07-20 — Generalized `![[X]]` embed: pages + non-media sources (branch `page-embeds`)"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-07-20 — Generalized `![[X]]` embed: pages + non-media sources (branch `page-embeds`)

## Progress


**Problem.** `![[source:…]]` embeds worked for inline media (image / video /
audio / PDF iframe / Mermaid) but `![[PageName]]` did nothing — the `!` was
silently consumed and a page embed rendered as a plain cite link. Non-media
sources (text, markdown) likewise had no embed path; they fell back to a cite
link. Plan v2 (`plans/page-embed-v2.md`) generalizes `![[X]]` to embed **pages
and non-media sources** in a collapsed `<details>` disclosure, lazily fetched +
rendered on expand through the same `ReaderMarkdown.prepared` +
`MarkdownHTMLRenderer.render` + `evaluateJavaScript` seam the reader already
uses.

**Approach (render-only; the `WikiLinkParser.parse` L184 reject gate stays in
place — page embeds stay out of the link graph; that's a deferred follow-up).**

1. **Linkify layer (pure, in `WikiLinkMarkdown.linkified`).** A new
   `transclusionEmbedHTML(display:kind:id:target:fragment:name:)` helper emits
   the collapsed `<details>`, and a new `brokenEmbedHTML(display:kind:)` emits
   the muted missing-target disclosure. The embed dispatch was restructured at
   BOTH call sites (canonical ULID and name-based) to:
   - `kind == .page` → page transclusion when resolved, else broken-page header
     (bare names fall back to the source namespace when a source exists).
   - `kind == .source` → media inline via `embedHTML` (unchanged), else
     non-media transclusion; synthetic-provider-mime w/o target stays a cite
     link (§15.2 gotcha — never become a transclusion).
   - `kind == .chat` → not an embed (cite link; consistent with the parser).
   - Canonical ULID embeds probe both `displayName(id, .page)` and
     `displayName(id, .source)`; page wins on collision; explicit `page:` /
     `source:` prefixes force the namespace.

2. **Pure fetch+render helpers (`Sources/WikiFS/Reader/TransclusionEmbedder.swift`,
   new).** `renderEmbedBody(store:id:kind:context:)` is the single reuse point
   guaranteeing nested `![[…]]` collapse and `[[…]]` link: it fetches
   (`getPage` / `processedMarkdownHead` / raw UTF-8 for native text) and runs
   the shared pipeline. Pure given a `:memory:` in-memory store — unit-tested
   against the #658 fixtures. Includes pure helpers for the JS-string seam:
   `injectJSCall` (HTML as a **parameter**, escaped via `WikiReaderRep.jsString`),
   `cycleMarkerHTML` / `cycleMarkerJSCall`, `placeholderBodyHTML`, `isCycle`.

3. **Expand layer (`WikiReaderView.swift`).** New `WKScriptMessageHandler`
   (`embedFetchName`) + `WKUserScript` (`embedBootstrapJS`) define
   `window.sdwInjectEmbed(embedId, html)` (param-based injection — never
   string-concatenated) and bind one-shot `toggle` listeners. The Coordinator's
   `handleEmbedFetch(body:)` (sync, fire-and-forget) /
   `processEmbedFetch(body:)` (async, awaitable for tests): cycle check (no
   fetch) → resolve id → fresh `store.renderContext()` → off-main
   `readPool.asyncRead { TransclusionEmbedder.renderEmbedBody }` → safe-inject.

4. **CSS** for `.sdw-transclusion` disclosure (collapsed-by-default, `▸` arrow
   rotating 90° on open) + a NEW broken-state rule reusing `#ff453a`
   (`.sdw-transclusion[data-sdw-state="missing"] .sdw-embed-title`). The
   existing `a[href^="wiki://missing"]` selector is untouched.

5. **`WikiStoreModel.internalStore`** — public accessor for the underlying
   `WikiStore` so the Coordinator's no-`readPool` fallback (in-memory tests)
   can cast to `GRDBWikiStore` and call `TransclusionEmbedder.renderEmbedBody`
   directly. Production always goes through `readPool` (`WikiSession.init`
   sets it for file-backed wikis).

**Cycle safety (Plan v2 §8).** Primary bound = lazy-collapse (a body is fetched
only when its specific `<details>` is opened; cycles can't infinite-loop because
each level only deepens on explicit user action). Defense-in-depth: ancestor
chain via `data-sdw-embed-path` (empty at linkify; populated by
`sdwInjectEmbed` for each nested `<details>` = parent path + parent id). On
expand, `TransclusionEmbedder.isCycle(path:id:)` checks membership; a hit
renders `↩ PageName (cycle)` and skips the fetch entirely.

**Tests.** `Tests/WikiFSTests/TransclusionEmbedTests.swift` (30 tests):
17 linkify dispatch tests (page / source / pdf / mermaid / bare→source fallback
/ page-wins-on-collision / explicit-prefix / broken-header / code-span
protection / escaped bang), 6 pure fetch+render tests against in-memory fixtures
(`:memory:` #658), 4 cycle + safe-injection helper tests, 3 Coordinator handler
tests using a `deliverJS` recorder (cycle marker, safe-injection payload with
the classic `");evil();//` breakout proving jsString neutralizes it, missing
target placeholder). Updated 4 existing tests in `WikiLinkMarkdownTests.swift`
+ `DiagramEmbedTests.swift` whose pre-v2 assertions (cite-link fallback for
unresolved / non-media / synthetic-provider-mime-without-target / `![[Page]]`)
reflected the now-replaced behavior. Manual live validation procedure
documented in `plans/page-embed-v2.md` §12.4 — live WKWebView JS is not
drivable in-process; `log show --predicate 'subsystem ==
"com.selfdrivingwiki.debug"' --info | grep embed-fetch` confirms fetch-on-expand
and the cycle marker.

**Files touched.** `Sources/WikiFSLinks/WikiLinkMarkdown.swift`,
`Sources/WikiFS/Reader/TransclusionEmbedder.swift` (new),
`Sources/WikiFS/Reader/WikiReaderView.swift`,
`Sources/WikiFSCore/Store/WikiStoreModel.swift`,
`Tests/WikiFSTests/TransclusionEmbedTests.swift` (new),
`Tests/WikiFSTests/WikiLinkMarkdownTests.swift`,
`Tests/WikiFSTests/DiagramEmbedTests.swift`,
`plans/page-embed-v2.md` (the plan).

---

## Verification

Historical verification remains in the progress record above.
