---
timestamp: 2026-09-01T210000Z
title: Move Mermaid to a local renderer package
branch: feature/mermaid-renderer-package
status: complete
---

# Move Mermaid to a local renderer package

## Progress

Mermaid is no longer a built-in renderer. All Mermaid rendering and all save-time fence-syntax validation moved into the reviewed package at `RendererPackages/Mermaid`. Production Swift keeps zero Mermaid rendering code and zero Mermaid JavaScript bytes.

The manifest revision is now 3. A fence claim may declare a `validation` object with an engine asset path, a wrapper asset path, and an entry function. The declaration requires two distinct approved assets and one JavaScript identifier. A revision 1 or 2 manifest that carries the declaration is rejected. Revision 2 canonical bytes and reviewed package hashes did not change.

The host keeps a format-neutral `FenceSyntaxValidator` runner and a package-driven `FenceSyntaxValidationService`. The service reads the machine index store, loads the declared assets through the validated resource provider, and caches one runner per package version. The wrapper asset evaluates before the engine, because the bundled engine captures DOM state while it loads. All Mermaid-specific JavaScript knowledge lives in the package's `validate.js`.

The built-in descriptor, the reader's Mermaid DOM plumbing, the `.diagram` embed target, and the SourceDetail detector are deleted. A claimed mermaid fence renders through the generic disclosure-row card. A `.mmd` source presents like any other renderer-package text source. Sources gained an optional file extension so extension-fallback matchers resolve legacy NULL-MIME rows.

`wikictl page save` blocks on an invalid claimed fence when the declaring package is installed, and prints a one-line skip notice when no package declares the fence. The in-app editor keeps a non-blocking banner. Save-time validation runs only where the package is installed.

`MermaidSourceNeutralityTests` enforces the boundary. Production Swift outside the three-file ingestion allowlist never names the format. `Package.swift` and `build.sh` reference no Mermaid asset. `Resources/` no longer carries the vendored engine or the retired validator bundle.

The design record with accepted behavior changes and deviations is in [`plans/mermaid-renderer-package.md`](../plans/mermaid-renderer-package.md).

## Verification

- `swift run RendererPackageTool validate RendererPackages/Mermaid` passes. Package hash `714bb2a23a33bbe45ab9507137c2784d844fee32220ae6248ea78a60e2acda6f`.
- `make build` and `make test` pass. The full suite runs 4128 tests in 445 suites.
- `WIKIFS_APP_TESTS=1 swift test --filter MermaidRendererPackageHostedValidationTests` passes 5 tests: the startup `input.read` render in both appearances, the parse-error session integrity, the claimed-fence render, the install/removal cycle with the save-validation service, and the no-package Source-tab plus bundle-absence legs.
- `WIKIFS_APP_TESTS=1 swift test` covers the reader golden suites for claimed fences and `.mmd` embeds.
- Pre-existing machine-environment failures were verified against a `main` worktree baseline. This branch introduces no regressions.

Manual spot-check: a separately built release bundle contains no `mermaid.js` or `merval.bundle.js` resource. Importing through the real Settings UI stays manual, as the plan records.
