# Mermaid read-only renderer package

This is a reviewed, dependency-free static package for the Mermaid diagram
text format. It contains exactly one downloaded file — the official Mermaid
distribution bundle — and no package manager metadata, and no runtime
network dependency.

The package reads exactly one host-authorized immutable input through the
existing `input.read` bridge. It renders the diagram once into an SVG and
re-renders on system appearance changes. It has no edit, persistence,
clipboard, filesystem, worker, or network capability.

The same engine asset serves two contracts:

- Rendering: `index.html` + `viewer.js` mount the diagram in a package
  session.
- Fence-syntax validation (manifest revision 3): `validate.js` declares the
  `__sdw_validate_fence` entry function. The host's generic
  FenceSyntaxValidator evaluates `mermaid.min.js` and `validate.js` in a
  bare JavaScriptCore context and calls that function with the fence text.
  The engine that renders is the engine that validates, with no version
  skew.

## Upstream provenance

  Name:    Mermaid
  Version: 11.16.0
  Source:  https://cdn.jsdelivr.net/npm/mermaid@11.16.0/dist/mermaid.min.js
  License: MIT (see LICENSE.txt)

The vendored bytes are byte-identical to the file previously shipped as the
app-bundled renderer resource; the git history preserves that identity.

## Review and update procedure

1. Review every changed static asset and this provenance record.
2. Keep all runtime assets local and declare every file in `manifest.json`.
3. Recompute every SHA-256 asset digest in `manifest.json`.
   The validator calculates the immutable package hash when it accepts the
   complete directory.
4. Run the package validation and registry tests before accepting the update.
5. Never add a runtime download, dynamic package loader, worker, or a bridge
   method without a separately reviewed security change.
