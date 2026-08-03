---
timestamp: 2026-06-16T162227Z
title: "2026-06-16 — Feature: ingest a resource by URL — DONE ✅ (live-verified, merged to main)"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-06-16 — Feature: ingest a resource by URL — DONE ✅ (live-verified, merged to main)

## Progress


Fetch a URL and land it as an ingested
file in the ACTIVE wiki — exactly like a drag-dropped file, so the existing
"Ingest into wiki" `claude -p` operation can summarize it. HTML is converted to
clean Markdown; PDFs/text/binaries are stored verbatim. All deterministic logic is
pure + unit-tested with a FAKE fetcher (NO real network in tests); the UI is a small
native sheet. **221 → 289 tests; clean signed bundle (app + appex + `wikictl`).**

**Added (`WikiFSCore`, all pure + dependency-free)**
- **`HTMLToMarkdown`** — a hand-rolled, tolerant HTML→Markdown converter. We
  deliberately do NOT use `NSAttributedString(html:)` (WebKit-backed,
  main-thread-only, non-deterministic, untestable). A tokenizer
  (`HTMLTokenizer.swift`) + a streaming renderer (`HTMLMarkdownRenderer.swift`) +
  an entity decoder (`HTMLEntities.swift`). Strips `script`/`style`/`head`/`nav`/
  `footer`; prefers `<article>`/`<main>`/`<body>` content; maps `h1`–`h6`→`#`…,
  `p`→paragraphs, `br`→newline, `a`→`[t](u)`, `strong`/`b`→`**`, `em`/`i`→`*`,
  `code`→`` ` ``, `pre`→fenced block, `ul`/`ol`/`li`→lists (nesting-indented),
  `blockquote`→`>`, `img`→`![alt](src)`; decodes named + numeric (`&#NN;`/`&#xNN;`)
  entities; collapses whitespace; extracts `<title>` (for the filename). Every loop
  is input-length-bounded — never crashes/loops on malformed/unclosed tags
  (degrades to literal text). 45 tests.
- **`URLIngestService`** — the fetch→dispatch→store pipeline with an INJECTED
  `URLResourceFetcher` (so dispatch/filename/store is unit-tested with a fake
  fetcher). `Content-Type` dispatch: `text/html`/`application/xhtml+xml` →
  `HTMLToMarkdown` → store the **markdown** as `.md` (named from `<title>`);
  `application/pdf` → raw bytes as `.pdf`; other `text/*` → raw as-is; else → raw
  bytes with a MIME/URL-inferred extension. Filename rules: HTML uses the sanitized
  `<title>` (else the URL stem, else host), via `FilenameEscaping.escapeTitle` +
  an 80-char cap + an `ensureExtension` guard; derives from the FINAL (post-redirect)
  URL. `normalizeURL` trims whitespace + defaults a missing scheme to `https://` +
  rejects non-http(s). 20 tests.
- **`URLSessionFetcher`** — the production `URLResourceFetcher`: `URLSession`
  (ephemeral config) with a desktop Safari User-Agent (so sites don't 403), redirect
  following (reports the final URL), a bounded timeout, and non-2xx → `httpStatus` /
  transport error → `network` translation. The app is un-sandboxed, so this needs no
  entitlement and fires no macOS prompt.

**Added / changed (app — `WikiFS`)**
- **`WikiStoreModel.ingestURL(_:fetcher:)`** — the model seam: validate + fetch OFF
  the main actor (the GET shouldn't stall the UI), then store on the main actor via
  the SAME `store.ingestFile` path drag-ingest uses (so the file shows up under Files
  + `files/by-{id,name}` and is pickable in Operations → Ingest), `reloadIngestedFiles()`
  + `onPageDidChange?()`. Pure `URLIngestService.plan(for:)` decides filename+bytes
  so no `@Sendable` store closure crosses the actor boundary. 3 tests.
- **`AddFromURLSheet`** — a clean native sheet: a paste-friendly URL field
  (auto-focus, submit-on-Return), a prominent **Fetch** button, an inline progress
  spinner while fetching, and an inline red error row on failure. SWIFTUI-RULES:
  the status row is always-mounted + height-animated (§1.1, no insert/remove
  transition), the URL is read fresh at click time (§3.5), semantic Dynamic-Type
  fonts (§5.1), no formatters in `body`. On success it dismisses and the new file
  appears live.
- **Affordance** — "Add from URL…" lives in TWO native spots in `SidebarView`: the
  sidebar toolbar (next to New Page, always available) and an inline icon button in
  the "Files" section header (next to the content it produces). Also updated the
  Operations → Ingest empty-state hint to mention it.

**Skills (CLAUDE.md, before & after):** `swiftui-pro`, `macos-design`,
`typography-designer`, `airbnb-swift-style` — the sheet matches the app's existing
utility type scale (`.headline`/`.subheadline`/`.body`/`.callout`, same as
`OperationsView`) and animation/state rules; no findings to apply.

**Tests/build.** `make test` → **289/289** green (+45 `HTMLToMarkdownTests`, +20
`URLIngestServiceTests`, +3 `WikiStoreModelURLIngestTests`); `make` produces a clean
signed bundle.

**Live gate (orchestrator `make install` + user):** open a wiki → click "Add from
URL…" (sidebar toolbar) → paste an HTML page URL (e.g.
`https://en.wikipedia.org/wiki/Photosynthesis`) → Fetch → a `.md` file named from the
page title appears under Files; paste a PDF URL (e.g.
`https://www.w3.org/WAI/ER/tests/xhtml/testfiles/resources/pdf/dummy.pdf`) → a `.pdf`
appears (raw bytes). Then Maintain Wiki → Ingest → pick the fetched file → it
summarizes like any dropped file.

## Verification

Historical verification remains in the progress record above.
