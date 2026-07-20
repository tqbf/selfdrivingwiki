# Chat References Don't Navigate — Fix Plan

## Goal

Clicking a "reference" (footnote definition at the bottom of a chat
response) should navigate to the referenced page/source. Currently it does
nothing ("takes me nowhere").

## Root Cause

**Source display names containing a pipe `|` get mis-split by the
`[[…]]` regex, truncating the link target so it never resolves and renders
as an inert `wiki://missing` link.**

### The exact chain

1. The agent emits footnote definitions per the system prompt
   (`prompts/footnote-conclusions-rule.md`):
   ```
   [^retries]: [[source:Flex Tier - Documentation | Neuralwatt Cloud#"Flex is best-effort…"]]
   ```
   The source's real display name is `Flex Tier - Documentation | Neuralwatt Cloud`
   (it contains a pipe).

2. The `[[…]]` regex (`Sources/WikiFSLinks/WikiLinkSpan.swift:20`) treats `|`
   as the alias separator:
   ```
   \[\[((?:[^\]\|"]|"[^"]*")+)(?:\|([^\]]+))?\]\]
   ```
   So the match splits as:
   - **target** = `source:Flex Tier - Documentation ` ← truncated
   - **alias**  = ` Neuralwatt Cloud#"Flex is best-effort…"`

3. `WikiLinkMarkdown.linkified` (`Sources/WikiFSLinks/WikiLinkMarkdown.swift:85`)
   — the render path used by chat (via `ChatWebView.renderedMarkdown` →
   `ReaderMarkdown.prepared` → `MarkdownHTMLRenderer.render`) — resolves the
   truncated target against `isResolved`. The full name
   `Flex Tier - Documentation | Neuralwatt Cloud` IS in the store's
   `sourceNames` set, but the truncated `Flex Tier - Documentation` is NOT.
   → `isResolved` returns `false`.

4. The link renders as `wiki://missing?title=Flex%20Tier%20-%20Documentation`
   (host `missing` = unresolved/inert). The HTML is
   `<a href="wiki://missing?…">…</a>`.

5. `ChatWebView.decidePolicyFor` (`Sources/WikiFS/Chats/ChatWebView.swift:314`)
   fires `onWikiLink?(url, openInNewTab)` →
   `WikiReaderView.onWikiLinkHandler` (`Sources/WikiFS/Reader/WikiReaderView.swift:125`)
   → `linkRoute(for: url)` returns `.inert` (host `missing`) → `break`.
   **Nothing happens.**

### Why it works for pages but not chat

