# Goal

Implement machine-scoped dynamic extractor packages for byte-backed PDF and HTML sources. Represent each exact validated package revision as a host-generated Cordis plugin while package code runs only in a separate process through a versioned protocol.

Migrate Defuddle and pdf2md into reviewed packages. Preserve existing extraction workflows, configuration, provenance compatibility, and optional Bun and uv behavior. Explicit unavailable selections fail closed.

# Implementation Summary

Use four distinct layers:

1. The durable machine catalog owns installed package records and immutable bytes.
2. A process-local reconciler maps each catalog revision into one trusted, host-generated Cordis plugin.
3. The plugin owns reversible extraction-registry registrations and package-level lifecycle state.
4. A managed process service runs the package script through a bounded extractor protocol.

A package script is not loaded as Swift, does not provide a `PluginDefinition`, and never receives `CordisContext`. The host creates the `PluginDefinition` from validated manifest data. Cordis owns dependency ordering, activation state, reversible effects, inspection, and quiescent removal of package registrations. The process service owns executable resolution, input and output, deadlines, cancellation, process groups, and cleanup.

Follow the DeepSeek Harness identity and lifecycle split:

- `ExtractorPackageID` is the stable package lineage.
- `ExtractorPackageRevisionID` identifies exact package ID, semantic version, and digest.
- `ExtractorPackagePluginRunID` identifies one process-local Cordis activation attempt.
- Cordis `PluginID`, loader definition identity, runtime `ComponentID`, and extraction request IDs remain separate namespaces.

Unlike DeepSeek Harness `tool-cordis`, package source does not execute in a VM or host process. Unlike its process-local dynamic definition registry, the extractor machine catalog is durable and authoritative. Each app and daemon process independently reconciles catalog generations into its own Cordis context.

Add a narrow host-generated dynamic plugin facility to `CordisLoader`. The current `PluginCatalog` remains immutable and link-time as documented in `Sources/Cordis/PluginDefinition.swift`. Do not weaken it or allow runtime Swift/module loading. Add a separate `DynamicPluginHost` that accepts only trusted `PluginDefinition` values plus immutable revision fingerprints. It supports define, run, stop, undefine, reconcile, and source-free inspection.

Mount one generated plugin for every compatible validated package revision. Multiple installed versions can remain active because their registry keys carry exact revision identity. Logical selection resolves the highest compatible active revision. A failed new revision does not remove a working older revision.

Each generated plugin declares fixed host-owned dependencies:

- the extraction registry;
- the extractor package catalog reader;
- the managed process executor;
- package diagnostics and operation preparation services.

A package manifest cannot request arbitrary Cordis services, register global services, supply tools, or add listeners. Its plugin can contribute only the extractor registrations declared in its validated manifest.

The first package and protocol revisions support:

- machine-scoped packages available to all wikis;
- local directory import only;
- one-shot process execution only;
- byte-backed PDF and HTML inputs only;
- one input file and one Markdown result per operation;
- JSON Lines control messages on standard input and output;
- a host-owned private operation directory;
- visible capability declarations without a sandbox claim;
- no archive, URL, registry, or remote installation;
- no long-lived package daemon;
- no package-supplied Swift, Cordis plugin, VM code, or in-process module;
- no arbitrary package-defined Cordis dependencies or global registrations;
- no new wiki database schema.

Preserve old `extraction-config.json`, queue payloads, XPC payloads, SQLite columns, and built-in backend names. Add optional logical package selections. Persist exact package provenance through an additive tagged producer in extraction activity plan version 1.

Primary touch points include:

- `Sources/Cordis/PluginDefinition.swift` for documentation only unless a small identity helper is required;
- new trusted dynamic host types in `Sources/CordisLoader/`;
- `Sources/WikiFSTypes/` for package, revision, protocol, and request identities;
- new package manifest, validator, store, catalog, and protocol code in `Sources/WikiFSCore/Extractor/`;
- `Sources/WikiFSCore/Core/AsyncProcessRunner.swift` only for reusable safe primitives;
- `Sources/WikiFSEngine/ExtractionServiceKeys.swift`;
- `Sources/WikiFSEngine/ExtractionPlugins.swift`;
- `Sources/WikiFSEngine/ExtractionRuntimeFactory.swift`;
- `Sources/WikiFSEngine/ExtractionCompositionOwner.swift`;
- `Sources/WikiFSEngine/ExtractionCoordinator.swift`;
- `Sources/WikiFSEngine/ProductionPluginCatalogs.swift` and its `ProcessCompositionInputs` / `ProcessServiceKeys` seams;
- `bundles/wikifs-base/cordis.patch.yml`;
- `Sources/WikiCtlCore/CLIPluginCatalog.swift` and CLI profile tests;
- new extractor package plugin host and reconciler code in `Sources/WikiFSEngine/`;
- `Sources/WikiFSEngine/QueueExtractionProvider.swift`;
- `Sources/WikiFS/Queue/AppQueueExtractionProvider.swift`;
- `Sources/WikiFS/Sources/ExtractionSettingsView.swift`;
- `Sources/WikiFS/Sources/DefuddleExtractionService.swift` and `Sources/WikiFSEngine/PdfExtractionService.swift` during migration;
- `Sources/WikiFSCore/Sources/ExtractionActivityPlan.swift` and `ExtractionProvenance.swift`;
- `Package.swift`, `Makefile`, and `build.sh`;
- `tools/defuddle/`, `tools/pdf2md/`, and new `ExtractorPackages/` resources;
- `PLAN.md`, `plans/`, `docs/architecture/`, `docs/user-guide/`, and `docs/skills/`.

# Implementation Plan

## Phase 0: Establish delivery controls and prove the production process boundary

1. Create `feature/dynamic-extractor-packages` from the current approved base. Enable `.githooks/` before commits.
2. Leave the unrelated untracked `mise.lock` unchanged and out of every commit.
3. Add `plans/dynamic-extractor-packages.md` and index it in `PLAN.md`.
4. Add one `progress/` record after each merged phase. Do not add a generic `PROGRESS.md` entry.
5. Characterize current behavior before composition changes:
   - all built-in PDF backend resolutions;
   - HTML selection and explicit tag-based extraction;
   - queue and direct UI extraction;
   - readiness, setup progress, conversion progress, cancellation, and failure display;
   - backend, model, tool, and technique provenance.
6. Build a signed-service feasibility harness before package or plugin implementation. Reuse the existing `wikid.xpc` precedent for spawning mise-managed pdf2md and agent CLIs. Test only these new boundaries:
   - add a no-dependency fixture executable that exchanges bounded standard-input and standard-output data and spawns a fixture child;
   - build and sign the real app with embedded `wikid.xpc`;
   - install and invoke the service through its production Mach service path;
   - do not substitute `NSXPCListener.anonymous()` or `@testable import wikid`;
   - resolve reviewed extractor package bytes through the same XPC-bundle API production packages use;
   - create the private `0700` operation-directory layout in the real App Group from the service;
   - launch the fixture with the race-free process-group primitive and terminate its verified group on cancellation;
   - retain the scenario in `scripts/test-signed-wikid-extractor.sh` and opt-in `SignedWikiDExtractorLaunchTests`.
