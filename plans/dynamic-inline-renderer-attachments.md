# Dynamic inline renderer attachments

Status: active design record.

## Purpose

This design adds dynamic renderer views inside a markdown reader. A renderer
owns its view. The reader owns admission, geometry, focus, and teardown.

Static cards remain the readable fallback. They also provide an Open control
for a full renderer presentation.

## Exact admission

The reader creates one `RendererEmbedActivationAdmission` for each document
generation. The admission accepts only an exact page ID, page-version ID,
renderer reference, block ID, input, capability, and generation.

Markdown conversion registers each valid card with that admission. Geometry
cannot mount a view unless the placeholder resolves to an admitted context.
The reader rejects stale generations and missing contexts.

## Renderer-owned view resolution

`RendererInlineAttachmentResolver` resolves an admitted context and its
placeholder ID. It returns one of these results:

- `unsupported` means that the reader keeps the card. The Open control can
  use the full renderer presentation.
- `content` provides the renderer-owned SwiftUI view for the inline host.
- `failed` keeps the renderer closed and shows the static card fallback.

The coordinator does not inspect a renderer reference, a fence kind, or input
bytes. It only asks the injected resolver for a result.

The default resolver composes built-in renderer support. JSON Canvas uses its
native attachment factory. An installed-renderer resolver must use the same
exact admitted input and the validated package session configuration.

A composed resolver checks built-in support first. It then checks installed
renderer support. It stops when a resolver returns content or failure.

## Geometry and active attachment policy

The document reports a card rectangle, visibility, revision, and generation.
The coordinator accepts only finite, newer geometry for the active generation.
It stores the latest geometry for each placeholder.

The first visible admitted card with inline content can auto-mount. The host
allows one active attachment. A later card stays a card when the active slot
is in use. Its Open control can use the full renderer presentation.

The container updates its viewport only when the report belongs to the mounted
placeholder. Geometry from another card cannot move the active view.

The reader uses the established unflipped overlay coordinate conversion. It
does not change that conversion for an attachment type.

## Focus and controls

Auto-mount does not change the first responder. The reader keeps keyboard
focus so page navigation and selection continue to work.

An explicit activation can move focus into the inline view. Escape collapses
the active attachment and restores focus to the reader.

Each mounted attachment has a compact native header. The header provides
Open in Window and Collapse actions. Open in Window uses the admitted renderer
context and the existing full-renderer presentation path.

## Failure and teardown

The resolver validates renderer-owned input before it creates content. A
resolver failure closes the attachment and removes its Collapse control.

An installed renderer reports a terminal session failure to the same placeholder
and generation. The host then closes the session and keeps the static card.

The reader closes all attachments when a document load starts, WebKit reloads,
the card leaves the DOM, or the reader dismantles. A package view must close
its WebKit session when the inline host removes it.

## Non-goals

This design does not run package JavaScript in the markdown document. It does
not change source or page bytes. It does not create provenance, File Provider,
or search-index writes.

This slice uses one active inline attachment. A future multi-attachment design
must replace the single child and viewport with keyed host views.

## Required checks

- Test automatic mount for a visible admitted native renderer.
- Test that automatic mount preserves reader focus.
- Test that inactive geometry cannot move an active attachment.
- Test Escape, DOM removal, reload, stale generation, and session failure.
- Test installed package mount and session teardown with the exact admitted input.
