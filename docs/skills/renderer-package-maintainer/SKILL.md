---
name: renderer-package-maintainer
description: Maintain Self Driving Wiki static renderer packages. Use when adding, reviewing, importing, updating, removing, or documenting a renderer package, including bundled Excalidraw.
---

# Renderer package maintainer

Read [the current package guide](references/current-package-guide.md) before you change a renderer package or its documentation.

Use this workflow:

1. Keep a v1 package as one local folder with `manifest.json` and declared static assets.
2. Use typed package, version, registration, and renderer-reference values at Swift boundaries.
3. Validate every folder with `RendererPackageValidator` before activation.
4. Activate only through `RendererMachineIndexStore` and its coordinator.
5. Treat an installed renderer as machine-scoped. Every compatible validated package is available to every wiki.
6. Do not read or write wiki enablement as an availability decision. Compatibility rows remain inert.
7. Keep source logical and exact preferences separate from installation and availability.
8. Keep source fallback and native renderers available after every package failure.
9. Update the guide reference and its documentation tests when package facts change.

Do not add a catalog, signing, archives, network distribution, destination selection, automatic preference changes, or storage migration.
