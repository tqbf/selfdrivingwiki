# Typed Markdown embed pipeline

Status: active architecture record.

## Purpose

The reader uses one typed render-time document pipeline. It does not rewrite embed syntax into HTML or synthetic Markdown.

Persisted Markdown stays unchanged. Swift Markdown parses standard Markdown. `WikiFSLinks` supplies source-ranged wiki links and embeds from the same source text.

## Pipeline

The pipeline has four stages:

1. `ReaderMarkdown` prepares source frontmatter and footnotes.
2. `PreparedMarkdownDocument` stores the unchanged normalized Markdown, Swift Markdown document, UTF-8 line table, and wiki syntax overlay.
3. `DocumentEmbedResolver` resolves links, media, transclusions, and renderer candidates from immutable facts.
4. `MarkdownHTMLRenderer` lowers typed nodes to HTML, action URLs, and WebKit messages.

The overlay owns its complete source interval. The lowerer suppresses Swift Markdown descendants inside that interval. Invalid UTF-8 ranges or crossing intervals fail closed to escaped authored text.

## Syntax-owned roles

Syntax selects the presentation role:

- Markdown images and media-capable wiki source embeds use `inlineContent`.
- Approved rich fences use `disclosureRow`.
- Page embeds and non-media source embeds use typed lazy transclusion.

A renderer must support the required role. Renderer matching cannot change the role.

Inline content never emits renderer-row disclosure markup. Rich fences keep the existing disclosure-row interaction.

## Resolved embed model

`ResolvedDocumentEmbed` is a closed model. It represents inline media, a renderer plan, transclusion, a missing target, or readable fallback content.

Page and source targets use separate ID types. Source content versions and source Markdown versions also remain separate namespaces.

Ordinary Markdown images use the same typed inline lowerer as wiki source media. Exact sibling targets resolve to typed blob targets. Eligible renderer targets carry pinned immutable source facts.

## Renderer selection and admission

Renderer descriptors declare `supportedEmbeddingRoles`. Registry matching filters by the required role before priority selection.

Manifest revision 2 requires a nonempty role set. Revision 1 keeps its canonical bytes and hash. The runtime grants only the approved legacy disclosure role. Revision 1 never receives inline-content authority.

Renderer activation uses exact document or source identity, version namespace and value, immutable bytes, recomputed digest, MIME type, renderer reference, role, capability, and generation.

The host validates the tuple before resolver, factory, child host, or session creation. URLs, paths, extensions, generated HTML, and DOM attributes do not grant authority.

## Inline renderer lifecycle

Inline dynamic renderers use a separate keyed lifecycle:

- `fallback`
- `eligible`
- `waitingForResources`
- `mounted`
- `failed`
- `removed`

An `IntersectionObserver` reports entry into a retained visibility window. The window is the viewport plus a 600-pixel preload margin.

Inline renderers use a separate per-document budget. This budget does not consume the four expanded disclosure-row slots. The process-wide installed-WebKit permit pool remains separate.

Resource pressure keeps the inline fallback visible. It never promotes inline content to a disclosure row. Permit release, budget release, visibility entry, and document refresh can retry admission.

## Transclusion

Page and non-media source embeds carry tagged transclusion targets. The reader fetches them lazily through read-only access.

Nested content uses the same prepare, resolve, and lower stages. A typed ancestor set detects page and source cycles.

Nested content does not reuse the outer document identity or activation admission. Rich fences remain readable static rows. Inline dynamic renderer requests fall back unless a separate exact admission exists.

## Fallback rules

Every failure keeps readable content:

- images keep an image fallback;
- media keeps a link or native media fallback;
- Mermaid keeps exact escaped source code;
- rich fences keep code;
- transclusion failures keep a typed missing or empty result.

Package failure, unsupported roles, invalid manifests, stale generations, resource pressure, and activation rejection do not produce empty content.

## Compatibility

This design does not change persisted page or source bytes. It does not change wiki syntax, canonical IDs, File Provider output, or public `wiki://` and `wiki-blob://` routes.

`WikiLinkMarkdown.linkified` remains a links-only compatibility bridge for non-render callers. It preserves embed syntax exactly. Production render code cannot call this bridge.