7. Stop before Phase 1 if XPC-bundle package lookup, service-owned operation-directory creation, protocol exchange, or race-free process-group termination fails. Ask the operator to select an entitlement change, another process host, or reduced daemon scope. Never route daemon extraction silently through the app.
8. Add architecture guards that reject a second package resolver, package-specific consumer switches, package-supplied Cordis code, and package code in the Swift process.
9. Deliver reviewable, dependency-ordered PRs. Do not merge, enqueue, or enable auto-merge.

## Phase 1: Define extractor package, revision, manifest, selection, and protocol contracts

### Typed identities

1. Add validated types in `WikiFSTypes`:
   - `ExtractorPackageID` for a lowercase reverse-DNS lineage;
   - `ExtractorPackageVersion` for semantic version;
   - `ExtractorPackageDigest`;
   - `ExtractorPackageRevisionID` for package ID, version, and digest;
   - `ExtractorRegistrationID`;
   - `ExtractorReference` for exact revision and registration;
   - `LogicalExtractorReference` for package and registration without version;
   - `ExtractorPackagePluginRunID` for one process-local activation;
   - `ExtractorProtocolRevision` and `ExtractorManifestRevision`;
   - `ExtractorRuntimeName` for one command name without a slash;
   - `ExtractorRequestID` for one extraction operation.
2. Keep extractor, renderer, Cordis plugin, Cordis component, activation-run, and extraction-request namespaces distinct.
3. Use closed enums for extractor kind, launch mode, capability, input transport, event kind, and failure cause.
4. Do not use sentinel strings for built-in, automatic, missing, disabled, stopped, or failed state.

### Manifest revision 1

5. Define `ExtractorManifest` with:
   - manifest revision;
   - package ID, version, and display name;
   - protocol revision;
   - one package-relative entry point;
   - direct execution or one validated runtime command with fixed arguments;
   - one or more registrations;
   - declared package files and SHA-256 digests;
   - declared behavioral capabilities;
   - operation limits within host policy.
6. Each registration declares an ID, display name, supported extractor kinds, normalized MIME types, and optional filename extensions.
7. Limit revision 1 to PDF and HTML byte extraction. Reject transcript and URL-only registrations.
8. Define capabilities as a closed set. Include network, shared runtime cache, and model download. Capability declarations are review facts, not arbitrary Cordis dependencies or proof of OS enforcement.
9. Define capability implications. Model download requires network. Reject inconsistent declarations.
10. Reject unsupported revisions, duplicate registrations, empty kind sets, invalid paths, normalized collisions, undeclared files, unsupported capabilities, and limits above host policy.
11. Define entry-point modes:
    - direct launch requires a staged regular file with an allowed owner-executable source mode;
    - runtime launch requires a readable regular script and does not require execute permission.
12. Normalize installed and operation-snapshot permissions:
    - directories use fixed owner-only traversal;
    - ordinary files use fixed owner-read-only mode;
    - only a direct entry point receives fixed owner-read-and-execute mode.
13. Recheck normalized mode immediately before spawn. Reject source mode or identity changes during copy and mode drift after installation or snapshot creation.
14. Treat normalized modes as host-derived admission invariants, not digest input.
15. Compute a deterministic package digest from canonical normalized manifest data and every declared file digest. Exclude source metadata, modes, and installation paths.
16. Add a machine-readable schema and checked valid/invalid fixture corpus. Make schema and Swift validation agree.

### Protocol revision 1

17. Define portable `Codable` JSON Lines frames:
    - host writes one request and closes standard input;
    - package writes bounded progress and diagnostic frames;
    - package writes exactly one terminal result or failure;
    - standard output contains protocol frames only;
    - standard error contains bounded unstructured diagnostics only.
18. Put source bytes and package snapshot in a host-created `0700` operation directory.
19. Pass package-relative input and output paths. Do not put PDF bytes, HTML bytes, or unbounded Markdown in JSON.
20. Include request ID, protocol revision, extractor kind, MIME type, original filename, paths, and deadline in the request.
21. Include request ID, warnings, result metadata, and package-reported tool/model metadata in terminal frames.
22. Define stable failure causes for unsupported input, invalid request, missing runtime, setup, timeout, cancellation, process termination, output limit, malformed protocol, and extraction failure.
23. Set named host maxima for manifest size, package files, copied bytes, frame bytes, stderr tail, input, Markdown output, duration, and progress events.
24. Treat cancellation and deadline as host authority.
25. Reject malformed UTF-8 or JSON, request mismatch, path escape, duplicate or missing terminal frames, excess output, and protocol output after termination.

### Selection compatibility

26. Add `ExtractionBackendReference` with built-in and installed cases. This is the persisted, version-free selection domain. `ExtractionAdapterKey` is the exact registry domain. Convert between them only inside logical resolution, never at consumer call sites.
27. Add optional logical `pdfExtractor` and `htmlExtractor` fields to `ExtractionConfig`. Preserve all existing fields and defaults.
28. Define one precedence rule for each extractor kind:
   - when the new logical field is absent, use the legacy `backend` or `htmlBackend` field unchanged;
   - when the new logical field selects a built-in, that explicit selection wins over the legacy field;
   - when the new logical field selects an installed package, a compatible active exact registration wins over the legacy field;
   - when that installed selection is unavailable, preserve it, emit one redacted diagnostic, and block the route. Do not run another extractor.
29. Resolve logical installed references from compatible, active exact plugin registrations. Rank by semantic version, then exact revision identity. Never use install or activation order.
30. Keep all compatible installed revisions mounted. A failed higher version leaves a working lower version available.
31. Keep reviewed local pdf2md when it is the explicit or legacy PDF choice. Keep tag-based extraction when it is the explicit or legacy HTML choice.
32. Keep an unavailable logical selection saved. Report one redacted diagnostic and require recovery or another explicit selection.

## Route selections: typed MIME routes

The Settings routing table needs a stable identity for one default-extraction route. Route identity is a typed pair, `ExtractorRouteID`: an `ExtractorKind` plus a normalized `ExtractorMIMEType`. The type keeps three namespaces distinct — a route is not an extractor kind, not a backend kind, and not a raw MIME string. MIME is authoritative. Filename extensions stay registration matching hints and never enter the persisted route.

The current canonical routes are PDF (`application/pdf`) and HTML (`text/html`). Route identity admits other kind-plus-MIME pairs, and the UI can display them, but execution adapters for new kinds stay separate work. This stack changes no execution path.

`ExtractionConfig.routeExtractors` stores one `ExtractorRouteSelectionRecord` per route as a deterministically sorted array. A string-keyed JSON dictionary was rejected: an array keeps the persisted order canonical and makes duplicate route keys in hand-edited files representable and resolvable.

Precedence for a route:

1. An exact `routeExtractors` record.
2. The bundled default-route record for that route (`default-routes.json`).
3. No selection.

Generic references only. A record names a host adapter, an installed package lineage, or the explicit no-default value. The route supplies the input format; the reference never carries PDF, HTML, or DOCX cases.

One-time migration. The retired `backend`, `htmlBackend`, `pdfExtractor`, and `htmlExtractor` keys are decode-only inputs. The decoder adopts each retired value into the matching route record when no record claims the route, and encode never writes the retired keys again. `routeExtractors` is the sole persisted extractor selection.

Decode resilience. A missing key decodes to an empty list. A malformed record is dropped through the logged decode seam. Duplicate records for one route resolve deterministically: the canonically-greatest record wins, independent of file order, with one bounded diagnostic.

## Route presentation: registration-driven rows

