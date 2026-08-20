---
name: renderer-package-maintainer
description: Create and maintain Self Driving Wiki static renderer packages. Use when adding, authoring, reviewing, importing, updating, removing, or documenting a renderer package, including bundled Excalidraw.
---

# Renderer package maintainer

Read [the current package guide](references/current-package-guide.md) before you change a renderer package or its documentation.

## Create a package

1. Copy [`assets/minimal-renderer-package/`](assets/minimal-renderer-package/) to the requested local destination.
2. Choose valid package, version, and registration identifiers.
3. Add only static assets.
4. Declare every asset in `manifest.json`.
5. Choose bounded matchers, capabilities, limits, link policy, accessibility values, compatibility, and priority.
6. Calculate lowercase SHA-256 digests from the final asset bytes.
7. Put identical asset records in each descriptor `approvedAssets` list and the top-level `assets` list.
8. Run `swift run RendererPackageTool validate <folder>` from the repository root.
9. Fix every validator error before import.
10. Test matching, rendering, keyboard access, VoiceOver labels, failure fallback, and external-link policy when applicable.
11. Tell the user to import the validated folder through Settings → Renderers.

The validation tool does not install or activate the package.

## Package HTML rules

- Use package-local assets only.
- Do not add a network dependency.
- Do not use file URLs.
- Do not add frames, workers, objects, or forms.
- Use the native bridge only through declared capabilities.
- Read [Web package isolation](references/current-package-guide.md#web-package-isolation) before you add script or bridge access.

A package with interactive controls needs its own keyboard and VoiceOver tests. The minimal template is read-only and non-interactive.

## Maintain a package

1. Keep a v1 package as one local folder with `manifest.json` and declared static assets.
2. Use typed package, version, registration, and renderer-reference values at Swift boundaries.
3. Validate every folder with `RendererPackageValidator` before activation.
4. Activate only through `RendererMachineIndexStore` and its coordinator.
5. Treat an installed renderer as machine-scoped. Every compatible validated package is available to every wiki.
6. Do not use wiki enablement as an availability decision. Compatibility rows remain inert.
7. Keep source logical and exact preferences separate from installation and availability.
8. Keep source fallback and native renderers available after every package failure.
9. Update the guide reference and its documentation tests when package facts change.

Do not add a catalog, signing, archives, remote distribution, network installation, destination selection, automatic source-preference changes, per-wiki enablement, or storage migration.
