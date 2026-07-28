---
timestamp: 2026-07-09T212342Z
title: "2026-07-09 — #281: Chat quote anchors (`[[chat:Title#\"quote\"]]`)"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-07-09 — #281: Chat quote anchors (`[[chat:Title#"quote"]]`)

## Progress


`[[chat:Title#"quote"]]` now deep-links to a specific message in a chat
transcript — navigating to the chat, scrolling the matched message into view,
and highlighting the passage — exactly as `[[source:Name#"quote"]]` does for
sources. This closes the explicit non-goal carried over from
`chat-projection.md` (where `chat_messages.text` was "the future FTS substrate,
but quote-anchor matching is not built"). Design of record:
`plans/chat-quote-anchors.md`.

**What shipped (no parser/URL change — that already worked):** The parser
(`WikiLinkParser.splitFragment`) and URL builder (`WikiLinkMarkdown.markdownLink`)
already carried a `#"quote"` fragment through the emitted `wiki://chat?…#"quote"`
URL for chat links generically. The gap was resolution + rendering, not syntax.

- **`ChatQuoteResolver`** (new, pure, `Sources/WikiFSCore/ChatQuoteResolver.swift`)
  — `quoteText(_:)` strips the surrounding `"` the parser keeps verbatim;
  `searchableText(_:)` exposes the prose each `.chat-row` renders; `messageIndex(
  of:in:)` is a whitespace-normalized, case-insensitive **first-match** substring
  scan over the transcript-visible events (mirrors the source quote anchor's
  `wikiNormalized` matching + `ChatWebView`'s `window.find` first-match).
- **Route + navigation** — `WikiLinkRoute.chat` gains `fragment:` (was
  `chat(title:id:)`); `linkRoute(for:)` and both `route(_:)` switch sites +
  `onWikiLinkHandler` thread it through; `selectChat(byID:anchor:)` /
  `selectChat(byTitle:anchor:)` gain an `anchor:` param (default `nil`, so
  sidebar/other callers are unchanged) and set `pendingScrollAnchor` tagged
  `.chat(id)` + bump `pendingScrollAnchorVersion` — the same seam
  `selectPage`/`selectSource` use.
- **Rendering** — `ChatWebView` gains `ChatHighlightRequest{version,quote}` +
  a `quoteAnchor` field; the coordinator stashes the quote and applies it via
  `highlightAndScrollJS(quote:)` — `window.find` + `<mark class="sdwhl">` +
  `scrollIntoView`, the exact mechanism `WikiReaderView.applyFind` uses (the
  transcript is one document, so `window.find` lands on the first match = the
  resolver's message). Applied in `didFinish` (fresh load, after rows render)
  and `updateNSView` (re-click on an already-loaded view); the stash survives a
  request that lands before load (guarded on `isLoaded`). `mark.sdwhl` CSS added
  to the chat shell HTML. Forwarded through `ChatTranscriptView`.
- **`ChatView`** consumes the anchor via a `.task(id:)` keyed on
  `(chatID, anchorVersion, messageCount)` — the messageCount dimension re-fires
  once a persisted chat's messages load, so the set-once anchor is consumed only
  when the transcript is ready (it survives the 0→N load); resolves via
  `ChatQuoteResolver`, then drives `ChatHighlightRequest`.
- **Agent surface** — `prompts/system-prompt-default.md` documents
  `[[chat:Title#"distinctive passage"]]` (regenerated via `make prompts`).

**Tests:** `ChatQuoteResolverTests` (16 — quote stripping, exact/whitespace/
case-tolerant first-match, partial-substring, nil-when-absent, prose-kind
coverage, non-searchable-skip) + `ChatQuoteAnchorModelTests` (5 —
producer/consumer/tagging/mismatch/nil-anchor). `ChatWebView` highlight is
WKWebView (manual verification only). Gate: `swift build` clean; full `swift
test` — **2079 tests in 167 suites** pass; `make check-prompts` green.

## Verification

Historical verification remains in the progress record above.
