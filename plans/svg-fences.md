# SVG fences

# Goal

Make `svg` fenced blocks render as collapsible renderer rows, the same way
`excalidraw` fences render. The diagram shows after the reader expands the row.

# Design

The host has no SVG-specific fence code. A fence alias renders as a renderer
row when an installed package declares the alias in its manifest. The reviewed
SVG package (manifest revision 2, package version 1.0.1) now declares:

```json
"fenceClaims": [{ "alias": "svg", "inlineMIMEType": "image/svg+xml" }]
```

The reader row reuses the generic disclosure markup: collapsed by default, the
optional quoted title, the expansion budget, Open in Window, and frame
disposal on collapse. The package viewer keeps its inert boundary. The exact
authorized bytes mount as a base64 `data:` image, WebKit image mode stays the
security boundary, and the source bytes are never parsed as markup in the
reader document.

# Changes

- `RendererPackages/SVG/manifest.json`: revision 2, version 1.0.1, one fence
  claim. No asset bytes changed.
- `Tests/WikiFSAppTests/SVGRendererPackageTests.swift`: package identity and
  fence row regressions, with an Excalidraw fence as a parity control.
- `Tests/WikiFSAppTests/SVGRendererPackageHostedValidationTests.swift`:
  hosted row lifecycle, opt in with `WIKIFS_APP_TESTS=1`.
- `Tests/WikiFSTests/RendererPackageDocumentationTests.swift`:
  `svgFenceDocumentationMatchesManifest`.
- `docs/user-guide/renderer-packages.md` and the maintainer guide reference:
  version 1.0.1 and SVG fence syntax.

# Installation

Version 1.0.0 does not gain fence support. Import the updated
`RendererPackages/SVG` folder through Settings → Renderers → Advanced Local
Renderer Package Import.

# Verification

- `swift run RendererPackageTool validate RendererPackages/SVG`
- `swift test --filter SVGRendererPackageTests`
- `swift test --filter RendererPackageDocumentationTests`
- `WIKIFS_APP_TESTS=1 swift test --filter SVGRendererPackageHostedValidationTests`
- `make build` and `make test`

Record actual results in `progress/`.
