# Dynamic extractor Cordis lifecycle

This document describes how installed extractor package revisions become active registrations inside one process, and how the durable machine catalog, the dynamic plugin host, and the process executor cooperate.

Sources of truth in code:

- Trusted dynamic host: `Sources/CordisLoader/DynamicPluginHost.swift`
- Generated definitions: `Sources/WikiFSEngine/ExtractorPackagePluginDefinitionFactory.swift`
- Reconciler: `Sources/WikiFSEngine/ExtractorPackagePluginReconciler.swift`
- Store layout, admission, and modes: `Sources/WikiFSCore/Extractor/ExtractorDirectoryAdmission.swift`
- Store coordination: `Sources/WikiFSCore/Extractor/ExtractorPackageStore.swift`
- Catalog writer: `Sources/WikiFSExtractorStore/ExtractorPackageCatalogWriter.swift`
- Reviewed packages: `Sources/WikiFSEngine/ReviewedExtractorPackages.swift`
- Process provider: `Sources/WikiFSEngine/ProcessExtractorProvider.swift`

## Layers

Four layers separate durable state from process state:

1. **Durable machine catalog.** Installed package records and immutable bytes under the App Group container. This catalog is authoritative.
2. **Process reconciler.** One actor per app or daemon process reads catalog generations and maps each compatible validated revision to one trusted, host-generated Cordis plugin definition.
3. **Generated plugin.** Owns reversible extraction-registry registrations and package-level lifecycle state inside that process.
4. **Managed process service.** Runs the package script in a separate process through the extractor protocol.

Package code is not loaded as Swift, does not provide a `PluginDefinition`, and never receives a `CordisContext`. The host creates the plugin definition from validated manifest data. Package scripts stay external: they run as one-shot processes and speak the [extractor script protocol](extractor-script-protocol.md).

## Durable machine catalog

The store lives at `extractors/v1/` under the App Group container:

```text
extractors/v1/
├── packages/<packageID>/<version>/   installed immutable bytes
├── staging/                          admission staging areas
├── derived/index.json                versioned catalog index
├── operations/<role>/<pid>-<session> per-process operation roots
└── store.lock
```

Properties that the code enforces:

- **Machine-scoped.** Packages are available to every wiki on this Mac. Package bytes and records never enter wiki SQLite, queue or XPC payloads, or the File Provider projection.
- **App-only writes.** Only the app imports, bootstraps, repairs staging, publishes generations, and removes packages. Daemon catalog APIs are read-only. A daemon mutation attempt fails with `mutationForbidden`.
- **Serialized writers.** One actor plus a store lock (`flock` on `store.lock` with a process gate) excludes stale app writers after a restart.
- **Atomic publication.** The writer moves validated staging to its immutable final location first, then publishes the index generation. Readers observe a complete old or new generation. Correctness does not depend on wake delivery.
- **Recovery.** A moved-but-unpublished package is validated and published or removed before the next mutation. Removal publishes the new generation before deleting bytes.
- **Immutable identity.** A different digest for an existing package ID and version is rejected, both at import and in the index, through digest reservations.

## Reviewed packages

Two reviewed packages ship inside the app bundle and inside the daemon service bundle:

| Directory | Package ID | Version | Registration |
| --- | --- | --- | --- |
| `ExtractorPackages/Defuddle` | `org.selfdrivingwiki.defuddle` | 0.19.1 | `article` (HTML) |
| `ExtractorPackages/Pdf2md` | `org.selfdrivingwiki.pdf2md` | 1.0.0 | `document` (PDF) |

The identity of each reviewed package is a compiled golden constant in `ReviewedExtractorPackages`. A bundled directory runs only when its bytes reproduce the compiled revision, so a tampered or stale bundle payload is rejected instead of executed.

At app startup, `ReviewedExtractorBootstrap` publishes the bundled revisions into the machine catalog. Bootstrap is idempotent and best-effort: a failure logs one redacted diagnostic and leaves startup unaffected.

Both the app and the daemon can run reviewed revisions before publication through the reviewed overlay. The overlay admits bundled bytes into the process's own operation root and synthesizes catalog records. Once the catalog contains an exact revision, the installed bytes win. Neither process treats the overlay as a reason to write the catalog.

## Host-generated plugin definitions

`ExtractorPackagePluginDefinitionFactory` turns one exact revision into one `TrustedDynamicPluginDefinition`:

- **Definition identity** is `dynamic:extractor-package/<digest>`, where `<digest>` is a SHA-256 prefix over the canonical revision tuple. Raw external package IDs do not enter Cordis identity encoding.
- **Fingerprint** covers the exact revision, supported protocol revision, normalized registrations, and the fixed dependency-contract version. The host rejects a repeated definition ID with a different fingerprint. An identical repeat is idempotent.
- **Dependencies** are fixed and host-owned: the extraction backend registry, the extractor catalog reader, the managed process executor, the package admission checker, the package store layout, and the package source locator. A manifest cannot request other Cordis services, register global services, supply tools, or add listeners. The generated plugin contributes only extractor registrations.
- **Declared work** is one atomic registration batch plus its cleanup effect.

Each `run` invokes the trusted definition factory again and creates a fresh `ComponentDefinition` and `ComponentID`. Definition identity stays stable per revision. Component identity is unique per activation run. Activation revalidates that the exact revision is still in the authoritative catalog, but starts no script and downloads nothing. Heavy snapshot work happens later, per prepared operation.

