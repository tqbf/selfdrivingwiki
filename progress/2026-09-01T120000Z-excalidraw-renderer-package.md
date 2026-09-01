---
timestamp: 2026-09-01T120000Z
title: Move Excalidraw to a local renderer package
branch: feature/excalidraw-renderer-package
status: complete
---

# Move Excalidraw to a local renderer package

## Progress

Excalidraw now remains in `RendererPackages/Excalidraw` as a reviewed local renderer package. The app no longer copies the package into the SwiftPM resource bundle or installs it at startup. Users import the package through Settings → Renderers → Advanced Local Renderer Package Import.

The package manifest now uses version `1.0.5` and declares a bounded generic JSON matcher. The matcher requires a complete root object, the expected scalar values, and an array of objects. The host uses this typed matcher for runtime matching without an Excalidraw format branch.

The matcher decoder keeps a narrow compatibility path for the old `boundedJSONArtifact` wire token. It translates the old Excalidraw value into the generic constraints and preserves the old wire shape when encoding an unchanged legacy value. The original version `1.0.4` package hash remains reserved and valid.

Startup now reads and publishes the current machine index. The generic runtime still owns local installation, removal, provider preparation, safe mode, failure accounting, and Source fallback.

The reader no longer creates host-generated Excalidraw SVG. Source images and Markdown fences use the generic renderer attachment path. Descriptor data supplies package names and labels. Missing or failed packages keep readable fallback content.

## Verification

- `swift run RendererPackageTool validate RendererPackages/Excalidraw`
- Unchanged version `1.0.4` validation produced hash `3068dfdac9b8e8e31f8ac0704c944ef462238c55aa0bbc3bca86d5769e8c9243`.
- Version `1.0.5` validation produced hash `7580e5195a43ee677a795c2a4591c3dcebf528d3dbfadba7001f659e9c328999`.
- `swift test --filter RendererLegacyMatcherCompatibilityTests`
- `WIKIFS_APP_TESTS=1 swift test --filter 'DocumentEmbedResolverTests|MarkdownImageEmbedProjectionTests|RendererRuntimeFactoryTests|InstalledRendererHostTests|RendererSettingsManagementViewTests|PackageFenceReaderPlanTests'`
- `WIKIFS_APP_TESTS=1 swift test --filter RendererAttachmentCoordinatorTests`
- `WIKIFS_APP_TESTS=1 swift test --filter 'MarkdownHTMLRendererTests|DiagramEmbedTests|InstalledRendererHostTests|RendererArtifactMatcherTests|RendererPackageDocumentationTests|ExcalidrawSourceNeutralityTests'`
- `make build`
- `make test` with 4,115 tests passed
- `swift build` and `swift test` with 4,115 tests passed
- `uv run --script tools/validate_skills.py` with all 16 skills valid
- `node --check RendererPackages/Excalidraw/viewer.js`
- JSON parse check for `RendererPackages/Excalidraw/manifest.json`
- `git diff --check`
- Built app inspection found no Excalidraw package payload

The checkout has no `scripts/validate-skills` command. The repository validator runs through `uv` because system Python lacks PyYAML.