The Settings route table is a pure projection. `ExtractorRouteTableBuilder` builds one row per route from a union of three inputs: host-owned descriptors, active exact registration snapshots, and saved selections. No input re-reads a package manifest or directory — the registry projects each active exact registration's manifest-derived presentation (display name, kinds, MIME types, filename extensions) captured when the trusted definition factory built its batch entries.

Union rules:

- Host descriptors seed the canonical PDF and HTML rows, so both stay visible with zero packages installed.
- Every active exact registration contributes rows for its declared (kind, MIME) pairs. A future registration can add a row without another Settings layout change, but execution adapters for new kinds remain separate work.
- Saved records seed their route even when nothing active backs it. A stale installed selection stays selected and selectable (one unavailable choice in its picker); the row reports what actually resolves.

Ordering and deduplication:

- Rows sort by host order (PDF, then HTML) first, then by typed route order (kind raw value, then MIME raw value).
- Multiple exact versions of one logical registration deduplicate into one choice showing the highest active revision; the package lifecycle rows below the table keep every exact version for inspection and removal.
- Choices order like the pickers they replace: prompt (HTML), reviewed package, installed packages by package ID, connected services, built-ins.
- The reviewed packages attach only to their canonical routes; direct Anthropic and Gemini API choices never appear.

Statuses use a compact typed vocabulary: **Ready**, **Needs setup**, **Not installed**, **Starting**, and **Failed**. A non-ready status opens **Extractor Status** with the cause, blocked-route impact, supported recovery actions, and a redacted diagnostic preview. Settings reports route configuration and lifecycle health. Per-document operation failures remain in Activity.

## Phase 2: Add the trusted dynamic Cordis plugin host

1. Keep `PluginCatalog` immutable and link-time. Do not add dynamic module loading to it.
2. Add `DynamicPluginHost` in `CordisLoader` as a generic trusted-definition lifecycle host. Keep extractor policy in `WikiFSEngine`. The host must not import extractor types or know about extraction preparation.
3. Add separate identities for:
   - stable dynamic plugin definition;
   - immutable definition fingerprint;
   - exact activation run;
   - runtime Cordis component handle.
4. Make each `run` invoke the trusted definition factory again and create a fresh `ComponentDefinition` and `ComponentID`. Definition identity stays stable per package revision. Component identity is unique per activation run.
5. Do not accept source code, package paths, arbitrary config, shared-library names, or package-provided factories in this API.
6. Support these lifecycle operations:
   - `define`: record one immutable trusted definition without activation;
   - `run`: register its component, await settlement, and retain the exact run and handle;
   - `stop`: dispose the component and its definition-declared effects, but retain the definition;
   - `undefine`: stop and remove the definition and retained lifecycle state;
   - `inspect`: return source-free state and diagnostics.
7. Reject a repeated definition ID with a different fingerprint. Treat an identical repeat as idempotent.
8. On run failure, dispose the failed component before returning. Preserve the failed attempt separately from physical component state.
9. Use Cordis staged activation for supplies, effects, and listeners. Preserve generation checks so a late activation cannot commit after stop or replacement.
10. Treat a settled pending component as waiting only when declared host dependencies are absent. It contributes no extractor registration until active.
11. Await component disposal as the generic stop barrier. Put extractor admission closure, preparation drain, and batch withdrawal inside the generated definition’s staged cleanup effect. Keep these operations nonthrowing and method-atomic from Cordis’s perspective. Cordis consumes each cleanup effect once.
12. Mirror `EntryTree`’s commit-then-dispose ownership discipline. Remove active ownership before disposal starts. Never retain a possibly disposed handle as active after a throwing cleanup.
13. Record cleanup anomalies and Cordis cleanup failures as retained diagnostics. Do not claim that repeated stop reruns a consumed disposer. Put any retryable external cleanup in a separate host-owned lease with an explicit retry operation and ownership token.
14. Keep stop and undefine idempotent. A stale run, disposer, or retry lease cannot affect a newer run.
15. Make `run` return a typed outcome: active with run ID, waiting with the same run ID and missing dependencies, or failed with phase diagnostics. Retain one handle for both waiting and later activation.
16. Observe waiting runs by reading handle state and history on dependency changes, catalog wakes, settings refresh, and inspection. Do not call `run` again for a desired definition that already has a waiting run.
17. Add a source-free inspection snapshot with plugin identity, revision fingerprint, run ID, component ID, component state/history, missing dependencies, definition-declared work count, retained run count, last failure phase, cleanup anomalies, and Cordis cleanup failures.
18. Keep host-retained run diagnostics bounded by a named policy. Measure Cordis runtime disposed-record growth during repeated stop and run cycles before proposing runtime-level record eviction.
19. Model diagnostics after DeepSeek Harness run attempts: defined, starting, waiting, active, failed, stopping, stopped, and undefined are distinct states.
20. Add no generic user-facing dynamic plugin loader, VM, JavaScript evaluator, or runtime Swift loader.
21. Add an architecture guard that prevents profile `EntryTree` rows from referencing dynamic definition IDs.

## Phase 3: Build secure package admission and the durable machine catalog

1. Create `ExtractorPackageStoreLayout` at `extractors/v1/` under the App Group. Include package, staging, derived-index, and operation roots.
2. Store exact package ID and version as immutable bytes. Reject a different digest for an existing identity.
3. Accept one local directory only. Reject files, archives, URLs, and remote sources.
4. Copy into fresh staging without following links. Validate only the staged copy.
5. Apply the renderer validator’s secure-copy rules:
   - reject absolute paths and parent traversal;
   - reject symlinks, hard links, devices, sockets, and FIFOs;
   - reject filesystem-boundary changes;
   - reject normalized and case-folded collisions;
   - detect identity, metadata, or mode changes during copy;
   - enforce file and byte limits;
   - reject missing and undeclared files;
   - verify each digest and package digest.
6. Factor low-level secure-copy code only when renderer behavior and errors stay unchanged. Run the complete renderer validator suite before and after.
7. Make the app the only catalog writer. Only the app imports, bootstraps, repairs, recovers staging, publishes generations, and removes packages.
8. Make daemon catalog APIs read-only. Reject daemon mutation in production composition.
9. Serialize app writes through one actor and a store lock that excludes stale app writers after restart.
10. Atomically move validated staging to its final immutable location, then publish the index generation.
11. Recover a moved-but-unpublished package by validating and publishing it or removing it before another mutation.
12. Publish removal before deleting package bytes. Recovery removes unreferenced package directories.
13. Use a versioned index with generation checks and durable atomic replacement. Store exact revision, registrations, capabilities, install time, and bounded redacted admission diagnostics.
14. Let readers observe a complete old or new generation. Correctness does not depend on wake delivery.
15. Before execution, copy the exact revision into a private operation snapshot and revalidate it.
16. Let both app and daemon use exact reviewed bundled revisions when the machine index lacks them. Each process verifies compiled expected identity and digest. Only the app publishes them.
17. Keep local imports unavailable to the daemon until the app publishes them.
18. Clean app-owned staging and operation roots after all terminal paths and startup recovery. The daemon cleans only its operation roots.
19. Add real multiprocess helpers for app-writer exclusion, rejected daemon mutation, concurrent daemon read, failed publication, orphan recovery, daemon-before-bootstrap reviewed execution, removal during preparation, and writer crash recovery.
20. Keep package files, records, and selections out of wiki SQLite and File Provider projections.
21. Add `ExtractorPackageToolCore` and `extractor-package-tool` for validation, digest output, and protocol fixture smoke tests.

