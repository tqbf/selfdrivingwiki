# Dynamic inline renderer attachments

Status: active design record.

> Updated 2026-08-25: Syntax now owns the embedding role. Markdown images and
> media-capable wiki source embeds stay inline. Approved rich fences use
> disclosure rows. See [`typed-markdown-embed-pipeline.md`](typed-markdown-embed-pipeline.md).

## Purpose

The Markdown reader has two presentation paths. Approved rich fences use compact renderer rows. Image syntax remains in the reader DOM without disclosure chrome.

The reader owns admission, geometry, focus, resource policy, and teardown for dynamic attachments. Each renderer owns its expanded view.

Image syntax does not auto-mount a dynamic attachment. Ordinary images use DOM `<img>` elements. Mermaid and trusted typed projectors can create inert DOM SVG. Other renderer-backed images keep a DOM image fallback and can show an exact-authorized interactive action.

Readable code, summaries, or images remain as fallback content. A failed or unavailable renderer never produces an empty row.

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

## Keyed hosts and separate budgets

Image syntax does not use a keyed host or an inline attachment budget. Its DOM content follows normal document layout and scrolling.

`WikiReaderContainerView` stores other native children and visible rectangles by `RendererAttachmentPlaceholderID`. Geometry, focus, failure, DOM removal, and teardown are keyed.

A reader document can keep four native or installed renderer rows expanded. A fifth disclosure request stays collapsed and creates no renderer resources.

Inline content uses a separate document budget. It does not consume a renderer-row slot. The coordinator checks this budget immediately before resolver, factory, host-child, or session creation.

Each inline placeholder uses one state: `fallback`, `eligible`, `waitingForResources`, `mounted`, `failed`, or `removed`.

An `IntersectionObserver` uses the viewport plus a 600-pixel preload margin. It mounts eligible inline content inside this retained visibility window.

The coordinator releases an inline child after it stays outside the retained window or leaves the DOM. Ordinary geometry and zoom updates keep the existing child.

The process-wide installed-WebKit permit pool is a third resource. Permit pressure keeps fallback content visible and retryable.

Inline Mermaid stays inside the document. It does not consume native or installed renderer budgets. Authored Mermaid fences continue to use disclosure rows.

## Geometry, zoom, and focus

The document reports one CSS rectangle, visibility value, revision, and generation for each placeholder. The coordinator accepts only finite, newer geometry for the active generation.

The container updates only the matching child. A geometry report, failure, or removal for one row does not move or close another row.

`WKWebView.pageZoom` remains the reader zoom source. The reader converts each CSS rectangle once with `RendererAttachmentGeometry` and lets the native child fill that scaled frame.

The reader explicitly reprojects all mounted children and requests one geometry report after a zoom change. It does not apply a second whole-view scale transform.

Disclosure activation moves focus into the selected inline renderer. Escape collapses only the focused renderer and restores reader focus.

## Mermaid boundary

A Mermaid source embed uses inline content. It emits no disclosure control or renderer-row markup.

An authored Mermaid fence uses the shared title and disclosure semantics. Its disclosure action asks the vendored Mermaid library to create the SVG.

The reader keeps Mermaid source as escaped text. A missing library or parse failure preserves readable raw code.

Inline Mermaid does not use the inline attachment budget unless an approved installed renderer explicitly handles it.

## Failure and teardown

A resolver failure affects only its matching placeholder and generation. Other expanded rows keep their state.

A document load, WebKit reload, or reader dismantle removes all children. DOM removal, collapse, and renderer failure remove only the matching child.

Removing an installed child closes its WebKit session and releases its process permit. Resource pressure remains retryable.

## Non-goals

This design does not change source or page bytes. It does not add a generic image renderer or authorize content from filenames, extensions, paths, or URLs.

This design does not pass reader zoom to a separate renderer window. Renderer-owned canvas zoom also remains independent from reader page zoom.

## Required checks

- Test initial collapsed rows, titles, trailing window actions, and ARIA state.
- Test inline placeholders without disclosure markup.
- Test separate inline, disclosure-row, and process-wide budgets.
- Test visibility mount, retained-window release, retry, and DOM removal.
- Test exact source and fence admission, forged action rejection, role mismatch, and stale generations.
- Test keyed geometry, focus, failure, reload, and teardown.
- Test zoom alignment below and above 100 percent without double scaling.
- Test inline source Mermaid and authored Mermaid rows.
- Test readable fallback for unclaimed, unresolved, external, oversized, and failed content.