Pages get canonicalized on save: `WikiLinkRewriter.canonicalize`
(`Sources/WikiFSLinks/WikiLinkRewriter.swift:40`) runs the **pipe-in-name
fix** (issue #619, lines 71–126) that reconstructs `bareTarget | alias` and
resolves the whole name, promoting the link to canonical
`[[source:ULID|DisplayName]]` form. Chat messages are stored as raw agent
output and **never canonicalized**, so they keep the broken name-form link
and hit the render path's unresolved branch.

`WikiLinkMarkdown.linkified` (the shared render path) has NO pipe
reconstruction — only `WikiLinkRewriter` (the canonicalize path) does.

## Exact Fix

**Add pipe-in-name reconstruction to `WikiLinkMarkdown.linkified`, in the
non-canonical name-based resolution branch** (mirroring the `WikiLinkRewriter`
logic at lines 71–126).

### File: `Sources/WikiFSLinks/WikiLinkMarkdown.swift`

Insert pipe-reconstruction before the `resolvedSplit` call (around line 224).
When `fixed.alias` is present (i.e. the regex split target|alias), reconstruct
the whole name (`bareTarget | normalizedAlias`, plus any `#`-fragment), run
that through `WikiLinkResolver.resolvedSplit`, and if it resolves emit a
navigable `wiki://source`/`page`/`chat` link with the FULL resolved name as
both the URL target and the display text. Otherwise fall through to the
existing path unchanged.

**Key properties of the fix:**
- Reconstructs `bareTarget | normalizedAlias` (+ `#fragment` if present) and
  runs it through `WikiLinkResolver.resolvedSplit` (which handles `#` splits
  and loose matching). `resolvedSplit` returns `nil` if the reconstructed
  name doesn't resolve → falls through to the unchanged existing path.
- Only triggers when `fixed.alias != nil` (i.e. there WAS a `|` in the span),
  so zero-cost for non-pipe links.
- Resolved pipe-links render with the FULL resolved name as display text
  (mirroring `WikiLinkRewriter`'s `resolvedName` auto-alias) and carry the
  FULL resolved base name in the `wiki://source?title=<full name>` URL.
- The `resolved: true` + correct `target` means `linkRoute` returns
  `.source(title:…, id:nil, fragment:…)` and `selectSource(byDisplayName:)`
  resolves it.

## Files to Modify

| File | Change |
|------|--------|
| `Sources/WikiFSLinks/WikiLinkMarkdown.swift` | Add pipe-reconstruction block (lines ~213–228) |
| `Tests/WikiFSTests/WikiLinkMarkdownTests.swift` | Add tests: pipe-containing source/page/chat names resolve |

## Testing Plan

### Swift Testing (pure — no UI)

Add to `Tests/WikiFSTests/WikiLinkMarkdownTests.swift`:

- A `[[source:Name | Alias]]` where the real source name contains `|`
  resolves and renders a navigable `wiki://source` link (not `wiki://missing`).
- Cover source/page/chat.
- The chat footnote case: pipe-containing name + `#"quote"` anchor — the
  fragment lands in the alias portion after the `|` split; the reconstruction
  carries it through `resolvedSplit`.
- A genuine alias (`[[Alpha|B]]` where Alpha exists and "Alpha | B" does NOT)
  still resolves to Alpha — the reconstruction fails and falls through.
- A genuinely-missing name still falls through to `wiki://missing`.

Run:
```bash
swift test --filter WikiLinkMarkdownTests
```

### Full suite

```bash
swift test   # ~1.5 min; ensures no regressions in reader/canonicalize
```

### Live UI manual validation

1. Build: `make build`
2. Open the Self Driving Wiki app, open the chat that has the failing run
   (Neuralwatt Flex Tier Q&A).
3. Scroll to the footnote definitions at the bottom of the assistant
   response.
4. Click a reference link (e.g. the `Flex Tier - Documentation | Neuralwatt
   Cloud` source link in a footnote).
5. **Expected:** the source detail view opens (and scrolls to the quoted
   passage if the `#"quote"` anchor matched).
6. Also verify: footnote reference superscripts (the `¹`, `²` in the body)
   still scroll to the definition at the bottom (these are fragment-only
   `#wiki-fn-…` links — unchanged by this fix).

## Acceptance Criteria

- [ ] Clicking a footnote-definition source link in a chat navigates to the
      source detail view (when the source exists).
- [ ] Sources with `|` in their display name resolve and navigate.
- [ ] Sources WITHOUT `|` continue to resolve (no regression).
- [ ] Genuine alias links (`[[Foo|bar]]` where Foo exists) are unaffected.
- [ ] Footnote reference superscripts still scroll within the transcript.
- [ ] `swift test` passes (including the new tests).
- [ ] The reader (page/source view) is unaffected — it canonicalizes on save,
      so the render-path fix is additive robustness there.

## Gotchas

1. **Don't canonicalize chat messages.** Chat is raw agent output stored as
   text; canonicalizing it would require a write-back path and risks
   clobbering agent output on re-render. The render-path fix is the right
   layer — it heals at display time without touching bytes.

2. **The fix is in the render path (`linkified`), shared by reader + chat.**
   This is intentional: it makes BOTH more robust (the reader's
   canonicalize fix only runs on save; a freshly-typed-but-unsaved
   `[[source:Name|With Pipe]]` benefits too). It mirrors the exact
   reconstruction strategy already proven in `WikiLinkRewriter`.

3. **`resolvedSplit` does the heavy lifting.** The reconstruction just feeds
   `bareTarget | alias` (+ fragment) into the existing `#`-split + loose-match
   machinery. Don't reimplement fragment splitting.

4. **Display text uses the FULL resolved name** (`reconSplit.base`), matching
   `WikiLinkRewriter`'s `resolvedName` auto-alias. The `|` was part of the
   name, not a real alias separator, so showing just the post-`|` fragment
   would misrepresent the citation.

5. **macOS 15 / Swift 6.0.** The fix is pure String manipulation — no
   concurrency, no actor boundaries, no version-gated APIs.

6. **Scope to `fixed.alias != nil`.** The reconstruction only runs when the
   regex found a `|`. A non-pipe link has no alias, so zero overhead.