## Phase 4: Add the process capability and process-backed adapter

### Managed process execution

1. Add a narrow `ManagedProcessExecuting` host service.
2. Resolve a direct entry point beneath the validated operation snapshot.
3. Resolve runtime commands against a host-owned immutable search list, including mise shims, before spawn. Launch an absolute executable URL and do not rely on child PATH lookup.
4. Separate launch requirements from behavioral capabilities.
5. Always provide deterministic locale, operation-private `HOME`, package-private temporary/cache directories, and request correlation values.
6. Grant shared runtime or model caches only through matching capabilities.
7. Never inherit credentials, API tokens, provider secrets, wiki database paths, unrelated environment values, or the parent environment wholesale.
8. Keep Bun and uv optional. A missing runtime returns a typed failure. An explicitly selected package does not cause another extractor to run.
9. Treat runtime executables as user-account-trusted dependencies, not digest-verified package bytes. Keep the ordered resolution locations immutable in host policy, but do not describe user-writable mise shims as immutable executables. Resolve through mise-managed execution paths where practical. Record the absolute runtime path and pre-spawn file identity in bounded diagnostics, then recheck identity immediately before spawn.
10. Extend or replace `AsyncProcessRunner` with:
   - standard-input data and deterministic EOF;
   - continuous frame decoding;
   - bounded standard error;
   - separate output limits;
   - deadline and cooperative cancellation;
   - typed exit and signal cause;
   - exactly-once completion;
   - no blocking wait, semaphore, sleep, or unbounded continuation.
11. Start each extractor in a separate process group with `posix_spawn` and `POSIX_SPAWN_SETPGROUP`, or an equivalent race-free primitive.
12. On cancellation or timeout, verify child identity, send `TERM` to the owned group, wait a named grace period, then send `KILL` to the same verified group.
13. Keep pure signal targeting in the existing safe seam. Tests signal fixture processes only.
14. Use structured concurrency for pipe drains, timeout, completion, and cancellation.
15. Log request ID, exact revision, digest prefix, protocol revision, duration, byte counts, and exit cause through `DebugLog.extraction`. Do not log content, full paths, environment values, credentials, or unbounded stderr.

### Process-backed adapter and operation lifetime

1. Add `ProcessExtractorProvider` for one exact validated revision and managed process service.
2. Adapt registrations to existing PDF and HTML extraction surfaces. Package scripts do not conform to Swift protocols.
3. Translate protocol progress to existing queue and UI callbacks.
4. Map process and protocol failures to typed extraction failures. Do not substitute another extractor after explicit package selection.
5. During adapter preparation:
   - verify the plugin activation token is still admitted;
   - verify the exact revision remains in the authoritative catalog or reviewed overlay;
   - create and revalidate the private package snapshot;
   - check admission again before returning the prepared operation.
6. Track only preparation work in the package plugin’s admission gate. A prepared operation owns its snapshot independently and may finish after plugin stop or package removal.
7. On full extraction-context shutdown, stop new preparations, dispose package plugins, then cancel and await all managed operations before disposing the executor.
8. Return exact revision, digest, protocol revision, tool/model metadata, and technique as immutable execution provenance.
9. Make readiness validate package and runtime without downloading models or starting extraction.
10. Add a fixture extractor executable for success, progress, malformed output, excess output, nonzero exit, signal handling, child spawning, timeout, and cancellation.

## Phase 5: Reconcile durable revisions into one process-scoped extraction graph

### Composition authority

1. Make each app or daemon process profile own exactly one extraction context. That context owns `ExtractionBackendRegistry`, `DynamicPluginHost`, `ExtractorPackagePluginReconciler`, package catalog reader, managed process executor, built-in adapters, and the public `ExtractionServices` facade.
2. Remove the per-wiki `wiki.extraction` and `wiki.extraction.pdf2md` ownership rows from `bundles/wikifs-base/cordis.patch.yml`, or replace them with a consumer that resolves the inherited process facade without supplying another registry. Opening more wikis must not create more package activations.
3. Collapse `ExtractionRuntimeFactory` onto the process extraction context. It must not create a private competing `CordisContext` or manual backend resolver after migration.
4. Keep `MutableExtractionServices` as the stable process facade installed by `ProcessRuntimePlugins.extractionDefinition`. `ExtractionCompositionOwner` owns that same process graph and its reconciler lifecycle. Queue workers, app direct UI, daemon workloads, and per-wiki runtime services resolve the same registry-backed facade instance within their process.
5. Update `ProcessCompositionInputs`, `ProcessServiceKeys`, `ProductionPluginCatalogs`, profile bundle rows, and boot tests together. Preserve dependency-order independence.
6. Define CLI scope explicitly. Revision 1 CLI profiles can use exact reviewed bundled Defuddle and pdf2md revisions only. They do not reconcile local imported packages or become catalog writers. If a CLI path observes an unavailable installed logical selection, it emits one redacted diagnostic and fails closed.
7. Add composition identity tests that open two wiki profiles and prove one process registry/reconciler/package activation set, while app and daemon still own different registry instances. Prove app direct UI and queue extraction resolve the same package adapter through the same process registry.

### Generated plugin definition

1. Add `ExtractorPackagePluginDefinitionFactory` in `WikiFSEngine`.
2. Generate one deterministic Cordis `PluginID` per `ExtractorPackageRevisionID`. Keep the raw external package ID separate from Cordis identity encoding.
3. Fingerprint the definition with the exact revision, supported protocol, normalized registrations, and fixed host dependency contract.
4. Each generated definition declares only fixed host-owned dependencies:
   - `ExtractionServiceKeys.backends`;
   - extractor catalog reader;
   - managed process executor;
   - package preparation and diagnostics services.
5. Revalidate the exact package source during activation. Do not start the script or download dependencies.
6. Construct all process-backed registration factories before mutating the registry.
7. Replace the string-only package key path with a typed `ExtractionAdapterKey` that has distinct built-in and installed cases. The installed case contains extractor kind plus exact `ExtractorReference`, including revision and registration. Preserve the existing built-in raw values only at configuration boundaries.
8. Add exact registry lookup by `ExtractionAdapterKey`. Add a separate kind-filtered query by `LogicalExtractorReference` that returns compatible active exact registrations for deterministic semantic-version and revision-identity ranking.
9. Keep reviewed package registrations in the installed namespace. Map legacy `localPdf2md` and Defuddle configuration values through compatibility adapters to the reviewed logical references. Do not reuse built-in keys for reviewed package revisions.
10. Add `ExtractionBackendRegistry.registerBatch`:
   - derive one revision-qualified exact key for each declared registration;
   - validate every registration and collision before commit;
   - commit all registrations atomically;
   - return one batch handle with exact activation token;
   - remove only registrations owned by that token;
   - make stale disposal a no-op.
11. If batch ownership cannot be attached as a staged Cordis effect, dispose the batch explicitly before activation throws.
12. Make the plugin effect close preparation admission, await preparation quiescence, and dispose the batch in defined order.
13. A package plugin can register extractor adapters only. It cannot supply arbitrary Cordis services, tools, events, listeners, or package-defined dependencies.

### Catalog reconciler

