# Dynamic inline renderer attachments

Status: active design record.

> Updated 2026-08-25: Syntax now owns the embedding role. Markdown images and
> media-capable wiki source embeds stay inline. Approved rich fences use
> disclosure rows. See [`typed-markdown-embed-pipeline.md`](typed-markdown-embed-pipeline.md).
>
> Updated 2026-09-03: Reader embeds moved into the reader document's DOM.
> Package renderers, built-in PDF and HTML, and byte-backed media render as
> iframes and media elements inside the page. The native sibling overlay and
> its geometry projection are removed. See "DOM embeds" below.

## Purpose

The Markdown reader has two presentation paths. Approved rich fences use compact renderer rows. Image syntax remains in the reader DOM without disclosure chrome.

The reader owns admission, focus, resource policy, and teardown for dynamic attachments. Each renderer owns its expanded view.

Image syntax does not auto-mount a dynamic attachment. Ordinary images use DOM `<img>` elements. Mermaid and trusted typed projectors can create inert DOM SVG. Other renderer-backed images keep a DOM image fallback and can show an exact-authorized interactive action.

Readable code, summaries, or images remain as fallback content. A failed or unavailable renderer never produces an empty row.

## DOM embeds

The reader document loads under the `wiki-reader:` custom scheme. WebKit blocks framed custom-scheme loads from an https parent, so the reader parent cannot be an https document. `WikiReaderDocumentSchemeHandler` registers the scheme. Without a registered handler, `loadHTMLString(baseURL:)` falls back to `about:blank`.

Each admitted package iframe gets a 128-bit random origin token. The URL shape is `renderer-package://<token>/<package>/<version>/<path>`. WebKit reports the token as the frame's exact `WKSecurityOrigin.host`. Two frames of one package get different origins. One frame cannot read another frame's document.

`ReaderRendererPackageRouter` maps one token to one package reservation and rewrites requests to the canonical `renderer-package://package/...` form. The canonical `RendererPackageSchemeHandler` adds the CSP, MIME, and no-sniff headers. Unknown, replayed, or revoked tokens fail closed.

Built-in content uses exact-version blob URLs. `wiki-blob://source-version/<SourceVersionID>` serves pinned bytes and the stored MIME. A HEAD edit never changes what an admitted embed shows. The compatibility `wiki-blob://source/<SourceID>` route stays for ordinary embeds.

Package frames get a sandbox with only `allow-scripts`. Raw HTML frames omit `allow-scripts`, so scripts, inline handlers, and `javascript:` URLs do not run. Byte-backed audio and video are `<audio>` and `<video>` elements with metadata preload. Provider-hosted media with no bytes renders a readable fallback with an open action. The reader origin is never stamped into an external URL.

The reader admits one frame-scoped bridge session per frame. Each session owns its broker, input reader, expected origin host, webview identity, and generation. A message with a wrong token, origin, webview, generation, or closed state fails closed.

## Titles and stable identity

A rich fence can use one optional quoted title after its approved alias. A renderer row uses this title or the registered renderer name.

An inline image uses its Markdown alt text for fallback and accessibility content. The reader escapes authored text before it adds the text to HTML or attributes.

A title is presentation metadata. A title edit does not change renderer bytes, the canonical fence digest, the block ID, or the placeholder ID.

## Exact admission

The reader creates one `RendererEmbedActivationAdmission` for each document generation. Markdown conversion registers each eligible renderer row with this admission.

A fenced artifact requires an exact page ID, page-version ID, block ID, renderer reference, bridge input, capability, and generation.

An interactive image also requires an exact source ID and one typed source version. The version can be a `SourceVersionID` or a `SourceMarkdownVersionID`. The reader does not convert between these namespaces.

The image route also checks the normalized MIME type, SHA-256 digest, immutable bytes, renderer reference, bridge byte limit, capability, and generation. A path or URL never grants authorization.

The authorized interactive-image input limit is 48,384 bytes. An oversized, unresolved, external, unclaimed, or unsupported image remains an ordinary Markdown image.

## Renderer-owned view resolution

`RendererInlineAttachmentResolver` resolves an already-admitted context and placeholder. It returns `unsupported`, `content`, or `failed`.

The default composition checks built-in support before installed package support. Native JSON Canvas uses the exact admitted source pin or inline artifact.

An installed renderer receives the exact admitted `RendererBridgeInput` through `RendererAuthorizedInputReader`. The Markdown document does not execute package JavaScript.

An unsupported disclosure request stays collapsed. It does not open a window. **Open in Window** is a separate direct action that uses the same admitted context.

## Budgets and lifecycle

A reader document can keep four renderer rows expanded. A fifth disclosure request stays collapsed and creates no renderer resources. The refusal is retryable.

Inline content uses a separate document budget of six renderers. It does not consume a renderer-row slot. Package frames add a third budget of six concurrent frames, with a 30-second load timeout.

`ReaderDOMRendererLifecycle` is a finite state machine per placeholder: `collapsed`, `loading`, `active`, `retryableResourceRefusal`, `failed`, or `removed`. Legal transitions are an explicit table. A stale callback from an older generation cannot mutate a newer document.

Collapse, DOM removal, navigation, reload, reader dismantle, and process termination close only the matching frame session and release its budget.

Inline Mermaid stays inside the document. It does not consume inline or frame budgets. Authored Mermaid fences continue to use disclosure rows.

## Geometry, zoom, and focus

Embeds are DOM children. Scroll, resize, and reader `pageZoom` move and scale them with the page. There is no geometry report, no viewport projection, and no reprojection pass.

`WKWebView.pageZoom` remains the reader zoom source. Package canvas zoom stays renderer-owned. The reader applies no second scale transform.

Disclosure activation moves focus into the reader document. Escape collapses only the expanded row and restores focus to that row's disclosure button.

## Mermaid boundary

A Mermaid source embed uses inline content. It emits no disclosure control or renderer-row markup.

An authored Mermaid fence uses the shared title and disclosure semantics. Its disclosure action asks the vendored Mermaid library to create the SVG.

The reader keeps Mermaid source as escaped text. A missing library or parse failure preserves readable raw code.

Inline Mermaid does not use the inline or frame budgets unless an approved installed renderer explicitly handles it.

## Failure and teardown

A resolver failure affects only its matching placeholder and generation. Other expanded rows keep their state.

A document load, WebKit reload, or reader dismantle closes all frame sessions. DOM removal, collapse, and renderer failure remove only the matching embed.

Closing a frame session closes its broker and releases its budget slot. Resource pressure remains retryable.

## Non-goals

This design does not change source or page bytes. It does not add a generic image renderer or authorize content from filenames, extensions, paths, or URLs.

This design does not pass reader zoom to a separate renderer window. Renderer-owned canvas zoom also remains independent from reader page zoom.

## Required checks

- Test initial collapsed rows, titles, trailing window actions, and ARIA state.
- Test separate row, inline, and frame budgets.
- Test exact source and fence admission, forged action rejection, role mismatch, and stale generations.
- Test frame-scoped bridge provenance: token, origin, webview, generation, closed state, and two-frame isolation.
- Test scoped collapse, Escape, DOM removal, reload, dismantle, revocation, and process-termination teardown.
- Test exact-version blob bytes and MIME with HEAD-change non-substitution.
- Test the inert HTML sandbox and the byteless-media readable fallback.
- Test DOM scroll and zoom invariance: embed and sentinel rectangles stay aligned without overlay projection.
- Test inline source Mermaid and authored Mermaid rows.
- Test readable fallback for unclaimed, unresolved, external, oversized, and failed content.
