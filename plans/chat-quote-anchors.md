# Chat quote anchors — `[[chat:Title#"quote"]]`

**Status:** design of record for issue #281.
**Builds on:** [`chat-projection.md`](chat-projection.md) (`[[chat:…]]` wikilinks +
chat File Provider projection, shipped) and
[`quote-highlight-and-scroll.md`](quote-highlight-and-scroll.md) (the
`[[source:Name#"quote"]]` navigate-then-highlight mechanism, shipped).

The chat-projection plan called chat quote anchors out as an explicit **non-goal**
(the `chat_messages.text` column was "the future FTS substrate, but quote-anchor
matching is not built"). This doc closes that gap.

## Goal

A `[[chat:Title#"quoted passage"]]` link deep-links to a specific message in a
chat transcript — navigating to the chat, scrolling the matched message into
view, and highlighting the exact passage — exactly as
`[[source:Name#"quote"]]` does for sources.

## What already works (no change needed)

The **parser** already handles the syntax generically — the gap is resolution +
rendering, not parsing (issue #281 §Scope):

- `WikiLinkParser.splitFragment` splits at the first `#"` for *any* kind, so
  `[[chat:Title#"quote"]]` already yields `base: "chat:Title"`,
  `fragment: "\"quote\""`. `classify` peels `chat:` after `source:`.
- `WikiLinkMarkdown.linkified` threads the fragment into the emitted URL for
  *every* kind (the `markdownLink` helper appends `#frag` unconditionally), so a
  chat quote link already renders as `wiki://chat?title=…#"quote"` (or with
  `&id=<ULID>`). `WikiLinkMarkdown.fragment(from:)` already accepts the
  `chat` host.

So `[[chat:Title#"quote"]]` parses and renders to a clickable URL carrying the
quote today. The work is: carry the fragment through the click router, resolve
it to a message, and highlight it.

## The gaps

| Layer | File | Gap |
| --- | --- | --- |
| Route | `WikiReaderView.swift` | `WikiLinkRoute.chat` has no `fragment`; `linkRoute(for:)` and both `route(_:)` switch sites drop it; `onWikiLinkHandler` doesn't forward it. |
| Navigation | `WikiStoreModel.swift` | `selectChat(byID:)` / `selectChat(byTitle:)` take no `anchor:`, never set `pendingScrollAnchor` (unlike `selectPage`/`selectSource`). |
| Resolution | (new) | No quote→message matcher. |
| Rendering | `ChatWebView.swift` / `ChatView.swift` | `ChatView` never consumes `pendingScrollAnchor`; the transcript `WKWebView` has no quote-highlight (only the outline's user-turn scroll). |

## Design decisions

### D1 — Single-document highlight reuses the reader's `window.find` + `<mark>`

The chat transcript is **one** scrollable `WKWebView` document (`ChatWebView`
folds the whole feed into one body). So the quote highlight can reuse the exact
mechanism the reader uses (`WikiReaderView.applyFind`): clear prior `mark.sdwhl`,
`window.find(quote)` from the document top, wrap the selection in
`<mark class="sdwhl">`, `scrollIntoView({block:"center"})`. The `mark.sdwhl`
CSS (`rgba(255,213,79,0.8)`) is added to the chat shell HTML.

This avoids fragile per-row index alignment (some events render an empty row).
`window.find` searches the rendered text content and lands on the first match —
which is, by definition, the message the resolver identifies.

### D2 — Pure Swift resolver (testable + gates the highlight)

`ChatQuoteResolver` (WikiFSCore) mirrors the source quote anchor's
whitespace-normalized, case-insensitive **first-match** substring search, but
over a transcript's events instead of a document's blocks:

- `quoteText(_ fragment:)` — strip the surrounding `"` the parser keeps verbatim.
- `searchableText(_ event:)` — the prose each `.chat-row` renders
  (`userText`/`assistantText`/`result`/`toolUse`/`toolResult` summaries; empty for
  non-rendered events).
- `messageIndex(of:in:)` — first event whose `searchableText` contains the
  quote (`wikiNormalized` + lowercased); nil if none.

The resolver's result is **testable** (issue #281 §Tests) and gates the
highlight — no point searching the DOM if no message contains the quote. Its
"first match" semantics match `window.find`'s, so the two stay consistent.

### D3 — Navigation carries the fragment via the existing anchor seam

`selectChat(byID:anchor:)` / `selectChat(byTitle:anchor:)` gain an `anchor:`
param (default `nil`, so sidebar/other callers are unchanged) and set
`pendingScrollAnchor` tagged with `.chat(id)` + bump
`pendingScrollAnchorVersion` — exactly as `selectPage`/`selectSource` do. The
reader's `consumePendingScrollAnchor(for:)` is already `WikiSelection`-generic.

### D4 — Consume after messages load (versioned task key)

`ChatView` resolves against `displayMessages` (the same transcript-visible
events the web view renders). For a persisted chat these load in `.task(id:
chatID)`. To consume the anchor only once messages are present (and re-fire on a
re-click), the consume task is keyed on `(chatID, pendingScrollAnchorVersion,
displayMessages.count)`: it guards on non-empty messages before calling the
set-once/consume-once `consumePendingScrollAnchor`, so the anchor survives the
0→N load.

## Implementation

| File | Change |
| --- | --- |
| `Sources/WikiFSCore/ChatQuoteResolver.swift` (new) | Pure resolver: `quoteText`, `searchableText`, `messageIndex`. |
| `Sources/WikiFSCore/WikiStoreModel.swift` | `anchor:` param on both `selectChat`; set `pendingScrollAnchor` (`.chat(id)`). |
| `Sources/WikiFS/WikiReaderView.swift` | `fragment` on `WikiLinkRoute.chat`; thread through `linkRoute` + both `route(_:)` switch sites + `onWikiLinkHandler`. |
| `Sources/WikiFS/ChatWebView.swift` | `ChatHighlightRequest{version,quote}`; `quoteAnchor` field; `mark.sdwhl` CSS; `window.find` highlight JS; coordinator `pendingHighlightQuote`/`appliedHighlightVersion` applied in `didFinish` + `updateNSView`. |
| `Sources/WikiFS/ChatTranscriptView.swift` | Forward `quoteAnchor`. |
| `Sources/WikiFS/ChatView.swift` | `@State quoteAnchor`; `.task(id:)` consume+resolve; pass to transcript view. |
| `prompts/system-prompt-default.md` | Document `[[chat:Title#"quote"]]` (agent surface); `make prompts`. |

## Tests

| Area | Tests |
| --- | --- |
| Resolver (`ChatQuoteResolverTests`) | quote-stripping; exact match; whitespace/case-tolerant; first-match-on-repeat; nil when absent; tool-summary match; quote that spans a normalized newline. |
| Route | `WikiLinkMarkdownTests`/route — chat URL carries `#"quote"` fragment (already covered if present; add if not). |
| Model | `selectChat(byID:anchor:)` sets `pendingScrollAnchor` tagged `.chat(id)` + bumps version; nil anchor leaves it unset. |

`ChatWebView` (WKWebView) isn't unit-testable here → manual verification only
(mirror the source quote-link manual checks).

## Non-goals

- Chat-to-chat links inside a chat message body (carried over from
  chat-projection.md — the transcript is rendered JSON, not authored markdown).
- Per-message scroll-precision beyond `window.find`'s first match.
- FTS-backed resolution — `messageIndex` is an in-memory substring scan of the
  loaded transcript (the `chat_search`/`chat_chunks` tables from #245 serve
  *search*, not cite-resolution).