1. Add one `ExtractorPackagePluginReconciler` actor per extraction context.
2. Read an immutable machine catalog generation and merge exact reviewed bundled revisions as a host-owned overlay.
3. Ignore stale generation notifications. Read authoritative state on startup, wake, settings refresh, and before logical resolution when the observed generation is uncertain.
4. Build and validate all desired host definitions before lifecycle mutation.
5. Reconcile each exact revision independently so one failed package cannot block unrelated packages.
6. For a desired revision:
   - define it idempotently;
   - run it if stopped;
   - expose it for selection only after active settlement and batch registration.
7. For an undesired revision:
   - remove it from selection immediately through the authoritative catalog gate;
   - stop it to preparation quiescence;
   - execute each Cordis cleanup effect once;
   - undefine retained host state after physical disposal;
   - preserve cleanup anomalies for inspection without restoring admission or claiming a consumed disposer was retried;
   - retry only separately modeled external cleanup leases that still own a concrete resource and exact token.
8. Keep older active revisions when a new revision fails. Logical selection chooses the highest compatible active revision.
9. Never replace one live revision in place. A changed version or digest has a new exact definition identity.
10. Preserve failed activation attempts and current active revisions separately in inspection.
11. Use payload-free cross-process wakes only as hints. App and daemon contexts own separate hosts, run IDs, handles, and reconciliation status.
12. Do not share `ComponentHandle`, activation tokens, process leases, or mutable reconciler state across processes.
13. Add source-free package inspection for desired catalog generation, observed generation, exact revision, plugin/run state, registrations, missing dependencies, preparation count, last failure phase, and cleanup failure.

### Single extraction authority

1. Make `ExtractionBackendRegistry` the only adapter authority for built-in and package extractors.
2. Register built-in adapters through static Cordis plugins and installed revisions through generated Cordis plugins.
3. Update `ExtractionRuntimeFactory` to resolve through the registry. Remove its manual backend-construction switch after parity tests pass.
4. Preserve one immutable configuration and credential snapshot per preparation.
5. Extend `ExtractionServices` with kind-aware typed preparation. Keep the existing PDF override method as a compatibility adapter.
6. Route explicit HTML extraction through `ExtractionServices`. Remove direct Defuddle construction at consumer sites.
7. Keep transcript adapters static and outside package revision 1.
8. Thread typed execution provenance through app and daemon queue providers.
9. Reject package-specific switches outside definition factory, reconciler, and process provider.

## Phase 6: Migrate Defuddle and pdf2md into reviewed package plugins

### Reviewed resources

1. Add `ExtractorPackages/Defuddle/` and `ExtractorPackages/Pdf2md/` with manifests, protocol entry points, declared assets, licenses, provenance, and pinned digests.
2. Add an `extractor-packages` sync and validation command. Fail on unintended drift.
3. Make it a prerequisite of `make build`, `make check`, and `make test`. Document the prerequisite for bare SwiftPM commands.
4. Put identical reviewed package resources where both app and signed `wikid.xpc` can resolve them. Validate final signed bundle layouts.
5. Feed reviewed revisions through the same generated plugin factory and reconciler as installed revisions.
6. Let the app bootstrap reviewed revisions into the machine store. Let both processes use separately verified bundled revisions until publication succeeds.
7. Resolve a reviewed package only when it is the explicit or legacy choice. Never use it to replace an unavailable third-party selection.

### Defuddle

8. Create one reviewed Bun protocol entry point with pinned Defuddle library code. Do not wrap a second Defuddle CLI process.
9. Preserve article extraction, metadata, empty-content failure, progress, diagnostics, and explicit tag-based extraction.
10. Update `tools/defuddle/README.md` with generation, provenance, and protocol tests.
11. Remove path probing and package-specific process ownership from `DefuddleExtractionService` after all callers use the package plugin.

### pdf2md

12. Keep `convert_pdf` decorated with `@beartype`. Preserve the human CLI, PEP 723 metadata, and exit codes.
13. Add protocol mode to `tools/pdf2md/pdf2md` with progress frames and file-based Markdown output.
14. Keep PEP 723 and `pyproject.toml` dependencies synchronized.
15. Preserve readiness, dependency and model setup, progress, and cancellation.
16. Remove package-specific process ownership from `PdfExtractionService` after queue, UI, shutdown, and fail-closed coverage passes.
17. Map old built-in local pdf2md and Defuddle choices to reviewed logical package registrations.
18. If bootstrap or index preparation fails, run the exact reviewed bundled revision through its generated package plugin in both app and daemon contexts.
19. Never activate an unexpected reviewed identity or resolve another extractor through an unavailable third-party reference.

## Phase 7: Add package selection, trust, lifecycle, and inspection UI

1. Extend `ExtractionSettingsView` with built-in and installed PDF and HTML choices.
2. Persist logical installed selections. Show the resolved exact revision and plugin state without rewriting the logical choice.
3. Add “Advanced Local Extractor Package Import.” Accept one directory and reject files and archives at picker and store boundaries.
4. Show this warning before import: installing an extractor package authorizes executable code to run on this Mac. State that Cordis lifecycle and capabilities do not create a security sandbox.
5. Show package name, versions, exact digest, registrations, capabilities, runtime, validation state, and redacted diagnostics.
6. Show Cordis lifecycle states with user terms such as Available, Waiting for Host Service, Failed to Activate, Stopping, and Removing. Keep raw IDs and detailed run history behind disclosure. `Stopped` is an internal/transient inspection state after disposal, not a user-persisted disable setting in revision 1.
7. Add removal with confirmation. Removal is the only user action that stops an installed revision in revision 1. Preserve sources and logical selections. State that a selected route stays blocked until the user chooses another extractor.
8. Add readiness per registration. It must not download a model without a separate explicit action.
9. Keep forms compact and use progressive disclosure.
10. Use semantic text styles, system colors, and standard controls. Give each import, selection, readiness, and removal control a stable accessibility identifier, accessible name, state value where applicable, and keyboard path.
11. Add hosted accessibility-contract tests for labels, values, identifiers, focusable controls, and key equivalents. Add a manual VoiceOver smoke script for spoken announcements and focus order because the repository has no VoiceOver automation harness.
12. Keep asynchronous model mutations on the main actor. Do not write SwiftUI state synchronously from representable updates.

## Phase 8: Persist exact package provenance without a schema migration

1. Add `.installedPackage` to `ExtractionProducer` with exact revision, registration, protocol revision, and package-reported tool/model metadata.
2. Keep `ExtractionActivityPlan.currentVersion` at 1. Extend its tagged producer payload additively.
3. Decode all existing version 1 backend, tool, and legacy producers plus pre-versioned `{ backend, model }` data unchanged.
4. Replace closed producer decoding with a tolerant producer envelope. Decode outer version-1 fields independently, inspect producer `kind` as a raw string, decode known payloads, and map an unknown kind or malformed installed-package payload to a missing producer while preserving valid origin, provider, model, source-version, tool-version, and note fields. Keep unsupported outer plan versions as errors and use normalized-column fallback for missing producer data.
5. Keep `activities`, `agents`, and `source_markdown_versions` columns unchanged.
6. Use a stable compatibility technique in existing text columns. The tagged plan is authoritative for exact identity.
7. Extend `ExtractionProvenance` and extraction alternatives with package name, version, registration, and digest prefix. Do not label package versions as models.
8. Define the `GRDBWikiStore.appendDerivedMarkdown` field matrix for `.installedPackage`: allow exact package identity, registration, protocol, tool version, and package-reported model metadata. Forbid `providerID` because the package is not a provider-backed producer. Reject all other incompatible combinations with typed errors.
9. Remove queue and persistence assumptions that every byte extractor is an `ExtractionBackend`.
10. Store no package content, source content, environment value, activation diagnostics, or unbounded stderr in provenance.

