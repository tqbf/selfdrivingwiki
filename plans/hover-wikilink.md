# Hover tooltip for wiki links

> **Status: implemented (`feature/hover-wikilink`, PR pending).**

## Feature

Wiki links in the WKWebView reader (`WikiReaderView`) now show a human-readable
tooltip on hover. Previously every link showed a raw `wiki://` URL in the
browser's default link-preview area; now:

| Link type | Tooltip shown |
|---|---|
| `[[Page]]` | `[[Page]]` |
| `[[source:Paper]]` | `[[source:Paper]]` |
| `[[Page#Section]]` | `[[Page#Section]]` |
| `[[source:Paper#"quote"]]` | `[[source:Paper#"quote"]]` |
| `[[#Section]]` (same-page anchor) | `#Section` |
| External `https://…` | the URL (browser default) |

## Implementation

Single change in `MarkdownHTMLRenderer.visitLink(_:)`. The renderer already
produces the `<a href="wiki://…">` element; a new `title` attribute is now
added alongside `href`:

- For `wiki://anchor#…` URLs (same-page anchors): `title="#fragment"`.
- For `wiki://page?title=…` and `wiki://source?title=…` URLs: reconstruct the
  original `[[…]]` notation (including `source:` prefix and `#fragment` if
  present) via the existing `WikiLinkMarkdown.target(from:)` /
  `WikiLinkMarkdown.fragment(from:)` helpers.
- For all other URLs (external http/s, missing `wiki://missing`): `title` equals
  the raw `href` value — the same text browsers show by default.

The `title` value is HTML-attribute-escaped via the existing `escapeAttribute`
helper, so quotes and angle brackets in link targets are safe.

## Files changed

| File | Change |
|---|---|
| `Sources/WikiFS/MarkdownHTMLRenderer.swift` | `visitLink` generates `title` attribute |
| `Tests/WikiFSTests/MarkdownHTMLRendererTests.swift` | Updated two existing tests to expect `title` attribute on regular and wiki links |

## Tests

Two existing tests (`regularLink`, `wikiLinkHrefPassesThrough`) updated to
assert the new `title` attribute. No new test cases were needed — the tooltip
logic is covered by the existing link-rendering matrix; `WikiLinkMarkdown`
helpers are already unit-tested independently.
