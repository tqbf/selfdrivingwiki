## Renderer packages

The repository includes a reviewed read-only Excalidraw renderer package. The app does not bundle or install this package automatically. Import `RendererPackages/Excalidraw` through Settings → Renderers → Advanced Local Renderer Package Import. The package ID is `org.selfdrivingwiki.excalidraw-readonly`. The version is `1.0.5`. The registration ID is `excalidraw`.

### Scope and availability

Renderer packages are machine-scoped. Every compatible validated installed renderer is available to every wiki. A disabled compatibility row in `renderer_wiki_enablement` does not suppress a renderer. Do not add new enablement writes or UI controls. The app keeps existing enablement rows, journal cases, decoding, and APIs for compatibility only.

A source can retain a logical or exact renderer preference. A logical preference selects a registration from an available package. An exact preference pins a package version for that source. Preferences do not install a package, change another source, or limit another wiki. Open renderer sessions retain their active exact pins during registry refresh.

### Package v1

A package is one local directory. It contains one normalized `manifest.json` and only the files declared in that manifest. The manifest has a revision, a typed package ID, a typed version, descriptors, and asset digests. Every descriptor has a typed registration ID, matchers, an implementation, approved assets, capabilities, input limits, link policy, accessibility values, compatibility values, and priority.

A revision 2 descriptor may declare `fenceClaims`: one array entry per claimed Markdown rich-fence alias, each with the alias and the inline MIME type the fence bytes are handed to the renderer as. Claims require the `disclosureRow` role, must be unique inside the package, cannot use an alias a built-in or another installed package already claims, and revision 1 packages never receive fence authority. Claiming an alias changes the manifest bytes, so bump the reviewed version with the change. The fence card's display text derives from the descriptor `displayName`; manifests carry no other per-format presentation strings. See `plans/package-declared-fences.md`.

Use a local directory for Advanced Local Renderer Package Import. The app accepts directories only. It does not accept archives, downloaded packages, a catalog, signing, network distribution, or a destination picker.

`RendererPackageValidator` copies a candidate into machine staging. It rejects traversal, duplicate paths, symlinks, nonregular files, unsupported files, missing files, undeclared files, changed sources, and asset or package hash mismatches. The validator calculates SHA-256 digests over normalized package data. Do not construct a `ValidatedRendererPackage` outside the validator.

`RendererMachineIndexStore.activate` revalidates the staged package while the package-store coordinator holds its cross-process lock. It checks the authoritative package ID, version, and expected hash before the no-replace move. An identical validated installed hash is an idempotent no-op. A different hash fails closed. A no-op does not create another install event. A removed tombstone with the same hash can restore the exact package through normal validation and activation.

The machine index owns package payload state and safe-mode suppression. It is outside wiki databases and File Provider projections. Removal creates a machine tombstone and deletes only the payload. It preserves source preferences. A later local import can restore a package when the tombstone hash matches.

### Matching, fallback, and safe mode

The registry combines native descriptors with all compatible validated installed descriptors. It does not filter installed descriptors through per-wiki enablement. Matchers use normalized MIME type, extension fallback, artifact kind, and bounded content signatures. Source fallback remains available when a package is absent, invalid, incompatible, safe-mode suppressed, or cannot create a validated session. Native renderers remain available.

Safe mode suppresses one installed package version after qualifying renderer failures. It does not disable Source or native renderers. Resetting safe mode only restores the suppressed machine package version. It does not alter source preferences or active session pins.

### Web package isolation

Web packages use a nonpersistent WebKit data store and the `renderer-package` scheme. The scheme handler serves only validated declared package bytes and adds restrictive CSP headers before WebKit parses content. Package HTML does not use a file URL, a network URL, or `loadHTMLString`.

The package CSP permits package-local scripts, styles, images, media, and fonts. It permits WebAssembly compilation through `'wasm-unsafe-eval'`, without JavaScript `eval`. It permits a package to fetch its own declared, hash-pinned assets through the `renderer-package` scheme. It blocks network origins, frames, workers, objects, forms, and base URLs. The navigation delegate separately cancels unsafe navigations. It does not claim to intercept all subresource requests.

Run WebAssembly on the main thread. A worker needs `worker-src`, and the CSP keeps that closed. Do not load WebAssembly bytes from a network origin.

The native bridge runs in an isolated content world. Its only read method is `input.read`. Each request needs a per-session capability, a unique request ID, the expected session, the expected window, and the main frame. The host enforces message and payload limits. The bridge reads only the host-authorized pinned input. It cancels and removes handlers when the session closes.

An external link requires a declared link policy and a host-observed user gesture. The host authorizes only a normalized HTTP or HTTPS destination with a single-use session-bound nonce.

### Reviewed Excalidraw renderer package

The reviewed package root is `RendererPackages/Excalidraw` in the repository. SwiftPM does not copy it into the app resource bundle. Users import the folder through Settings → Renderers → Advanced Local Renderer Package Import.

The package version is `1.0.5`. Its manifest declares a bounded JSON matcher for complete objects with `type` equal to `excalidraw`, `version` equal to `2`, and an `elements` array of objects. It is a read-only Web renderer. It declares `input.read` and user-activated external links. It has 48,000-byte input and decoded-input limits. The viewer supports VoiceOver and keyboard navigation.

### Create and validate a package

Use the tested package in [`../assets/minimal-renderer-package/`](../assets/minimal-renderer-package/) as the starting point. It contains `manifest.json` and one semantic, read-only `index.html` file.

Copy the complete folder before you edit it. Change the package, version, and registration identifiers. Add only the static assets that the renderer needs.

Calculate each lowercase SHA-256 digest after the final asset edit. Put the same asset records in each descriptor `approvedAssets` list and the top-level `assets` list.

Run this command from the repository root:

```text
swift run RendererPackageTool validate <package-folder>
```

The command validates a local folder under an invocation-owned temporary root. It prints the package ID, version, sorted registration IDs, and package hash as JSON.

The command removes its temporary data after success or failure. It does not install, activate, remove, refresh, or change a renderer package.

Fix every validator error before import. Then ask the user to import the validated folder through Settings → Renderers.
