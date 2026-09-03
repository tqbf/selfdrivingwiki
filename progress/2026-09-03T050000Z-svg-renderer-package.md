---
timestamp: 2026-09-03T050000Z
title: Move SVG to a reviewed renderer package
branch: feature/svg-renderer-plugin
status: complete
---

# Move SVG to a reviewed renderer package

## Progress

SVG is no longer a built-in renderer. All SVG display knowledge moved into the reviewed package at `RendererPackages/SVG`. Production Swift keeps zero SVG rendering code.

The package is manifest revision 1: `org.selfdrivingwiki.svg-readonly` version `1.0.0`, registration `svg`. It matches `image/svg+xml` plus the `.svg` extension fallback, declares `input.read` only, no external links, and 16,000,000-byte input/decoded limits — the retired built-in's ceiling. It fills both embedding roles at priority 100 (the retired built-in's tier) and claims no fence alias. `PROVENANCE.md` records that the package carries no vendored third-party bytes: the viewer renders through WebKit's native SVG image mode, so there is no engine to vendor.

The viewer mounts the exact authorized bytes as a base64 `data:` image — the same inert display surface the retired `SVGRendererView` used. WebKit image mode is the security boundary: script never runs, event handlers never bind, external references never load. To keep that mechanism, the generic package CSP now admits `data:` in `img-src` only (`RendererContentSecurityPolicy.headerValue`); no other directive gained a source, and `RendererCapabilityBoundaryPolicyTests` pins that `data:` never appears outside `img-src`. No reviewed package other than SVG mounts `data:` images today.

The built-in removal deleted: `BuiltInRendererID.svg` (the enum is closed, so no persisted decode path regresses), the descriptor case, `BuiltInRendererMIME.svg`, `BuiltInRendererLimits.svgMaximumInputByteCount`, the `makeSVG` factory entry, and `SVGRendererView.swift`. A `.svg` source now presents as readable source text until the package is installed; the planner's neutral code-block presentation is unchanged and regression-pinned.

Tests: `SVGRendererPackageTests` (offline validation, matching, capability/size pins, viewer inertness contract, tamper rejection), `SVGSourceNeutralityTests` (deleted renderer symbols stay deleted), and the `RendererCapabilityBoundaryPolicyTests` CSP golden. The retired `SVGRendererTests` and the SVG built-in fixtures in the registry, presentation-state, and D2 matching suites moved to `pdf`/`html` legs.

## Verification

- `swift run RendererPackageTool validate RendererPackages/SVG` passes. Package hash `49341b23028b1537befc813dfa7e790f6e04fe1d1e5c7a84a755a64cd88b68e4`.
- `make build` passes.
- `make test` passes; see the branch commit for the final suite count.
- The CSP golden and the scoped-leg test updates compile and run in the full suite.

Manual spot-check: import `RendererPackages/SVG` through Settings → Renderers on a dev machine and confirm an `.svg` source renders inline, refuses to execute a `<script>` payload, and falls back to readable source text after package removal.
