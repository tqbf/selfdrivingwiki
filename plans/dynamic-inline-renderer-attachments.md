# Dynamic inline renderer attachments

Status: active design record.

## Purpose

The Markdown reader shows eligible interactive embeds as compact renderer rows. Each row starts collapsed and has a disclosure control, a title, and a trailing **Open in Window** action.

The reader owns admission, geometry, focus, resource policy, and teardown. Each renderer owns its expanded view.

Readable code, summaries, or images remain in the expansion region as fallback content. A failed or unavailable renderer never produces an empty row.

## Titles and stable identity

A rich fence can use one optional quoted title after its approved alias. An interactive image uses its Markdown alt text as the title.

An untitled embed uses the registered renderer display name. The reader escapes authored titles before it adds them to HTML or accessibility attributes.

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

## Keyed host and row budget

`WikiReaderContainerView` stores native children and visible rectangles by `RendererAttachmentPlaceholderID`. Geometry, focus, collapse, failure, DOM removal, and teardown are also keyed.

A reader document can keep four native or installed renderer rows expanded. The coordinator enforces this budget before resolver, factory, host-child, or session creation.

A fifth disclosure request stays collapsed and creates no renderer resources. Closing, removing, or failing one expanded row frees one document slot.

The process-wide installed-WebKit permit pool is a separate resource. Permit pressure keeps the row collapsed and retryable. It does not create a terminal failure or open a window automatically.

Mermaid expands as HTML and SVG inside the document. It does not create a native child or consume the four-row native budget.

## Geometry, zoom, and focus

The document reports one CSS rectangle, visibility value, revision, and generation for each placeholder. The coordinator accepts only finite, newer geometry for the active generation.

The container updates only the matching child. A geometry report, failure, or removal for one row does not move or close another row.

`WKWebView.pageZoom` remains the reader zoom source. The reader converts each CSS rectangle once with `RendererAttachmentGeometry` and lets the native child fill that scaled frame.

The reader explicitly reprojects all mounted children and requests one geometry report after a zoom change. It does not apply a second whole-view scale transform.

Disclosure activation moves focus into the selected inline renderer. Escape collapses only the focused renderer and restores reader focus.

## Mermaid boundary

A Mermaid row uses the shared title and disclosure semantics. An explicit disclosure action asks the vendored Mermaid 10.9.6 library to create the SVG.

The reader keeps Mermaid source in escaped `textContent`. A missing library or parse failure preserves readable raw code.

Mermaid does not use the inline resolver, an installed renderer session, or the native row budget.

## Failure and teardown

A resolver failure affects only its matching placeholder and generation. Other expanded rows keep their state.

A document load, WebKit reload, or reader dismantle removes all children. DOM removal, collapse, and renderer failure remove only the matching child.

Removing an installed child closes its WebKit session and releases its process permit. Resource pressure remains retryable.

## Non-goals

This design does not change source or page bytes. It does not add a generic image renderer or authorize content from filenames, extensions, paths, or URLs.

This design does not pass reader zoom to a separate renderer window. Renderer-owned canvas zoom also remains independent from reader page zoom.

## Required checks

- Test initial collapsed rows, titles, trailing window actions, and ARIA state.
- Test four independent expanded rows and zero renderer work on a fifth request.
- Test exact source and fence admission, forged action rejection, and stale generations.
- Test keyed geometry, focus, failure, DOM removal, reload, and teardown.
- Test zoom alignment below and above 100 percent without double scaling.
- Test Mermaid expansion, escaping, parse failure, and no-library fallback.
- Test ordinary-image fallback for unclaimed, unresolved, external, and oversized images.
