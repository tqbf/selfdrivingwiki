---
timestamp: 2026-08-19T203000Z
title: Dynamic inline renderer attachment seam
branch: bugfix/json-canvas-inline-preview
status: complete
---

# Dynamic inline renderer attachment seam

## Progress

Added an injected inline attachment resolver at the reader boundary. The
reader coordinator no longer selects JSON Canvas, Excalidraw, or a fence kind.

The default resolver composes native JSON Canvas and installed renderer
resolution. It gives each installed package the exact admitted input. The
reader auto-mounts a visible admitted result without changing first responder
focus. It keeps the explicit full-renderer fallback for unsupported content.

The source reader now uses the same resolver composition as the page reader.
Installed inline renderers no longer stop at the page detail surface.

The attachment coordinator stores the latest geometry for each placeholder.
The container now ignores geometry from an inactive placeholder when another
attachment is mounted.

The reader removed the Excalidraw static preview. Excalidraw now uses the
installed renderer resolver when available.

Each mounted renderer now has a native header. The header provides accessible
Open in Window and Collapse actions. Open in Window uses the admitted renderer
context and the existing full-renderer presentation path.

The attachment focus ring now tracks the real first responder. Auto-mount keeps
reader focus and does not show a keyboard-focus border until the attachment
gets focus.

An inline package session failure captures the admitted generation. The reader
acts on that failure only when its current attachment coordinator owns the same
generation and placeholder. A failure from an older session cannot fail a
remounted attachment.

## Verification

Passed:

- `make build`
- `make test` — 3,471 tests in 335 suites passed.
- `WIKIFS_APP_TESTS=1 swift test --filter WikiFSAppTests.RendererAttachmentCoordinatorTests` — 24 tests passed.
