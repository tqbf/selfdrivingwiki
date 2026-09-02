---
timestamp: 2026-09-01T220000Z
title: JSON Canvas renderer package migration
branch: feature/json-canvas-renderer-package
status: in-progress
---

# JSON Canvas renderer package migration

design: plans/json-canvas-renderer-package.md

## Progress

- Removed the native JSON Canvas built-in renderer and all JSON Canvas-specific production Swift:
  - `BuiltInRendererID.jsonCanvas`, the built-in descriptor/fence/priority, the factory map entry and `BuiltInRendererFactoryInputs.jsonCanvasHostAction`, the native decoder/view/viewport (`JSONCanvasDocument`, `JSONCanvasRendererView`, `JSONCanvasViewportState`), the native attachment factory, the reader fence presentation branch, the inline-capable reference special case, and the source outline/diagram-tab branches.
- Added the reviewed, immutable JSON Canvas Web renderer package at `RendererPackages/JSONCanvas`:
  - Package ID `org.selfdrivingwiki.json-canvas-readonly`, version `1.0.0`, registration `json-canvas`.
  - Manifest revision 4. Bounded `application/json` + `.canvas` matcher requiring root-object `nodes`/`edges` object arrays; `jsoncanvas` fence claim; `inlineContent` + `disclosureRow` roles; 48,000-byte input/decoded limits; protocol revision 1; priority 110.
  - Read-only accessible SVG renderer (text/file/link/group nodes, edge labels/arrowheads, deterministic z-order, pan/zoom/fit, keyboard, light/dark, Reduce Motion) with bounded parsing and typed navigation.
  - Validated package hash: `46d005a5441fbefd6136933c5cb314cd5149ee09ae72370167e669a9be560eb1` (final assets).
- Added renderer manifest revision 4 with capability-gated `hostNavigation` authority and a closed `hostNavigation.allowedTargetKinds` declaration (page/source/namedContent). Host protocol revision stays 1. Revisions 1–3 fail closed if they carry navigation. Reviewed Excalidraw (rev 2) and Mermaid (rev 3) package hashes remain unchanged:
  - Excalidraw 1.0.5: `7580e5195a43ee677a795c2a4591c3dcebf528d3dbfadba7001f659e9c328999`
  - Mermaid 1.0.0: `714bb2a23a33bbe45ab9507137c2784d844fee32220ae6248ea78a60e2acda6f`
- Added the generic package-to-host navigation bridge:
  - Typed `.page(PageID)` / `.source(SourceID)` / `.namedContent(rawRelativeReference)` targets with canonical-ULID and relative-path validation.
  - Discriminated page envelope; `host.navigate` never reads source bytes. Shared request-ID replay ledger with `input.read`.
  - Purpose-separated host-observed single-use activation (navigation nonce namespace distinct from external links). Uniform, non-oracular acknowledgement. Denied requests never invoke the router.
  - Neutral `RendererHostNavigationRouting` threaded through source panes, reader inline attachments, and renderer windows.
- Added tests: manifest/canonicalization/capability; bridge contracts; broker (real WebKit opt-in); reviewed package (validate/matching/fence/roles/capabilities/limits/static security/tamper); parser (node subprocess runs the exact `__sdw_parse_canvas` entry: at-cap, one-byte-over, malformed, bounds, groups, unsafe links); source neutrality (no production Swift policy + no SwiftPM/build bundling); updated built-in registry, Markdown embed, fence, and attachment coordinator tests; removed native JSON Canvas tests.

## Verification

- `swift run RendererPackageTool validate RendererPackages/JSONCanvas` — passes.
- Focused normal-suite filters passed: manifest revision 4, bridge contracts, parser, neutrality, reviewed package.
- `WIKIFS_APP_TESTS=1 swift test --filter RendererAttachmentCoordinatorTests` passed: 37 tests.
- `WIKIFS_APP_TESTS=1 swift test --filter RendererContentWorldBridgeTests` passed: 7 tests.
- `WIKIFS_APP_TESTS=1 swift test --filter RendererAttachmentSpikeHostedTests` passed: 4 tests.
- `WIKIFS_APP_TESTS=1 swift test --filter Phase6RendererHostedValidationTests` passed: 2 tests.
- `WIKIFS_APP_TESTS=1 swift test --filter JSONCanvasRendererPackageTests` passed: 6 tests.
- `WIKIFS_APP_TESTS=1 swift test --filter JSONCanvasRendererPackageHostedValidationTests` passed: 2 real-WebKit tests.
- `scripts/test-with-watchdog.sh` passed the full suite with no unfinished tests.
- Bare `swift build` and `swift test` passed. The test run completed 4,146 tests in 448 suites.
- `make build` passed. Two `make test` runs each found one unrelated extractor-package concurrency failure. Each failed test then passed three focused reruns, and the watchdog full suite passed.
- Built-app inspection found no bundled JSON Canvas package assets.
- `scripts/validate-skills` is not present in this checkout, so that planned check could not run.
- Remaining before delivery: complete implementation review, resolve its findings, and record the pull request.

## Notes / honest limits

- The JSON Canvas package cap is 48,000 bytes (the current shared bridge ceiling), lower than the former native 256 KiB. Canvases above the cap keep the readable Source/raw-fence fallback. This is an accepted user-visible migration limit; global bridge limits were not widened.
- The pure parser runs under the normal suite via a bounded non-blocking `node` subprocess; real WebKit rendering/accessibility/appearance/interaction remains hosted and opt-in (`WIKIFS_APP_TESTS=1`).
- `plans/dynamic-renderers-phase6-json-canvas-test-inventory.json` and its progress record describe the superseded native design; they are historical evidence, not current.
