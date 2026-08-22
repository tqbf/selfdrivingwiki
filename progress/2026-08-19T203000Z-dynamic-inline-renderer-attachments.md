---
timestamp: 2026-08-19T203000Z
title: Dynamic inline renderer attachment seam
branch: bugfix/json-canvas-inline-preview
status: updated-2026-08-22
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

## 2026-08-22 renderer row update

Interactive Markdown embeds now use renderer rows. Each row starts collapsed and shows a disclosure control, a title, and a trailing **Open in Window** action.

The reader uses keyed native children and keyed geometry. Four native or installed renderer rows can stay expanded in one document. A fifth disclosure request stays collapsed and creates no renderer resources.

Reader page zoom reprojects each mounted child from its stored CSS geometry. The native child fills the scaled frame without a second view transform.

Rich fences accept one optional quoted title. The parser rejects malformed title syntax. A title edit does not change the canonical block digest or placeholder identity.

Mermaid uses the renderer row interaction but renders its SVG inside the Markdown document. It keeps the vendored Mermaid 10.9.6 boundary and preserves readable raw code when the library or parser fails.

An approved renderer can claim an exact sibling image source. The Markdown alt text becomes the renderer row title. Unclaimed, unresolved, external, data, and oversized images remain ordinary Markdown images.

Interactive image admission checks the exact source ID, typed source version, MIME type, SHA-256 digest, immutable bytes, renderer reference, capability, document generation, and 48,384-byte bridge limit. Paths and URLs do not grant authorization.

Native JSON Canvas uses the exact admitted source bytes and typed pin. Installed renderers reread the pinned store payload and compare its MIME, bytes, and digest with the admitted source before session creation.

Unsupported disclosure requests stay collapsed. They do not open a separate renderer window. **Open in Window** remains a separate direct action.

### Completed validation

- Mermaid and Markdown focused suites passed with 53 tests.
- The focused image resolver run passed 73 tests in three suites.
- Image projection, route, native resolver, authorized-reader, and coordinator focused suites passed.
- The renderer package documentation suite passed 5 tests.
- Production SwiftLint passed with no violations for the changed renderer files.
- `git diff --check` passed.
- An independent security review found one high-severity installed-input validation gap. The implementation now validates the reread store payload against the admitted MIME, bytes, and digest.
- The security re-review confirmed the production fix. Its one medium test-fixture finding was fixed, and all 7 authorized-reader tests passed.

### Final validation

- `make test` passed with 3,527 tests in 342 suites.
- `make build` passed and produced a signed app with the File Provider enabled.
- `make prompts && make version && swift build` passed.
- `make prompts && make version && swift test` passed with 3,527 tests in 342 suites.
- The final accessibility, macOS interaction, typography, SwiftUI, security, and general implementation review found no unresolved critical, high, or medium issues.
- The native header uses the authored renderer row title, regular system weight, trailing controls, title truncation, and typed accessibility labels.
- The HTML renderer row uses relative type sizes, a flat in-flow treatment, visible focus rings, and reduced-motion handling.

### Manual validation limit

The automated hosted suites validate AppKit hit testing, keyboard focus, Escape, keyed geometry, zoom reprojection, and renderer teardown. The signed app build passed.

This environment did not perform a human visual check of light and dark appearance or pointer gestures in the signed app. The pull request must keep that limitation visible for operator approval.
