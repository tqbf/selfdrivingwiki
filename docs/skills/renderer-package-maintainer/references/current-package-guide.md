## Renderer packages

Self Driving Wiki includes and manages the read-only Excalidraw renderer automatically. The app validates the bundled directory and installs it in the machine renderer store. The package ID is `org.selfdrivingwiki.excalidraw-readonly`. The version is `1.0.1`. The registration ID is `excalidraw`.

### Scope and availability

Renderer packages are machine-scoped. Every compatible validated installed renderer is available to every wiki. A disabled compatibility row in `renderer_wiki_enablement` does not suppress a renderer. Do not add new enablement writes or UI controls. The app keeps existing enablement rows, journal cases, decoding, and APIs for compatibility only.

A source can retain a logical or exact renderer preference. A logical preference selects a registration from an available package. An exact preference pins a package version for that source. Preferences do not install a package, change another source, or limit another wiki. Open renderer sessions retain their active exact pins during registry refresh.

### Package v1

A package is one local directory. It contains one normalized `manifest.json` and only the files declared in that manifest. The manifest has a revision, a typed package ID, a typed version, descriptors, and asset digests. Every descriptor has a typed registration ID, matchers, an implementation, approved assets, capabilities, input limits, link policy, accessibility values, compatibility values, and priority.

Use a local directory for Advanced Local Renderer Package Import. The app accepts directories only. It does not accept archives, downloaded packages, a catalog, signing, network distribution, or a destination picker.

`RendererPackageValidator` copies a candidate into machine staging. It rejects traversal, duplicate paths, symlinks, nonregular files, unsupported files, missing files, undeclared files, changed sources, and asset or package hash mismatches. The validator calculates SHA-256 digests over normalized package data. Do not construct a `ValidatedRendererPackage` outside the validator.

`RendererMachineIndexStore.activate` revalidates the staged package while the package-store coordinator holds its cross-process lock. It checks the authoritative package ID, version, and expected hash before the no-replace move. An identical validated installed hash is an idempotent no-op. A different hash fails closed. A no-op does not create another install event. A removed tombstone with the same hash can restore the exact package through normal validation and activation.

The machine index owns package payload state and safe-mode suppression. It is outside wiki databases and File Provider projections. Removal creates a machine tombstone and deletes only the payload. It preserves source preferences. A later bundled bootstrap restores the exact reviewed Excalidraw version when tombstone state permits it.

### Matching, fallback, and safe mode

The registry combines native descriptors with all compatible validated installed descriptors. It does not filter installed descriptors through per-wiki enablement. Matchers use normalized MIME type, extension fallback, artifact kind, and bounded content signatures. Source fallback remains available when a package is absent, invalid, incompatible, safe-mode suppressed, or cannot create a validated session. Native renderers remain available.

Safe mode suppresses one installed package version after qualifying renderer failures. It does not disable Source or native renderers. Resetting safe mode only restores the suppressed machine package version. It does not alter source preferences or active session pins.

### Web package isolation

Web packages use a nonpersistent WebKit data store and the `renderer-package` scheme. The scheme handler serves only validated declared package bytes and adds restrictive CSP headers before WebKit parses content. Package HTML does not use a file URL, a network URL, or `loadHTMLString`.

The package CSP permits package-local scripts, styles, images, media, and fonts. It blocks network connections, frames, workers, objects, forms, and base URLs. The navigation delegate separately cancels unsafe navigations. It does not claim to intercept all subresource requests.

The native bridge runs in an isolated content world. Its only read method is `input.read`. Each request needs a per-session capability, a unique request ID, the expected session, the expected window, and the main frame. The host enforces message and payload limits. The bridge reads only the host-authorized pinned input. It cancels and removes handlers when the session closes.

An external link requires a declared link policy and a host-observed user gesture. The host authorizes only a normalized HTTP or HTTPS destination with a single-use session-bound nonce.

### Bundled Excalidraw

The bundled package root is `RendererPackages/Excalidraw` at build time. SwiftPM copies it into the app resource bundle. Runtime bootstrap reads the bundled resource, not the source checkout. The package has `LICENSE.md`, `PROVENANCE.md`, `index.html`, `viewer.css`, and `viewer.js`. The manifest pins each SHA-256 digest. Keep its manifest, hashes, license, and provenance exact when you package it.

Excalidraw matches `application/json`, the `excalidraw` extension, and the bounded Excalidraw JSON signature. It is a read-only Web renderer. It declares `input.read` and user-activated external links. It has 48,000-byte input and decoded-input limits. The viewer supports VoiceOver and keyboard navigation.

### Minimal two-file example

This minimal package has an entry document and no script. A real package must use SHA-256 values calculated from its actual bytes.

`manifest.json`:

```json
{
  "revision": 1,
  "packageID": "org.example.readonly",
  "version": "1.0.0",
  "descriptors": [{
    "reference": {
      "packageID": "org.example.readonly",
      "version": "1.0.0",
      "registrationID": "example"
    },
    "displayName": "Example",
    "implementation": { "webPackage": { "_0": { "path": "index.html" } } },
    "matchers": [{ "extensionFallback": { "_0": "example" } }],
    "presentations": ["web"],
    "approvedAssets": [{
      "path": "index.html",
      "digest": "5ce39d66a927d4e2933dc6a637a9c54eee55a1d54da48b87791b0d90bd23022b"
    }],
    "capabilities": ["inputRead"],
    "sizeLimits": { "maximumInputByteCount": 1024, "maximumDecodedByteCount": 1024 },
    "linkPolicy": "none",
    "accessibility": { "supportsVoiceOver": true, "supportsKeyboardNavigation": true },
    "compatibility": { "minimumProtocolRevision": 1, "maximumProtocolRevision": 1 },
    "priority": 0
  }],
  "assets": [{
    "path": "index.html",
    "digest": "5ce39d66a927d4e2933dc6a637a9c54eee55a1d54da48b87791b0d90bd23022b"
  }]
}
```

`index.html`:

```html
<!doctype html><meta charset="utf-8"><title>Example</title><p>Read-only renderer.</p>
```

The digest is the lowercase SHA-256 digest of the shown `index.html` bytes. Recalculate both values when you change the file. The validator rejects missing declarations and a digest that does not match `index.html`.