## Phase 9: Documentation, cleanup, and release gates

1. Add `docs/architecture/extractor-script-protocol.md` as the normative protocol reference.
2. Add `docs/architecture/extractor-package-manifest.md` as the normative package and digest reference.
3. Add `docs/architecture/dynamic-extractor-cordis-lifecycle.md` for durable-catalog reconciliation, generated plugin identity, activation, stop, undefine, inspection, operation pinning, and app/daemon independence.
4. Add `docs/user-guide/extractor-packages.md` for import, selection, trust, lifecycle states, fail-closed recovery, runtime setup, diagnostics, and removal.
5. Cross-link renderer packages without claiming a shared execution or security model.
6. Update `docs/user-guide/README.md`, `README.md` where needed, `PLAN.md`, `plans/architecture.md`, `plans/cordis-extraction-services.md`, `plans/mise-toolchain.md`, and tool READMEs.
7. Add `docs/skills/extractor-package-maintainer/SKILL.md` with manifest, validation, protocol, capability, reviewed-package, and lifecycle-inspection references.
8. Use `ste-writing` for changed prose.
9. Delete compatibility adapters only after all production consumers use registry-resolved package plugins.
10. Run architecture audits which prove:
    - package scripts do not enter the Swift process;
    - package code never receives `CordisContext`;
    - runtime definitions come only from the trusted host factory;
    - `PluginCatalog` remains static and link-time;
    - packages cannot register arbitrary Cordis services or tools;
    - no shell execution exists;
    - no package payload enters wiki storage or File Provider;
    - no second extraction resolver or package switch remains.
11. Run `python3 tools/validate_skills.py`, schema fixtures, reviewed digests, protocol smoke tests, and dynamic plugin lifecycle tests.
12. Run Python formatter, Ruff, Pyright, and pytest from `tools/pdf2md`.
13. Run the real Defuddle package fixture through mise-managed Bun.
14. Run `make build`, `make test`, required opt-in app tests, and bare `swift build` and `swift test` after package-resource sync.
15. Run scoped mutation testing for manifest normalization, digest, selection, protocol state, registry batch ownership, and reconciler generation logic when available.
16. Use Conventional Commits. Push only the feature branch and open or update PRs. The operator owns every merge decision.

# Acceptance Criteria

- **AC.1:** Extractor lineage, revision, registration, logical reference, exact reference, plugin run, request, renderer, and Cordis runtime identities cannot be interchanged.
- **AC.2:** Manifest revision 1 deterministically validates and hashes package bytes, normalizes modes, and rejects unsupported revisions, paths, files, capabilities, duplicates, and limits.
- **AC.3:** Local import validates staged bytes, atomically installs an immutable revision, rejects identity replacement, and recovers staging, orphan, and operation state.
- **AC.4:** Package files and records remain machine-scoped. No wiki database, queue/XPC payload, or File Provider projection contains package payload.
- **AC.5:** Protocol revision 1 accepts one request, bounded events, and one terminal frame. It rejects malformed, mismatched, escaped, duplicate, missing, or excess output.
- **AC.6:** Managed execution uses no shell, resolves an absolute executable, sends EOF, bounds output, enforces deadlines, propagates cancellation, and terminates the verified process group.
- **AC.7:** A package receives only its private operation files and allowed environment. It receives no credentials, database paths, parent environment, or unauthorized shared cache.
- **AC.8:** `DynamicPluginHost` implements trusted define, run, stop, undefine, failed-run cleanup, generation safety, idempotence, quiescence, and source-free inspection without dynamic code loading.
- **AC.9:** Each exact validated package revision is one host-generated Cordis plugin. Package scripts never provide plugins, register arbitrary Cordis services, receive context, or run in-process.
- **AC.10:** Each process reconciles durable catalog generations independently. One failed package does not block others, a failed new version leaves older versions available, stale generations cannot restore removed admission, and app/daemon handles never cross processes.
- **AC.11:** One package plugin activates all declared extraction registrations atomically. Failed activation rolls back all registrations, and a stale batch disposer cannot remove a newer registration.
- **AC.12:** `ExtractionBackendRegistry` is the sole adapter authority for built-in and package PDF/HTML extraction. `ExtractionRuntimeFactory` has no manual second resolver.
- **AC.13:** Legacy defaults and explicit built-in choices remain compatible. An unavailable explicit installed selection stays selected and fails closed in app and daemon preparation.
- **AC.14:** Defuddle runs as a reviewed generated package plugin and preserves article extraction, metadata, empty-content behavior, and explicit tag-based selection.
- **AC.15:** pdf2md runs as a reviewed generated package plugin while preserving `convert_pdf`, CLI, PEP 723, readiness, setup, progress, and cancellation.
- **AC.16:** Settings can import, inspect, select, check readiness, and remove packages with executable-code warning and accessible native controls. Removal shows stopping/removing progress; revision 1 has no persistent Stop/Start control.
- **AC.17:** A prepared extraction pins one exact validated snapshot and provenance. Plugin stop, package removal, or catalog refresh cannot change or terminate that operation, while full context shutdown cancels it.
- **AC.18:** Activity plan version 1 stores exact package revision, registration, protocol, and tool/model metadata. Existing and unknown producers retain compatible fallback without SQLite migration.
- **AC.19:** Logs and inspection identify catalog generation, package revision, activation run, operation, failure phase, and cleanup state without content, credentials, full paths, environment values, or unbounded stderr.
- **AC.20:** Package tools and documentation support validation, digest computation, protocol smoke testing, lifecycle inspection, reviewed-package updates, and the full exact-head release gate.

# Test Strategy

Use Swift Testing for new Swift suites. Mark subprocess, signed-service, and multiprocess suites `.serialized` with named `.timeLimit` traits. Never use `waitUntilExit`, `Thread.sleep`, semaphore waits, or unbounded continuations.

