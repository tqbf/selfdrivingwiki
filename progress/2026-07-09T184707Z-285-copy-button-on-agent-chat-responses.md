---
timestamp: 2026-07-09T184707Z
title: "2026-07-09 — #285: Copy button on agent chat responses"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-07-09 — #285: Copy button on agent chat responses

## Progress


Each assistant/response bubble in the chat transcript (Ask/Edit + Query) now has
a hover-revealed **Copy** button that writes the raw markdown text (not the
rendered HTML) to the system pasteboard — no more drag-selecting to copy an
answer.

The transcript is a single `WKWebView` (`ChatWebView`), so the button is an
HTML/CSS `:hover` affordance inside the rendered bubble markup, not a SwiftUI
modifier. Each `.chat-assistant` bubble emits a `<button class="copy-btn"
data-copy="<escaped raw text>">`. A delegated `document`-level click listener
posts the `data-copy` payload to a new `copyText` `WKScriptMessageHandler` on the
`WKUserContentController`; the coordinator writes it via the standard
`NSPasteboard.general` idiom. The button shows brief "Copied" feedback.

Scoped to `.chat` style only (the user-facing transcript). The internals/activity
feed (`feedRowHTML`) is unchanged (non-goal per the issue). 6 new tests in
`ChatWebViewLinkifyTests` cover: assistant + result rows carry `data-copy`,
user/tool rows don't, HTML-special-char escaping, and the empty-result guard.

## Verification

Historical verification remains in the progress record above.
