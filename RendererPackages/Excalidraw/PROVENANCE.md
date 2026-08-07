# Excalidraw read-only viewer package

This is a reviewed, dependency-free static package for the Excalidraw JSON
format. It contains no downloaded JavaScript, no package manager metadata, and
no runtime network dependency.

The package reads exactly one host-authorized immutable input through the
existing `input.read` bridge. It draws basic Excalidraw v2 elements in SVG and
offers read-only pointer pan and wheel zoom. It has no edit, persistence,
clipboard, filesystem, worker, or network capability.

The package does not include upstream Excalidraw source. The format name is
used for interoperability only. Its source files are licensed under the MIT
license in `LICENSE.md`.

## Review and update procedure

1. Review every changed static asset and this provenance record.
2. Keep all runtime assets local and declare every file in `manifest.json`.
3. Recompute every SHA-256 asset digest in `manifest.json`.
   The validator calculates the immutable package hash when it accepts the
   complete directory.
4. Run the package validation and registry tests before accepting the update.
5. Never add a runtime download, dynamic package loader, worker, or a bridge
   method without a separately reviewed security change.
