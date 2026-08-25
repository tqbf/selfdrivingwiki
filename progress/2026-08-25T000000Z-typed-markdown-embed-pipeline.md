---
timestamp: 2026-08-25T000000Z
title: Typed Markdown embed pipeline
branch: feature/typed-markdown-embeds
status: complete
---

# Typed Markdown embed pipeline

## Progress

## Completed implementation

The reader now uses one typed prepare, resolve, role-match, and lower pipeline.

`PreparedMarkdownDocument` keeps normalized authored Markdown, the Swift Markdown document, a UTF-8 line table, and source-ranged wiki syntax. The overlay keeps code spans and fences protected.

`DocumentEmbedResolver` uses tagged page, source, chat, version, media, renderer, and transclusion facts. Ordinary Markdown images and wiki source media use one inline lowerer.

Syntax owns the renderer role. Images and media use `inlineContent`. Approved rich fences use `disclosureRow`. Renderer matching cannot change this role.

Mermaid source embeds now render inline without renderer-row markup. Authored Mermaid fences keep the disclosure-row interaction.

Page and non-media source embeds use typed lazy transclusion. Nested content uses the same pipeline and does not reuse outer activation authority.

The reader removed production calls to `WikiLinkMarkdown.linkified`. The compatibility bridge now preserves embed syntax and rewrites cite links only.

The reader also removed the image callback and image-only projection. One typed document projection now handles exact sibling blob targets and eligible inline renderer targets.

## Renderer packages and admission

Renderer descriptors and manifest revision 2 declare `supportedEmbeddingRoles`. Revision 1 canonical bytes and hashes remain unchanged.

The revision 1 compatibility adapter grants only approved legacy disclosure-row authority. It never grants inline-content authority.

Inline and disclosure activation uses exact identity, typed version, immutable bytes, recomputed digest, MIME type, renderer reference, role, capability, and generation.

## Inline lifecycle

Inline dynamic renderers use a separate six-state lifecycle and document budget. An `IntersectionObserver` uses a 600-pixel preload margin.

Resource pressure keeps fallback content visible and retryable. Inline content never promotes to a disclosure row.

A hosted WebKit test mounts and removes a real inline JSON Canvas renderer through intersection, geometry, and mutation messages.

## Verification

Passed:

- 272 tests across 19 typed pipeline, renderer, transclusion, chat, and hosted lifecycle suites.
- 91 wiki-link, diagram-resolution, and preparation tests after removal of string generators.
- 85 typed transclusion, resolver, preparation, and renderer tests.
- 75 role-aware manifest, registry, and machine-index tests.
- 34 renderer attachment coordinator and hosted lifecycle tests.

The broad gate found and fixed these defects:

- A parent Markdown container emitted a nested list overlay twice.
- A canonical page embed used its raw ID instead of the current display name.
- Nested transclusion paths lost page and source namespace tags.
- Ambiguous source names could select one source by insertion order.
- A provisional navigation closed the new attachment coordinator.
- A stale transclusion task could emit into a replacement document.

Final validation passed:

- `make build` built and signed the macOS application.
- `make test` passed 3,669 tests in 376 suites.
- Bare `swift build` passed.
- Bare `swift test` passed 3,669 tests in 376 suites.
- Revision 1 package canonical JSON and package hashes use fixed golden values.
- Revision 1 installed-package restart and revalidation passed with a fixed persisted hash.
- Documentation and source-version signature contracts passed.

The repeat plan review closed all high and medium findings. The independent security review found no confirmed issues.

The optional mutation-tool probe timed out after 30 seconds before it returned a version. Mutation testing did not block delivery.

## Delivery

Commit and push the feature branch. Open an unmerged pull request. The operator owns the merge decision.