| Acceptance criterion | Named regression tests and checks |
| --- | --- |
| AC.1 | `ExtractorIdentifierBoundaryTests.testAllNamespacesRemainDistinct`; compiler fixtures under `Tests/WikiFSTests/Fixtures/`; existing renderer and Cordis identity tests. |
| AC.2 | `ExtractorManifestTests.testCanonicalDigestIsStable`; invalid revision/path/capability/limit corpus; `ExtractorManifestModeTests.testDirectEntryRequiresExecutableSourceMode`; installed/snapshot mode normalization and drift tests. |
| AC.3 | `ExtractorDirectoryValidationTests` adversarial filesystem matrix; `ExtractorPackageStoreTests.testImmutableIdentityRejectsDifferentDigest`; real multiprocess writer exclusion, publication failure, orphan reconciliation, and crash recovery tests. |
| AC.4 | `ExtractorPackageStoreLayoutTests.testStoreIsMachineScoped`; `ExtractorQueuePayloadCompatibilityTests.testPackagePayloadIsNotEncoded`; `ExtractorXPCPayloadCompatibilityTests.testPackagePayloadIsNotEncoded`; `ExtractorWikiWriterIsolationTests.testPackagePayloadIsNeverPersisted`; `ExtractorFileProviderProjectionTests.testPackagePayloadIsNeverProjected`; fresh-schema parity; supplementary architecture audit. |
| AC.5 | `ExtractorScriptProtocolTests.testValidProgressAndResultRoundTrip`; parameterized malformed, mismatch, traversal, duplicate/missing terminal, frame, progress, and output limit tests. |
| AC.6 | `ExtractorProcessRunnerIntegrationTests.testInputEOFSucceeds`; absolute runtime pinning; direct-mode pre-spawn check; timeout/cancellation process-group tests; exactly-once completion; opt-in `SignedWikiDExtractorLaunchTests.testProductionServiceSpawnsExchangesAndCancelsFixture`. |
| AC.7 | `ExtractorProcessEnvironmentTests.testOnlyAllowedEnvironmentIsVisible`; credential/database absence; private HOME/cache; shared-cache authorization; capability implication tests. |
| AC.8 | `DynamicPluginHostTests.testDefineDoesNotRun`; `testRunSettlesAndRecordsExactRun`; `testEachRunCreatesFreshComponentIdentity`; `testWaitingRunBecomesActiveWhenDependencyAppearsWithoutNewRun`; `testFailedRunDisposesComponent`; `testStopReachesQuiescenceAndRetainsDefinition`; `testRepeatedStopDoesNotClaimConsumedCleanupReran`; `testUndefineRemovesDefinition`; `testLateActivationCannotCommit`; `testConflictingFingerprintIsRejected`; `testInspectionContainsNoDefinitionSource`; `testRetainedRunDiagnosticsStayWithinPolicy`; `testStopRunChurnReportsDisposedRecordGrowth`. |
| AC.9 | `ExtractorGeneratedPluginBoundaryTests.testOneRevisionProducesOneTrustedPlugin`; `testManifestCannotDeclareCordisDependenciesOrRegistrations`; `ExtractionCompositionBoundaryTests.testScriptNeverReceivesContextOrRunsInProcess`. |
| AC.10 | `ExtractorPluginReconcilerTests.testReconcilesCatalogGeneration`; `testOneFailedRevisionDoesNotBlockOthers`; `testFailedHigherVersionLeavesLowerVersionAvailable`; `testSameLineageVersionsRemainActiveAndRankDeterministically`; `testStaleGenerationCannotRestoreAdmission`; `testRemovalClosesAdmissionBeforeCleanup`; `testReconcileDoesNotDuplicateWaitingRun`; `testIndependentAppAndDaemonHostsShareNoHandles`; real daemon-before-bootstrap and concurrent publication scenarios. |
| AC.11 | `ExtractionBackendRegistryBatchTests.testBatchCommitsAtomically`; `testSameLineageRevisionsUseDistinctExactKeys`; `testLogicalQueryReturnsBothCompatibleRevisions`; `testCollisionCommitsNothing`; `testActivationFailureRollsBackBatch`; `testStaleBatchDisposerCannotRemoveNewerToken`; `testPluginStopWaitsForPreparationQuiescence`. |
| AC.12 | `ExtractionRuntimeFactoryTests.testRegistryIsSingleResolverForBuiltInAndPackageAdapters`; `ExtractionCompositionIdentityTests.testTwoWikiProfilesShareOneProcessRegistryAndReconciler`; `testAppUIAndQueueResolveThroughSameProcessRegistry`; `testAppAndDaemonUseDifferentProcessRegistries`; `ExtractionBackendAuthorityAuditTests.testNoSecondConstructionSwitch`; built-in and consumer-call-site exhaustiveness tests. |
| AC.13 | Existing extraction, queue, HTML, plugin, runtime, and transcript suites; legacy-default and explicit-built-in selection tests; `ExtractionConfigTests.unavailableExplicitSelectionResolvesAsUnavailable`; fail-closed PDF and HTML preparation tests; reviewed Docling lineage tests; app and daemon process-service parity. |
| AC.14 | `DefuddleExtractorPackageTests.testReviewedIdentityAndGeneratedPlugin`; article fixture, metadata, empty content, protocol progress, explicit tag-based selection, and fail-closed package failure tests. |
| AC.15 | `PdfExtractorPackageTests.testReviewedIdentityAndGeneratedPlugin`; Python protocol success, progress, setup, and empty-output tests; CLI and API compatibility; package cancellation and fail-closed tests. |
| AC.16 | `ExtractionSettingsPackagePickerTests.testAcceptsOneDirectoryOnly`; `ExtractionSettingsPackageHostedTests.testLogicalSelectionSurvivesUnavailableRevision`; `testImportDisclosureShowsExecutableCodeWarning`; `testLifecycleDetailsAndRemovalProgressAreVisible`; `testReadinessDoesNotDownloadModels`; `testImportControlsHaveAccessibilityLabelsAndKeyEquivalents`; `testLifecycleControlsExposeAccessibleNamesAndValues`. Run a manual VoiceOver smoke test for import, selection, readiness, and removal because hosted tests validate the accessibility contract but cannot validate spoken announcements. |
| AC.17 | `InstalledExtractorSnapshotTests.testPluginStopDoesNotChangePreparedOperation`; `testRemovalDoesNotChangeSnapshotOrProvenance`; `testCatalogRefreshAffectsOnlyFuturePreparation`; `testFullContextShutdownCancelsManagedOperation`; real multiprocess removal-during-preparation scenario. |
| AC.18 | `ExtractionActivityPlanCodecTests.testVersion1InstalledPackageRoundTrips`; existing v1 and legacy fixtures; `testUnknownProducerPreservesAllOuterFields`; parameterized malformed-installed payload tests that preserve every valid outer field; `ExtractionWriterContractTests.testInstalledPackageAllowsToolAndReportedModelMetadata`; `testInstalledPackageRejectsProviderID`; parameterized incompatible-field rejection tests; normalized-column fallback and projection tests. |
| AC.19 | `ExtractorPluginInspectionTests.testStateAndFailureCorrelation`; `testSourceAndSecretsAreAbsent`; `ExtractorDiagnosticsTests.testRedactionAndBounds`; `testOneShotCleanupAnomalyRemainsVisibleWithoutFalseRetry`; cleanup failure and stale-run diagnostics tests. |
| AC.20 | `ExtractorPackageToolCoreTests`; subprocess CLI tests; documentation command tests modeled on renderer packages; `python3 tools/validate_skills.py`; exact-head gate log. |

Run focused compatibility groups during their owning phases:

1. `swift test --filter DynamicPluginHostTests`
2. `swift test --filter ExtractionPluginBootTests`
3. `swift test --filter ExtractionRuntimeFactoryTests`
4. `swift test --filter ExtractionCompositionOwnerTests`
5. `swift test --filter QueueExtractionTests`
6. `swift test --filter ExtractionActivityPlanCodecTests`
7. `swift test --filter ExtractionWriterContractTests`
8. `swift test --filter ExtractionProvenanceProjectionTests`
9. `swift test --filter RendererDirectoryValidationTests` after shared secure-copy changes
10. required opt-in `WikiFSAppTests` for Defuddle, pdf2md, settings, and signed XPC
11. `mise exec -- uv run` formatter, Ruff, Pyright, and pytest gates from `tools/pdf2md`
12. mise-managed Bun against the reviewed Defuddle package fixture

# Review Strategy

Run the `plan-reviewer` before handoff. Fix or rebut every finding. Repeat review after any critical or high correction.

During implementation, follow repository review guidance and `review-model-diversity`. Use a lower-power subagent for bounded implementation or test work.

After automatable tests pass, request:

1. A general implementation review from a different model family.
2. A Cordis lifecycle review focused on identity, staged activation, generation safety, stop/undefine, failure isolation, and cleanup.
3. A Swift concurrency review focused on reconciler actors, preparation gates, pipe drains, cancellation, and shutdown ordering.
4. A security review focused on package copying, digest authority, runtime resolution, environment, process groups, and redaction.
5. A SwiftUI/macOS review focused on trust wording, lifecycle state, keyboard access, VoiceOver, and error/progress presentation.
6. A Swift Testing review focused on deterministic plugin lifecycle, subprocess limits, signed-service gates, and real multiprocess fixtures.
7. A prose review with `ste-writing`.

Fix or explicitly rebut all findings. Repeat relevant reviews after critical fixes. Do not report readiness with a critical finding open.

# Documentation Strategy

Create:

- `plans/dynamic-extractor-packages.md` for the complete design and phase evidence;
- `docs/architecture/extractor-script-protocol.md` for protocol revision 1;
- `docs/architecture/extractor-package-manifest.md` for manifest, digest, modes, capabilities, and compatibility;
- `docs/architecture/dynamic-extractor-cordis-lifecycle.md` for durable catalog versus process graph, generated definition identity, reconciliation, activation, stop, undefine, inspection, failure isolation, and operation pinning;
- `docs/user-guide/extractor-packages.md` for import, selection, trust, lifecycle, fail-closed recovery, runtime setup, diagnostics, and removal;
- `docs/skills/extractor-package-maintainer/SKILL.md` and focused references;
- machine-readable schema and fixture corpus.

Update:

- `PLAN.md`;
- `plans/architecture.md`;
- `plans/cordis-extraction-services.md`;
- `plans/mise-toolchain.md`;
- `docs/user-guide/README.md`;
- `docs/user-guide/renderer-packages.md` with a cross-link only;
- repository `README.md` where needed;
- `tools/defuddle/README.md`;
- `tools/pdf2md/README.md` and script docstring;
- phase records under `progress/`.

State consistently:

- each exact package revision has a host-generated Cordis plugin;
- package code is not a Cordis plugin implementation and never receives context;
- the static `PluginCatalog` remains link-time;
- Cordis controls host registration and lifecycle, not OS isolation;
- package capabilities cannot request arbitrary Cordis services;
- the durable machine catalog is authoritative;
- app and daemon reconcile independent process-local graphs;
- package import is local-directory-only and machine-scoped;
- Bun and uv remain optional;
- an unavailable explicit extractor selection stays selected and fails closed;
- package bytes never enter a wiki or File Provider.

# Risks, Blockers, and Required Decisions

No product decision blocks the plan. Phase 0 contains one hard feasibility gate. The signed production `wikid.xpc` must resolve reviewed package bytes, create the private operation layout, exchange protocol frames, and terminate a verified fixture process group. Existing daemon subprocess launch and App Group access are established precedents. Failure in a new boundary requires an operator architecture decision before Phase 1.

The plan fixes these design decisions:

- each exact validated package revision is one host-generated Cordis plugin;
- package lineage, immutable revision, and activation-run identities are separate;
- multiple compatible revisions can remain active;
- logical selection chooses the highest compatible active revision;
- the durable machine catalog, not Cordis state, is authoritative;
- the static `PluginCatalog` remains immutable;
- a separate trusted dynamic host mounts only host-generated definitions;
- package scripts remain external and context-free;
- package plugins contribute only extraction registrations;
- app and daemon reconcile independently;
- plugin stop closes new preparation and waits for preparation quiescence;
- prepared operations own snapshots independently and survive plugin stop/removal;
- full context shutdown cancels managed operations;
- packages are machine-scoped and local-directory-only;
- revision 1 supports PDF and HTML one-shot processes;
- capability declarations are not a sandbox;
- exact provenance extends activity plan version 1 without schema migration.

Known execution risks:

1. **Dynamic host scope:** A generic runtime code loader would be unsafe and unnecessary. Keep `DynamicPluginHost` restricted to trusted in-memory `PluginDefinition` values and immutable fingerprints.
2. **Lifecycle versus operation lifetime:** Cordis stop must reach registration/preparation quiescence without killing already prepared operations. Full context shutdown has different cancellation semantics. Test both explicitly.
3. **Catalog convergence:** App and daemon can observe generations at different times. Every preparation must recheck authoritative exact revision membership so stale process-local registration cannot admit removed code.
4. **Failure isolation:** One malformed revision must not block unrelated packages or a working lower revision. Reconcile exact revisions independently and retain failed attempts for inspection.
5. **Stale ownership:** Old activation effects must not remove newer registry contributions. Use exact batch tokens and generation checks.
6. **Process-tree control:** Foundation `Process` cannot create a race-free process group alone. Implement the `posix_spawn` boundary before trusting timeout cleanup.
7. **Shared validator refactor:** Keep reusable copy primitives narrow and run complete renderer tests.
8. **App/XPC resources:** Verify identical reviewed bytes in final signed app and XPC bundles.
9. **Optional runtimes:** Core gates cannot require Bun, uv, Docling, or model downloads. Use fixture executables for core tests and separate mise integration gates.
10. **Version accumulation:** Multiple active revisions increase graph size. Activation starts no script and holds only immutable descriptors and registry factories. Add bounded inspection and measure before adding eviction policy.
11. **Trust wording:** Do not let “Cordis plugin” imply a sandbox. Keep the executable-code warning adjacent to import.
12. **Accessibility validation:** Hosted tests can verify labels, values, identifiers, focusability, and key equivalents. They cannot verify VoiceOver speech or focus order. Run and record the manual VoiceOver smoke script before release.
13. **Provenance compatibility:** Do not force package identity into closed `ExtractionBackend`. Keep typed execution provenance end to end.
13. **Working tree:** Leave the unrelated untracked `mise.lock` untouched.

## Issue #1159 — manifest/protocol revision 2 and credential authorization

Implemented on top of this plan (see
[`plans/credential-service.md`](plans/credential-service.md) for the full
design):

- **Manifest revision 2** adds registration-scoped credential requirement
  declarations (`id`/`kind`/`optional`/`label`/`purpose`). Revision 1
  decoding, canonical JSON, and package digests are unchanged; revision 1
  rejects the new key outright. Requirement IDs are unique across the whole
  manifest, so package lineage + requirement ID is an unambiguous
  authorization identity.
- **Protocol revision 2** adds optional RELATIVE request paths for a private
  credential input file and a public operation-configuration file. Values
  never ride stdin JSON or environment variables. Revision 1 requests keep
  their exact old shape.
- **Authorization** binds one package lineage + one requirement to one
  credential reference, pinned to a fingerprint of the normalized contract.
  A newer revision inherits the grant only while the fingerprint is
  unchanged; Settings states this rule before approval. The app is the only
  writer; the daemon reads the same bindings. Removing a package never
  deletes a grant.
- **Per-operation injection:** every execute rechecks admission, catalog
  membership, authorization, and values; the request-scoped 0400 credential
  file lives inside the private operation root and is deleted on every
  terminal path; package-controlled strings are redacted through the
  request's values before reaching host diagnostics or UI.
- **Reviewed Docling Serve package** (`org.selfdrivingwiki.docling-serve`,
  manifest/protocol revision 2) replaces the retired in-process adapter. The
  legacy `.doclingServe` selection maps to this lineage; the optional token
  is the existing `extraction.docling-serve-token` Keychain item and reaches
  the package only after explicit authorization.