## DynamicPluginHost operations

`DynamicPluginHost` in `CordisLoader` is the generic trusted-definition lifecycle host. It accepts only trusted in-memory definitions with immutable fingerprints. It supports:

| Operation | Behavior |
| --- | --- |
| `define` | Records one immutable trusted definition without activation. |
| `run` | Registers the component, awaits settlement, retains the exact run and handle. |
| `stop` | Disposes the component and its declared effects; retains the definition. |
| `undefine` | Stops and removes the definition and retained lifecycle state. |
| `inspect` | Returns a source-free state snapshot. |
| `reconcile` | Applies a desired definition set: define, run, and undefine the rest. |

Lifecycle states: `defined`, `starting`, `waiting`, `active`, `failed`, `stopping`, `stopped`, `undefined`. Failure phases: `definitionFactory`, `componentRegistration`, `activation`, `lifecycle`, `disposal`, `inspection`.

`run` returns a typed outcome: `active` with run and component IDs, `waiting` with the missing host dependencies, or `failed` with a phase and failure. A settled pending component counts as waiting only when declared host dependencies are absent, and it contributes no registration until it activates. Observing an existing `waiting` or `active` run never calls `run` again.

Failure isolation: On run failure, the host disposes the failed component before it returns. It keeps the failed attempt separate from physical component state. It preserves a working revision of the same lineage. Stop and undefine are idempotent. A stale run, disposer, or handle cannot affect a newer run. The host retains cleanup anomalies and Cordis cleanup failures for inspection. It does not claim that a consumed disposer ran again. Retention is bounded by policy: 16 runs and 32 diagnostics per definition.

## Reconciliation

`ExtractorPackagePluginReconciler` applies durable generations to the process graph:

1. Read the authoritative catalog. An unchanged generation is skipped unless forced. A corrupt or unreadable catalog keeps the current graph untouched instead of tearing down known-good state.
2. Build and validate all desired definitions before any lifecycle mutation, so a manifest that contradicts its catalog record never causes a partial pass.
3. Reconcile each revision independently. One package that fails to build or activate never blocks unrelated packages.
4. For a desired revision: define it idempotently, run it if stopped, and expose it for selection only after active settlement and batch registration.
5. For an undesired revision: remove it from selection through the authoritative catalog gate, stop it to preparation quiescence, run each cleanup effect once, then undefine retained state.
6. Retain bounded, redacted failure records. Messages contain no paths and no environment details.

Cross-process wake notifications are payload-free hints. Every reconciliation reads an authoritative generation, so a missed or stale wake cannot restore removed admission or lose new state.

## Registration lifetime

The generated component registers all declared registrations through `ExtractionBackendRegistry.registerBatch`:

- Each registration derives one revision-qualified exact key (`kind` plus exact `ExtractorReference`).
- The registry validates every entry and collision before it commits anything.
- The batch commits atomically and returns a handle with an exact activation token.
- The batch removes only registrations owned by that token. A stale disposer is a no-op against newer registrations.
- The plugin's staged cleanup effect disposes the batch in defined order when the component is disposed.

`ExtractionBackendRegistry` is the only adapter authority for built-in and package extraction. The static `PluginCatalog` remains link-time and immutable; dynamic definitions live only in `DynamicPluginHost`.

## Operation pinning

Preparation and execution are pinned to exact bytes:

1. Before returning a prepared operation, the provider verifies that the plugin activation is still admitted, that the exact revision is still in the catalog or reviewed overlay, and that a private validated snapshot of the installed bytes exists.
2. A prepared operation owns its snapshot. Plugin stop, package removal, or a catalog refresh cannot change or terminate it. Only full extraction-context shutdown cancels managed operations.
3. Concurrent operations get disjoint request-scoped subdirectories and share the immutable package snapshot.
4. The executor rechecks executable identity immediately before spawn and runs the protocol exchange under the deadline and cancellation rules.

## App and daemon independence

Each app or daemon process owns one extraction context with its own `ExtractionBackendRegistry`, `DynamicPluginHost`, reconciler, catalog reader, and executor. Run IDs, component handles, activation tokens, and reconciler state never cross process boundaries. One process may show a revision as active while another is still reconciling. The durable catalog, not either process graph, is the shared truth.

## Provenance

Extraction activity plan version 1 stores an additive `.installedPackage` producer with the exact revision, registration ID, protocol revision, and package-reported tool and model metadata. Existing producers decode unchanged, unknown producer kinds degrade to a missing producer without losing other fields, and no SQLite migration is required. Package versions are never presented as model versions. Provenance stores no package content, source content, environment values, or unbounded stderr.

## Non-goals

- No sandbox. Cordis lifecycle controls host registration and ordering, not operating-system isolation. Capability declarations are review facts.
- No dynamic code loading. `PluginCatalog` stays static. The dynamic host accepts only host-generated definitions.
- No package-supplied Cordis services, tools, events, or listeners.
- No long-lived package daemon. Package processes are one-shot.
- No archive, URL, registry, or network installation. Import is one local directory, and only the app imports.

Related documents:

- [Extractor script protocol](extractor-script-protocol.md)
- [Extractor package manifest](extractor-package-manifest.md)
- [Extractor packages (user guide)](../user-guide/extractor-packages.md)
