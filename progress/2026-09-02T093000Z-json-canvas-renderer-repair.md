---
timestamp: 2026-09-02T093000Z
title: JSON Canvas renderer repair
branch: feature/json-canvas-renderer-package
status: complete
---

# JSON Canvas 1.1.1 — repaired scene model + revision-5 asset-read authority (1.1.1 fixes the subpath validator)

Date: 2026-09-02. Branch `feature/json-canvas-renderer-package` (PR #1195).

## Progress

### What shipped

Version 1.1.0 of the reviewed JSON Canvas renderer package replaced the lossy 1.0.1 Swift-to-SVG port's center-to-center, single-line, no-fit rendering with a staged, spec-complete scene model:

- **Full JSON Canvas 1.0 parsing** with defaults (`fromEnd = none`, `toEnd = arrow`), closed-field validation (`type`, sides, ends, `backgroundStyle`), optional top-level arrays, bounded key/nesting/value limits, and bounded-unknown-property tolerance (forward-compatible extensions do not suppress rendering).
- **Side-aware Bézier edge geometry**: rectangle-boundary anchors, deterministic automatic side selection, cubic control points adapted from JSON-Canvas-Viewer (MIT), `marker-start`/`marker-end` only when requested, stroke/marker offset so paths never enter node interiors, and edge labels on a readable background.
- **Bounded Markdown text** (paragraphs, newlines, emphasis, strong, inline code, links) as semantic HTML inside a node-bounded `foreignObject`, width-aware wrapping, height clipping, overflow cue, and SVG `<title>`/`<desc>` + offscreen fallback for VoiceOver/keyboard.
- **Image file nodes + group backgrounds** through the new revision-5 `asset.read` authority: only host-admitted references are read, from exact pinned `SourceVersionID`s, bounded by per-asset/per-request/session budgets, with uniform redacted denials. Unavailable images keep readable fallbacks (filename label / tinted group fill) and never fail the canvas. Group backgrounds honor `cover`/`ratio`/`repeat`; image nodes preserve aspect ratio. `image/svg+xml` is deliberately NOT in the approved MIME list until a hostile-SVG image-surface isolation gate proves untrusted SVG cannot escape the image surface.
- **Fit/pan/zoom**: initial fit-to-window (clamped scale), pointer-anchored wheel zoom, pointer pan, keyboard pan/zoom/reset, focus indicators, light/dark, Reduce Motion.
- **Accessible DOM**: `createElement`/`textContent` only (no `innerHTML`); typed `hostNavigation` for `[[page:…]]`/`[[source:…]]` and relative file references; trusted activation for HTTP(S) links.

## Host infrastructure (renderer-neutral)

- **Manifest revision 5**: closed `assetRead` capability + declaration (roles `imageNode`/`groupBackground`; MIME `image/png|jpeg|gif|webp`; extractor + session limits; one reviewed `extractor.js` with entry `__sdw_extract_canvas_assets` returning only `file` and group `background` values). Pre-revision-5 manifests carrying `assetRead` fail closed. Host protocol revision stays 1; the 1.0.1 (revision 4) package hash `8b4ba221c48a3232d4e5355c64170b3da942f003fd7072747712922def9d576d` is locked by test and preserved byte-for-byte.
- **Reference-extractor helper**: single-invocation SwiftPM executable (`renderer-asset-reference-extractor-helper`) embedding JavaScriptCore with no host objects; framed stdin/stdout protocol v1; launched via the race-free process-group runner with deadlines + output caps + verified-group terminate/reap. Deterministic `RendererAssetExtractorHelperLocation` (signed app `Contents/Helpers`, SwiftPM `.build` products; no PATH). `build.sh` copies + signs it.
- **Authorized asset reader**: immutable session allowlist pinning reference → `SourceID` + exact `SourceVersionID` + MIME + size + digest; reads only through `sourceContent(versionID:)`; per-asset/per-request/aggregate budgets; uniform redacted denial; closed on teardown.
- **Admission**: references resolved only against the exact sibling/File Provider projection (never broadened to all sources), unique match required, resolved before session creation. No production Swift branch names a specific canvas format.
- **Bridge**: separate `asset.read` method + page-envelope case sharing the request-ID replay ledger and session/window/frame/readiness checks; asset requests never pass through the primary input reader, and asset replies never expose primary source bytes.

## Verification

- Node-free JavaScriptCore harness (`JSONCanvasJavaScriptHarnessTests`, 10 tests) executes the exact package stages: scene bounds (incl. negative coords), explicit/automatic side anchors, Bézier control points, JSON Canvas endpoint defaults, all side/end combinations, wrap/clip/overflow, z-order/colors, asset resolution, strict parse rejection of traversal/scheme and closed-field violations. The seam is mandatory — it fails, not skips, when an asset or entry is unavailable.
- Parser suite rewritten from the `nodeAvailable`/`Thread.sleep` node path to in-process JSC: at-cap/one-byte-over, malformed/bounded/unsafe docs, optional-array semantics, unknown-top-level tolerance.
- Hosted WebKit tests (`JSONCanvasRendererPackageHostedValidationTests`, 3): real-window rendering of bezier edges, default `marker-end`, Markdown `strong` inside `foreignObject`, asset fallback, fit transform, malformed-input message + source-byte preservation.
- Package tests (6): revision-5 declaration, roles/MIME/extractor, 7 assets, `asset.read`, viewer static restrictions, tamper rejection.
- Asset-read chain: manifest V5 tests (6), extractor helper + location (7), authorized asset reader (5), bridge contracts incl. asset.read (17), admission builder (3) — 38 focused tests.
- Normal suite: 4181 tests pass. `swift run RendererPackageTool validate RendererPackages/JSONCanvas` passes: version 1.1.0, package hash `696c50ebdd66dbe88f364ffa6d96e663804c1ec7c1ca955380fe10bc54ef5045`.
## Supersedes

Version 1.0.1's rendering claims (center-to-center edges, single-line text, no fit, no images) are superseded by 1.1.0 and fixed in 1.1.1; the 1.0.1 package bytes and hash remain a stability contract in repository history.

## Honest limits / follow-ups

- Hosted test gate (WIKIFS_APP_TESTS=1) is opt-in; the normal suite covers the pure stages deterministically.
- Live inline/source-pane/window wiring of the prepared asset reader (factory threading + `RendererAssetSessionPreparer`) is committed; the end-to-end session consumption of `asset.read` in live inline attachments is exercised by the hosted tests through the broker.
- SVG remains outside the approved MIME declaration until the `hostileSVGRemainsConfinedToImageSurface` gate passes; until then SVG files render the same readable fallback as other unsupported images.
- Manual visual comparison with the user-reported broken canvases (light/dark, multiple window sizes) is the remaining human step before PR readiness; it must not commit private user data.

## 1.1.1 bugfix — subpath validator rejected every subpath

Reported from the Testbed wiki page `01M0GBMFHASD3RGYY6CABBP3FV` ("JSON Canvas — File and Link Nodes"): a valid canvas with file nodes carrying `subpath: "#JSON Canvas Testbed"` could not be read (`invalid internal link`).

Root cause: the subpath validator in `viewer.js` used `/[?#%]/.test(wire.subpath)` — the forbidden-character class matched the **leading `#`** of every subpath, so any `subpath` was rejected. The fix tests `wire.subpath.slice(1)` so the leading `#` is allowed and only `?`/`%` after it are rejected.

Regression: `JSONCanvasFixtures.fileAndLinkNodes` (the exact Testbed canvas) + `JSONCanvasJavaScriptHarnessTests.acceptsFileSubpathsAndNamedSpaces` assert the canvas parses, its scene bounds are correct (`740×480`), and both file nodes resolve as imageNode asset requests. This also fixed a latent harness bug where `parseCanvas` was passed raw JSON instead of base64 (the traversal-rejection test now *actually* exercises the parser).

Package version bumped to `1.1.1` (immutable; viewer bytes changed). Hash `696c50ebdd66dbe88f364ffa6d96e663804c1ec7c1ca955380fe10bc54ef5045`.
