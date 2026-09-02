# JSON Canvas Specification Reference

This package implements a bounded, read-only subset of the JSON Canvas format defined by the open specification.

## Canonical reference

- Specification: <https://jsoncanvas.org/>
- Repository: <https://github.com/obsidianmd/jsoncanvas>
- Format version targeted: JSON Canvas 1.0 (`application/json`, `.canvas`)

The specification is published under the MIT license by the JSON Canvas project (Obsidian). The format and file layout are defined there; this package does not vendor the specification body or its reference renderer. See <https://github.com/obsidianmd/jsoncanvas> for the upstream license text.

## Supported subset

This package supports the following bounded subset of the format:

- Root object with `nodes` and `edges` arrays of objects.
- Node types: `text`, `file`, `link`, and `group`.
- Node geometry: finite `x`, `y`, `width`, `height`; positive dimensions; bounded magnitudes.
- Colors: preset identifiers `1`–`6` and `#RGB` / `#RRGGBB` hex values.
- Edge endpoints that must reference known node IDs; edge `id`, `color`, and `label`.
- Group `background` (bounded CSS color) and `backgroundStyle`.
- Internal references: `[[page:<ULID>]]`, `[[source:<ULID>]]`, and validated relative file references with optional `#subpath`.
- External HTTP(S) links.

Unsupported, malformed, or unsafe values fail closed and preserve the host Source/raw-fence fallback.

## Scope

This is a read-only renderer. It does not edit, persist, or rewrite canvas data.
