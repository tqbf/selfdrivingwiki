## Renderer packages

The repository includes a reviewed read-only Excalidraw renderer package. The app does not bundle or install this package automatically. Import `RendererPackages/Excalidraw` through Settings → Renderers → Advanced Local Renderer Package Import. The package ID is `org.selfdrivingwiki.excalidraw-readonly`. The version is `1.0.5`. The registration ID is `excalidraw`.

### Scope and availability

Renderer packages are machine-scoped. Every compatible validated installed renderer is available to every wiki. A disabled compatibility row in `renderer_wiki_enablement` does not suppress a renderer. Do not add new enablement writes or UI controls. The app keeps existing enablement rows, journal cases, decoding, and APIs for compatibility only.

A source can retain a logical or exact renderer preference. A logical preference selects a registration from an available package. An exact preference pins a package version for that source. Preferences do not install a package, change another source, or limit another wiki. Open renderer sessions retain their active exact pins during registry refresh.

### Package v1

A package is one local directory. It contains one normalized `manifest.json` and only the files declared in that manifest. The manifest has a revision, a typed package ID, a typed version, descriptors, and asset digests. Every descriptor has a typed registration ID, matchers, an implementation, approved assets, capabilities, input limits, link policy, accessibility values, compatibility values, and priority.

A revision 2 descriptor may declare `fenceClaims`: one array entry per claimed Markdown rich-fence alias, each with the alias and the inline MIME type the fence bytes are handed to the renderer as. Claims require the `disclosureRow` role, must be unique inside the package, cannot use an alias a built-in or another installed package already claims, and revision 1 packages never receive fence authority. Claiming an alias changes the manifest bytes, so bump the reviewed version with the change. The fence card's display text derives from the descriptor `displayName`; manifests carry no other per-format presentation strings. A revision 3 claim may add a `validation` declaration for save-time fence-syntax validation; see the reviewed Mermaid package section below. See `plans/package-declared-fences.md`.

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

### Reviewed Mermaid renderer package

The reviewed package root is `RendererPackages/Mermaid` in the repository. SwiftPM does not copy it into the app resource bundle. Users import the folder through Settings → Renderers → Advanced Local Renderer Package Import. The package ID is `org.selfdrivingwiki.mermaid-readonly`. The version is `1.0.1`. The registration ID is `mermaid`.

The package claims the `mermaid` fence alias with the inline MIME type `text/mermaid`, and it matches `text/mermaid` sources plus the `.mmd` extension fallback. It is a read-only Web renderer. It declares `input.read` only, no external links, and 48,000-byte input and decoded-input limits. It has priority 90 and fills both embedding roles.

The package carries one vendored engine asset, `mermaid.min.js`, from the upstream Mermaid 11.16.0 MIT distribution. `PROVENANCE.md` records the source URL and the asset digest. The same engine asset serves rendering and validation.

The manifest is revision 3. Its claim carries a fence-syntax validation declaration: the engine asset `mermaid.min.js`, the wrapper asset `validate.js`, and the entry function `__sdw_validate_fence`. The wrapper asset installs a minimal DOM and timer environment before the engine loads, because the bundled engine captures DOM state when it loads. The host evaluates the wrapper first, then the engine, then calls the entry function.

A revision 3 claim may declare `validation` with `engineAssetPath`, `wrapperAssetPath`, and `entryFunction`. The two asset paths must be distinct, approved by the declaring descriptor, and declared in the top-level asset list. The entry function must be one JavaScript identifier. A revision 1 or 2 manifest that carries a `validation` object is rejected.

### Reviewed JSON Canvas renderer package

The reviewed package root is `RendererPackages/JSONCanvas` in the repository. SwiftPM does not copy it into the app resource bundle. Users import the folder through Settings → Renderers → Advanced Local Renderer Package Import. The package ID is `org.selfdrivingwiki.json-canvas-readonly`. The version is `1.1.2`. The registration ID is `json-canvas`. The manifest is revision 5.

The package matches `application/json` sources with a bounded JSON matcher requiring root-object `nodes` and `edges` arrays of objects, plus the `.canvas` extension fallback. It claims the `jsoncanvas` fence alias with the inline MIME type `application/json`. It fills both embedding roles, has priority 110, and 48,000-byte input and decoded-input limits.

The package declares `inputRead`, `externalLink`, `hostNavigation`, and `assetRead` capabilities with a `hostNavigation` declaration that allows page, source, and named-content target kinds, and an `assetRead` declaration (roles `imageNode` + `groupBackground`; MIME `image/png`, `image/jpeg`, `image/gif`, `image/webp`; one reviewed `extractor.js` with entry `__sdw_extract_canvas_assets`; bounded extractor and session limits). It uses the user-activated external-link policy and protocol revision 1.

### Manifest revision 5 and asset read

A revision 5 manifest may declare the optional `assetRead` capability plus an `assetRead` object with:

- `allowedRoles`: a nonempty closed set (`imageNode`, `groupBackground`).
- `allowedMIMETypes`: a nonempty subset of `image/png`, `image/jpeg`, `image/gif`, `image/svg+xml`, `image/webp`. SVG stays excluded from the JSON Canvas declaration until a hostile-SVG image-surface isolation gate passes.
- `maximumExtractedReferenceCount`, `maximumExtractorInputBytes`, `maximumExtractorOutputBytes`, `maximumExtractorExecutionSeconds`, `maximumBytesPerAsset`, `maximumAggregateSessionBytes`: bounded ceilings.
- `extractorAsset`: a package-local asset (hash-approved, declared in both the descriptor and top-level assets) that derives `{role, reference}` records from the pinned primary input.
- `extractorEntryFunction`: an identifier-safe entry name.

The capability requires the declaration, and the declaration requires the capability. Built-in/native declarations are rejected, and the extractor asset must be approved by the declaring descriptor. Revisions 1 to 4 that carry asset-read authority fail closed.

The host runs the reviewed extractor in a single-invocation helper (fresh JavaScriptCore context, bounded framed stdin/stdout, enforced deadline + output caps, process-group terminate/reap) before any WebKit session exists, resolves each record against the exact sibling/File Provider projection, and pins each to `SourceID` + exact `SourceVersionID` + MIME + size + digest. The session asset reader returns only bounded approved bytes through `asset.read`; every miss is a uniform redacted denial. The package cannot enumerate the wiki, request arbitrary SourceIDs, read the primary canvas through `asset.read`, or fetch network/file URLs.

### Manifest revision 4 and host navigation

A revision 4 (or later) manifest may declare the optional `hostNavigation` capability and a `hostNavigation` object with `allowedTargetKinds` (a nonempty set of `page`, `source`, and `namedContent`).

The capability requires the declaration, and the declaration requires the capability. Built-in or native declarations are rejected. Revisions 1 to 3 that carry a navigation capability or declaration fail closed. Older hosts cannot decode the capability and reject the manifest.

Package code may request only the declared, typed target kinds through the isolated bridge. Named-content references are validated relative paths with an optional `#subpath`; the trusted host normalizes basename, extension removal, and anchor before routing. Every internal navigation request requires a fresh host-observed, single-use, purpose-bound user activation, and the bridge returns only a uniform acknowledgement. External HTTP(S) links continue through the separate external-link activation flow.

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
