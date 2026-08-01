# Wiki App platform

## 1. Purpose and scope

A Wiki App is an agent-built application that runs inside Self Driving Wiki. A user can ask an in-app agent to create or revise one without rebuilding the host application.

A Wiki App can provide a source workflow, an extractor, a renderer, or a combination. HTML, CSS, and JavaScript provide its interface. An optional Python or TypeScript backend uses the bundled `uv` or `bun` runtime for libraries, authentication protocols, and transformations.

Native Swift code owns durable wiki writes, capability grants, credential custody, policy decisions, and provenance. Generated code cannot access SQLite, arbitrary files, native process APIs, or unrestricted credentials directly.

The first implementation does not support generated Swift or dynamic native libraries. It does not expose a generic shell capability to a WebView. It does not install dependencies silently during a normal run. It does not migrate or delete current built-in providers, extractors, or renderers.

Ordinary imported HTML remains script-disabled in `Sources/WikiFS/Sources/HTMLSourceWebView.swift`. A Wiki App uses a separate trust boundary.

This document defines architecture only. It does not implement a registry, worker, WebView, schema, or user interface. It does not close issues #261, #390, or #593.

## 2. Vocabulary and typed identifiers

Swift APIs use separate identifier namespaces:

- `WikiAppID` identifies a stable application.
- `WikiAppVersion` identifies one immutable version.
- `WikiAppRunID` identifies one execution.
- `WikiAppManifestHash` binds the complete package.
- `WikiAppCapability` identifies one closed host operation.
- `ExtractorID` identifies one extractor registration inside an app.
- `ExtractorReference` identifies an exact app version and extractor.
- `RendererID` identifies one renderer registration inside an app.
- `RendererReference` identifies an exact app version and renderer.

These values do not use bare `String` inside Swift APIs. Raw strings cross only manifest, JSON-RPC, SQLite, and process boundaries.

A Wiki App version is immutable. A change to code, assets, the manifest, or a lockfile creates a new version and manifest hash.

## 3. Manifest and package format

Each package contains a versioned `wikiapp.json`, immutable UI assets, optional backend files, and dependency lock data. The manifest declares:

- app identity and version;
- supported host and protocol ranges;
- UI and optional backend entry points;
- a `uv` or `bun` runtime;
- lockfile and dependency hashes;
- capabilities and allowed network hosts;
- source operations, extractors, and renderers;
- input, output, time, process, and storage limits.

Installation validates a package. Registration does not execute it. Validation cannot run package install scripts or generated code.

A Slack source app can declare:

```json
{
  "schemaVersion": 1,
  "id": "local.slack-importer",
  "version": "1.0.0",
  "ui": "ui/index.html",
  "backend": { "runtime": "bun", "entrypoint": "backend/main.ts", "lockfile": "bun.lock" },
  "capabilities": ["network.fetch", "credential.use", "source.propose"],
  "allowedHosts": ["slack.com", "api.slack.com"],
  "sourceOperations": [{ "id": "import-channel", "displayName": "Import Slack Channel" }]
}
```

LiteParse can register a PDF extractor:

```json
{
  "schemaVersion": 1,
  "id": "local.liteparse",
  "version": "1.0.0",
  "backend": { "runtime": "uv", "entrypoint": "extract.py", "lockfile": "uv.lock" },
  "capabilities": ["input.read", "artifact.propose"],
  "extractors": [{
    "id": "pdf-to-markdown",
    "displayName": "LiteParse",
    "accepts": [{ "mime": "application/pdf" }],
    "produces": ["processed-markdown"],
    "network": "none"
  }]
}
```

An Excalidraw renderer can use local assets:

```json
{
  "schemaVersion": 1,
  "id": "local.excalidraw-viewer",
  "version": "1.0.0",
  "ui": "ui/index.html",
  "capabilities": ["input.read"],
  "renderers": [{
    "id": "diagram-viewer",
    "displayName": "Excalidraw",
    "accepts": [{ "extension": "excalidraw", "mime": "application/vnd.excalidraw+json" }],
    "modes": ["rendered", "split"],
    "editable": false,
    "network": "none"
  }]
}
```

JSON Canvas uses the same renderer contract with declarative `nodes` and `edges` matchers.

## 4. Host capability model

The host exposes a closed, typed API. Initial capability families include:

- read one authorized source content version;
- read one authorized page or chat snapshot;
- read or write objects in one run workspace;
- request an approved network operation;
- use a named credential through mediated fetch;
- propose a source or source content revision;
- propose processed Markdown or another artifact;
- open a wiki target;
- export an artifact or write to the clipboard.

The WebView-facing source operation is `source.propose`. A valid persistent grant can permit immediate native commit. The policy result is `committed`, `awaitingReview`, or `rejected`.

This capability need not be public or backed by `wikictl source add`. A future CLI command and the Wiki App host can share a typed internal source-registration service. Neither surface invokes the other.

The host derives the active `WikiID`, app identity, manifest hash, run ID, chat ID, and effective grant. Generated code cannot supply or spoof these values.

The host passes object handles across the UI and backend boundary. It does not accept arbitrary filesystem path strings from JavaScript.

## 5. UI and RPC boundary

A dedicated `WikiAppWebView` hosts Wiki App interfaces. It does not reuse `ChatWebView` and does not relax `HTMLSourceWebView`.

The view uses a private `WKWebViewConfiguration` and `WKUserContentController`. It has a controlled local origin, restrictive Content Security Policy, strict navigation policy, and no undeclared external scripts or iframes. It has no unrestricted `wiki-blob://` access.

A versioned request and response envelope carries typed operation and run IDs. The bridge defines correlation, cancellation, timeout, malformed-request rejection, and duplicate-response behavior. The host installs only handlers derived from effective capabilities and removes them when the view or run closes.

`Sources/WikiFS/Chats/ChatWebView.swift` and `Sources/WikiFS/Reader/WikiReaderView.swift` provide reference patterns for typed bridges and test seams. They are not the Wiki App security boundary.

## 6. Backend execution with bundled uv and bun

Python and TypeScript backends communicate through structured stdin and stdout RPC. The host passes executable and argument arrays. It does not construct shell command strings.

`Sources/WikiFSCore/Core/HelpersLocation.swift` provides bundled executable resolution. `Sources/WikiFSCore/Core/AsyncProcessRunner.swift` provides reference patterns for structured launch, pipe draining, and parent-process cancellation. The current runner does not establish descendant process-tree termination. The worker must own a process group and test full-tree termination.

App files are immutable. Each run gets one isolated workspace and clean `HOME`, cache, temporary, and environment directories. Named policy values limit wall time, CPU, memory, output bytes, files, descriptors, subprocess depth, and logs. Cancellation terminates the full process tree.

Normal execution is offline and locked. This means the worker has no direct network access. Approved requests still run through the native network broker.

Dependency installation or upgrade is a separate approval operation. It creates a new immutable app version. Normal runs cannot use `uvx`, `bunx`, unpinned resolution, install scripts, or undeclared native extensions.

The current `SandboxProfile` cannot secure Wiki Apps. It allows reads, network, and process execution by default. Wiki Apps require a separate default-deny worker profile and a dedicated helper or XPC isolation boundary. A prototype must validate the final mechanism.

## 7. Authentication and credentials

Native code keeps credentials in Keychain. The preferred path is a host-mediated request that injects a credential after policy validation. Generated code does not receive token bytes.

A grant is scoped to app ID, manifest hash, credential kind, and allowed destination hosts. Logs and errors record a credential identity label, never the secret.

Raw credential access is a stronger, short-lived capability. The first implementation should defer it unless a required API cannot use mediated requests. A new manifest hash does not silently inherit a raw credential grant.

Native code owns OAuth callback receipt, state validation, Keychain storage, revocation, and audit. A backend can construct an authorization URL, implement PKCE calculations, and parse provider responses. The host validates redirect and token endpoints before brokered exchange or refresh.

## 8. Source registration

A Wiki App produces a typed source proposal from a workspace object, remote URL intent, or bounded in-memory bytes. Native code validates filename, MIME type, size, external identity, provenance, and all staged artifacts before commit.

Existing compatibility references include:

- `Sources/WikiFSCore/Sources/SourceMaterializer.swift`;
- `MaterializedSource` and `SourceProvenance`;
- `WikiStore.addSource` and `WikiStore.appendContentVersion`;
- the private `WikiStoreModel.storeMaterialized` pattern.

`WikiStoreModel.storeMaterialized` is a private app-model seam. It is not a callable Wiki App API. Its best-effort sidecar persistence also cannot satisfy an atomic multi-artifact contract.

A new typed native source-registration and commit service will use `WikiStore` transactions. It can reuse current materialization values and store methods. Multi-source or multi-artifact proposals require a new store-level atomic operation after complete validation.

Each installed app does not become a new `SourceProvider` case. One stable platform classification can preserve current UI taxonomy. Structured provenance stores the concrete app, operation, version, manifest hash, run, and chat identity.

## 9. Runtime extractor registration

`ExtractionRegistry` combines built-in descriptors with enabled installed descriptors. Each descriptor declares:

- exact `ExtractorReference` and stable logical reference;
- display name and readiness;
- accepted MIME types and bounded declarative matchers;
- output artifact kinds;
- runtime, entry point, capabilities, and limits;
- privacy, network, credential, and default-option behavior.

This registry replaces the closed selection role of `ExtractionBackend.allCases` and `ExtractionCoordinator.current()` over time. Persisted `ExtractionBackend` values remain compatibility inputs. `MarkdownExtractor` remains a useful adapter for current built-ins.

Future queue and selection contracts carry `ExtractorReference`, not arbitrary strings or one enum case per installed app.

The built-in registry initially wraps:

- pdf2md as a built-in `uv` PDF extractor;
- Defuddle as a built-in `bun` HTML extractor;
- ACP, Anthropic, Gemini, and Docling Serve PDF extraction;
- tag-based HTML extraction;
- podcast and YouTube transcript extraction.

LiteParse validates dynamic registration. Installing its package adds a PDF option without a Swift rebuild.

A standard request pins the input content version, hash, extractor, app version, manifest, protocol, options, run kind, and grants. A standard result proposes processed Markdown and supported typed artifacts. Native code validates and appends output through the current version model.

Provenance records the extractor reference, manifest and lock hashes, runtime version, model or tool version, options hash, input version, run ID, and chat ID.

## 10. Runtime renderer registration

`RendererRegistry` resolves compatible renderers from MIME type, extension fallback, and bounded declarative content sniffing. Native code evaluates matchers. Renderer code cannot inspect the whole wiki to claim formats.

A renderer descriptor declares its exact reference, stable logical reference, display name, matchers, modes, assets, capabilities, limits, network policy, and read-only or editable presentation.

`SourceDetailView` asks the registry for Source, Rendered, and Split presentations. It does not gain one branch per generated format.

Issue #593 is the first platform validation case. A local Excalidraw viewer provides read-only pan and zoom without network or write capability. JSON Canvas uses the same contract and can request host-mediated resolution for links that occur in its authorized document.

Editing is a separate `source.proposeRevision` capability. A revision carries the expected content-version ID. Native code rejects stale writes and persists accepted edits through `appendContentVersion`, never row overwrite.

The platform defines three WebView trust levels:

1. Imported HTML with JavaScript disabled.
2. A registered read-only renderer with one authorized input.
3. An editable or operational Wiki App with explicit capabilities.

## 11. Persistence and provenance

Overloading current PROV text fields could support a prototype, but it is brittle. The platform should add structured logical records for:

- an app and immutable app version;
- extractor and renderer registrations;
- capability grants and policy version;
- a run and lifecycle state;
- request and result audit events;
- links to produced source, content, Markdown, and artifact versions.

The exact SQL shape belongs to a later implementation slice. Existing SQLite text, source and Markdown version chains, File Provider output, wiki links, and CLI formats remain compatibility contracts.

## 12. User experience

Native macOS UI owns:

- a chat action to create or revise a Wiki App;
- an installation review for code, dependencies, network, credentials, and capabilities;
- a Wiki Apps settings list with enabled state, readiness, version, and grants;
- an Extract With menu from compatible registry entries;
- renderer choice and Source, Rendered, and Split tabs;
- progress, cancellation, diagnostics, and produced-result links;
- update permission differences, activation, rollback, and removal.

Primary actions remain visible. Technical details use progressive disclosure. Later UI work must support keyboard access and VoiceOver.

## 13. Security model

Structural controls address these threats:

| Threat | Structural control |
| --- | --- |
| Bridge escalation or malformed RPC | Closed operations, typed envelopes, run binding, limits, and fail-closed decoding |
| Replay, cross-run, or cross-wiki requests | Host-derived identities, nonces, exact grants, idempotency keys, and lifecycle checks |
| Arbitrary file access or path traversal | Brokered object handles, isolated workspaces, canonical paths, and output validation |
| Dependency substitution or install scripts | Immutable full-package hash, locked offline runs, and separate approved version creation |
| Subprocess escape | Dedicated default-deny worker, process groups, limits, and full-tree cancellation |
| Network exfiltration | No direct network, native broker, destination checks, quotas, and redirect revalidation |
| Credential theft | Native Keychain custody, mediated injection, scoped grants, and redacted logs |
| Navigation or iframe exfiltration | CSP, strict navigation policy, local assets, and no undeclared frames |
| Output bombs | Byte, file, nesting, decompression, image, and canvas limits |
| Provenance spoofing | Host-generated provenance and package/run identity |
| Stale revisions | Expected content-version IDs and append-only writes |
| Compromised renderer assets | Immutable package hashes, isolated data stores, and capability-derived handlers |
| Cache poisoning | Complete cache keys, validation, and no reuse with undeclared inputs |

The first implementation cannot claim complete isolation before the worker prototype proves the process and network boundaries. Generated UI can still mislead a user, consume resources within limits, or produce semantically harmful output. Native review, visible app identity, and safe fallback reduce these risks.

## 14. Lifecycle, package trust, and updates

The app state machine permits these transitions:

| State | Legal next states |
| --- | --- |
| `downloaded` | `validated`, validation rejection |
| `validated` | `installed-disabled`, rejection |
| `installed-disabled` | `enabled`, `uninstalled` |
| `enabled` | `ready`, `suspended-or-broken`, `installed-disabled`, `uninstalled` |
| `ready` | `suspended-or-broken`, `installed-disabled`, `uninstalled` |
| `suspended-or-broken` | `enabled` after repair, `installed-disabled`, `uninstalled` |
| `uninstalled` | terminal for that installed version |

Rollback activates an older validated version. It does not mutate either version. A repaired package creates a new version unless only host-owned state was damaged.

The run state machine permits these transitions:

| State | Legal next states |
| --- | --- |
| `created` | `awaiting-grant`, `queued`, `cancelled` |
| `awaiting-grant` | `queued`, `cancelled`, `failed` |
| `queued` | `starting`, `cancelled`, `abandoned` |
| `starting` | `running`, `failed`, `cancelled`, `abandoned` |
| `running` | `validating-output`, `failed`, `cancelled`, `abandoned` |
| `validating-output` | `committing`, `failed`, `cancelled` |
| `committing` | `succeeded`, `commit-failed` |
| `commit-failed` | `committing` through idempotent recovery, or terminal `failed` |
| `succeeded`, `failed`, `cancelled`, `abandoned` | terminal |

A cancellation request during `committing` cannot undo an atomic commit. Recovery checks the idempotency record before it reports success or failure.

Lifecycle events preserve data as follows:

| Event | Required behavior |
| --- | --- |
| Disable | Stop new runs and registrations. Preserve packages, app state, grants, run records, and provenance. |
| Uninstall | Remove registrations, grants, credentials, app state, schedules, and caches under policy. Preserve produced wiki content and explanatory metadata. |
| Rollback | Activate an older immutable version. Preserve newer versions, runs, preferences, grants, and provenance until retention policy permits cleanup. Re-evaluate effective grants for the activated hash. |
| Host upgrade | Revalidate protocol compatibility and package integrity. Suspend incompatible apps without deleting data. |
| App or host crash | Mark orphaned active runs `abandoned` or recover their persisted commit state. Clean workspaces under retention policy. |
| Credential revocation | Prevent new broker requests. A non-committing active run fails with `expiredCredential` or returns to `awaiting-grant`. An atomic commit already in progress completes or recovers by idempotency key. |

Produced wiki content and enough package identity metadata to explain it survive app removal.

The host distinguishes built-in, local agent-generated, imported, and signed third-party packages. An unsigned package cannot shadow a built-in or another publisher identity.

The canonical package hash covers normalized manifest, code, assets, locks, modes, and protocol declarations. Validation rejects symlinks, hard links, special files, duplicate archive entries, path traversal, unsafe Unicode or case collisions, and archive bombs.

Every revision creates a new immutable version. Old versions remain while runs, preferences, or provenance refer to them. Activation is explicit, rollback is supported, and updates display semantic permission differences. New capabilities are never enabled silently.

## 15. Grant timing and policy

Grant evaluation has three stages:

1. Installation validates declarations and package integrity.
2. Enablement records eligible persistent grants.
3. A run derives effective grants from context, user action, and policy.

Scopes include once, this run, this source, this wiki, and this exact manifest hash. Clipboard, export, and external navigation require a foreground gesture. Raw credentials use short-lived elevation.

A background run does not wait for a hidden dialog. It enters a typed `grantRequired` result and can resume after foreground approval.

A changed manifest hash receives a new security review. The host can propose safe grant migration after a semantic permission diff, but it cannot copy expanded grants silently. Each grant records its capability-policy version.

## 16. Network broker and credential boundary

The worker and renderer boundaries must prevent direct network access. A native broker performs approved requests. The worker prototype must prove the enforcement mechanism before this becomes a security guarantee.

The broker validates methods, normalized hosts, ports, IDNs, resolved addresses, redirects, TLS, request and response sizes, streaming, timeouts, uploads, headers, and rate limits. It rejects loopback, link-local, private, or rebound destinations unless a specific policy permits them. Every redirect target is checked again.

Cookies are isolated by app and grant. WebSockets, server-sent events, proxies, and unusual ports are denied until explicit protocol support exists. Response headers and errors are filtered before generated code receives them.

## 17. Atomic runs, recovery, and app state

The host persists run intent before execution. It stages all proposed mutations and validates the complete set before a native transaction changes wiki data.

Every mutating request has an idempotency key scoped to an exact app version and run. Recovery distinguishes no result, unvalidated result, validated result, uncommitted result, lost acknowledgement after commit, and cancellation racing with commit.

A retry returns the prior commit result or resumes safely. It cannot duplicate a Slack, Zotero, archive, source, or extraction result.

A scoped app-data service stores cursors, account associations, preferences, external-ID mappings, and similar durable state. Apps cannot create arbitrary SQLite tables. State is namespaced by wiki, stable app identity, and optional account. App data has an explicit schema version and migration operation.

The first implementation excludes schedules, webhooks, and automatic synchronization. Typed run kinds reserve foreground interactive, user-triggered headless, scheduled, refresh, and event-triggered behavior. Future unattended runs use only grants that allow unattended execution.

## 18. Registration resolution and composition

An exact registration reference contains app ID, app version, and registration ID. A stable logical reference lets a preference follow compatible updates.

Matcher priority and tie-breaking are deterministic. Installation order never selects an extractor or renderer. Preferences define their scope and fallback. A queued or active run pins one exact descriptor for its full lifetime. The platform defines whether multiple versions can be enabled concurrently.

A refreshable source records an exact app operation, app version, external identity, and input recipe. Refresh appends a content version. Native policy decides whether a proposal creates a source, appends a version, creates a child, or matches an idempotent prior result.

Native orchestration can invoke a registered extractor from a source workflow. The first implementation does not permit arbitrary direct app-to-app RPC. Each hop gets a separate run and grant context. Capabilities do not flow transitively.

Later composition must define cycle detection, maximum depth, fan-out, and provenance edges. Defuddle can receive an authorized Slack artifact without inheriting Slack credentials or network grants.

## 19. Artifact contracts, reproducibility, and caching

The initial typed artifact vocabulary includes processed Markdown, source proposals, source revision proposals, files or blobs, and namespaced JSON artifacts. It can later add OCR geometry, tables, thumbnails, and child sources without creating a universal runtime type system.

A result can stage multiple artifacts. Native code persists only supported kinds. Intermediate artifacts remain inspectable when another stage consumes them.

Runs declare one reproducibility class:

- deterministic offline transformation;
- pinned tool but environment-sensitive;
- network-observed snapshot;
- model-assisted or non-deterministic.

Network and model runs do not promise byte-for-byte reproduction. Provenance records enough evidence to explain and compare results, including host and policy versions, negotiated protocols, runtime and architecture, locale and time zone, controlled seed, credential identity label, and dependency and asset hashes.

A cache key includes the input content-version hash, exact registration, package and lock hashes, runtime, options, tool or model version, and all declared deterministic inputs. The host does not reuse a cache when an undeclared external input can affect output.

## 20. Resource governance, diagnostics, and recovery UX

Named policies set per-run, per-app, and global limits for workers, queue fairness, priority, CPU, memory, disk, file descriptors, process depth, request concurrency, network bytes, decompression, JSON nesting, WebView count, decoded images, canvas size, logs, and workspace retention.

Inactive renderers can suspend. Repeated platform crashes activate a safe mode that starts with installed Wiki Apps disabled.

Diagnostics use stable categories and error codes. User diagnostics are separate from privileged logs. Redaction removes credentials, authorization headers, cookies, OAuth codes, query secrets, environment values, source bodies, and sensitive filenames before persistence.

Actionable failures include missing runtime, incompatible protocol, damaged package, missing grant, expired credential, denied network, quota kill, invalid result, stale revision, and commit recovery. A retry uses pinned app and input versions.

Cleanup policy covers success, failure, cancellation, abandonment, uninstall, and low disk space.

## 21. Renderer behavior and accessibility

Read-only behavior is enforced by omitting write handlers. A manifest assertion does not grant or enforce it.

The UI visibly identifies Wiki App content. The host restricts pop-ups, downloads, fullscreen, clipboard, external navigation, and deceptive native permission UI. Sensitive presentation actions require a user gesture.

Imported HTML, registered renderers, and operational Wiki Apps use separate process pools or nonpersistent data stores where the prototype supports them. Session data clears at teardown. A renderer receives only its authorized source version and declared linked targets.

If a renderer is missing, disabled, incompatible, or inaccessible, the app falls back to Source mode. Generated interfaces require labels, visible focus, semantic structure, reduced-motion support, adequate contrast, and no keyboard traps.

Descriptors can advertise optional interactive, snapshot, print, thumbnail, export, and accessibility-text operations. These are not required in the first renderer slice. A source preference states whether it follows a logical renderer or pins an exact version.

## 22. Protocol compatibility and portability

The manifest, WebView bridge, worker RPC, capability schema, and artifact schema negotiate versions independently. A package declares a host range and required capability revisions. The host rejects unsupported required features before enablement. Unknown capabilities and operations fail closed.

Each run records negotiated versions. Compatibility fixtures cover old package with new host, new package with old host, built-in adapters, malformed ranges, and removed capabilities.

Backup and sync policy treats manifests, payloads, app state, grants, credentials, preferences, caches, and provenance separately. Credentials never enter wiki storage. Grants can remain device-specific. A wiki without a renderer falls back safely and can offer installation.

## 23. Extraction and ingestion ownership

Source registration, extraction, and agent ingestion are separate stages:

1. Source registration stores or versions source material with validated provenance.
2. Extraction transforms one content version into processed Markdown or typed artifacts.
3. Agent ingestion reads pinned source material or artifacts and updates wiki pages through current agent workflows.

The platform preserves #799 behavior. HTML and transcript extraction remain user-triggered. Installing or matching an extractor does not run it. Registering a source does not start extraction or agent ingestion without an explicit action or policy.

A content-neutral extraction request carries host-derived `WikiID` and `SourceID`, exact content-version ID and hash, pinned `ExtractorReference`, typed input and outputs, options and hash, run kind, priority, user-action context, grants, idempotency key, and originating chat or workflow.

Migration must cover current split paths:

- PDF extraction through `QueueExtractionProvider` and `ExtractionResolution`;
- HTML extraction through the direct model path;
- podcast and YouTube transcript provider dispatch;
- format handling through `FormatMaterializer` and `SourceMaterializer`;
- agent ingestion through the queue and `AgentOperationRunner`.

The platform does not force all content through the existing PDF-coupled payload. It defines a content-neutral extraction job and adapts current queue and direct implementations in stages.

A queue item resolves and pins one descriptor before it runs. It persists app version, manifest, protocol, input, and options. Disabled, removed, incompatible, or unapproved registrations produce typed unavailable or `grantRequired` states. A queued item never switches extractors silently.

Extraction concurrency remains separate from agent-generation concurrency. Extraction does not lock unrelated queries, edits, or another source's ingest.

Each extraction appends an alternative Markdown version. It does not overwrite prior output or automatically select itself unless request policy says so. Compare, nominate, pinning, citation, File Provider, and provenance behavior remain compatible.

An agent-ingestion run pins its selected source and artifact versions before execution. A later extraction cannot change an active run's inputs.

A source-producing app can offer Extract, Ingest, or Extract and Ingest after commit. Native orchestration creates distinct runs and provenance edges. Credentials and capabilities do not flow across stages.

Source registration can succeed while extraction fails. Extraction can succeed while agent ingestion fails. Each successful stage remains durable and retryable. Retrying a later stage does not repeat an earlier commit. The UI reports partial success and links to each result.

Before routing changes, characterization tests must preserve built-in output, provenance labels, queue visibility, progress, notifications, active-version behavior, and source-detail actions.

## 24. Compatibility and migration

This platform extends current code before it replaces closed routing.

1. Add typed descriptors and registries that wrap current built-ins.
2. Add persistent manifests, versions, grants, and runs.
3. Add the dedicated WebView and typed bridge.
4. Add the isolated `uv` and `bun` worker.
5. Express pdf2md and Defuddle as built-in registrations after compatibility tests.
6. Prove LiteParse as the first no-rebuild extractor.
7. Prove Excalidraw or JSON Canvas as the first no-rebuild renderer.
8. Prove Slack or Zotero as the first source-producing Wiki App.
9. Remove closed routing only after migrations and compatibility tests exist.

`SourceProvider` remains a built-in and compatibility taxonomy. Installed apps do not add enum cases. `MarkdownExtractor`, `ExtractionBackend`, `ExtractionCoordinator`, and `QueueExtractionProvider` remain adapters until registry-driven contracts replace their closed selection roles.

The design generalizes future work from issue #261. Issue #390 remains an optional external CLI surface. Issue #593 becomes a renderer-platform validation case rather than a one-off `SourceDetailView` branch.

## 25. Implementation slices

### Slice A: Foundation contracts

Add identifiers, manifest types, descriptors, declarative matchers, protocol ranges, and pure validation. Likely modules are `WikiFSTypes` and a Foundation-only part of `WikiFSCore`. No production behavior changes.

### Slice B: Built-in registry adapters

Add extraction and renderer registries that wrap current implementations without changing execution. Touch `ExtractionCoordinator`, `ExtractionBackend`, `QueueExtractionProvider`, content detection, and `SourceDetailView` only through compatibility seams. Add golden characterization tests first.

### Slice C: Persistence

Add schema records for apps, versions, registrations, grants, runs, audit events, and artifact links. Implement through `WikiStore` and GRDB migrations. Preserve existing public and raw storage contracts.

### Slice D: WebView and fake bridge

Add `WikiAppWebView`, the typed bridge, navigation/CSP policy, and a fake host. Keep `HTMLSourceWebView`, `ChatWebView`, and `WikiReaderView` behavior unchanged.

### Slice E: Worker and sandbox

Add worker RPC, process-group ownership, default-deny isolation, quotas, redaction, and network-broker integration. Reuse helper resolution and process-launch patterns without claiming current sandbox sufficiency.

### Slice F: Source proposal and commit

Add proposal validation, staged objects, idempotent intent, and a native transactional commit service. Add store-level atomic multi-artifact support as an explicit schema or public-store contract change.

### Slice G: Extractor registrations

Migrate pdf2md and Defuddle behind built-in descriptors without changing output. Add LiteParse as the first installed `uv` extractor. Integrate the content-neutral job with queue and direct compatibility paths.

### Slice H: Renderer registrations

Add read-only Excalidraw and JSON Canvas descriptors, renderer sessions, Source/Rendered/Split integration, link resolution, and safe fallback. Defer editing.

### Slice I: Product UI

Add chat creation and revision, installation review, settings, semantic permission differences, run progress, errors, and removal. Apply native macOS accessibility and keyboard requirements.

Each slice must build through SwiftPM. Each schema migration and public contract change must be explicit in its implementation plan.

## 26. Test strategy

Future suites include:

- `WikiAppManifestTests` and `WikiAppPackageValidationTests` for Slice A;
- `ExtractionRegistryTests` and `RendererRegistryTests` for Slice B;
- `WikiAppRunStoreTests` for Slice C;
- `WikiAppBridgeTests` and `WikiAppRendererHostedTests` for Slices D and H;
- `WikiAppWorkerProtocolTests` and `WikiAppSandboxProfileTests` for Slice E;
- `WikiAppCapabilityPolicyTests`, `WikiAppCredentialPolicyTests`, and `WikiAppSourceProposalTests` for Slices E and F;
- `WikiAppExtractorRunnerTests` and `WikiAppExtractionProvenanceTests` for Slice G;
- `WikiAppRevisionProposalTests` for later editable rendering;
- `WikiAppChatIntegrationTests` for Slice I.

Tests must cover malformed packages and RPC, duplicate IDs, late responses, cancellation races, process-tree cleanup, network redirects and rebinding, secret redaction, disk-full and quota failures, commit crash points, idempotent recovery, registration conflicts, compatibility ranges, and non-transitive grants.

Implementation work uses targeted tests during development. Every implementation pull request runs `make build` and `make test`. Bare `swift build` and `swift test` must remain compatible.

## 27. Decisions and open questions

Decisions:

- A Wiki App has HTML UI and can have a Python or TypeScript backend.
- Bundled `uv` and `bun` are supported runtime implementations.
- Source addition is a private native capability unless another surface needs it.
- Wiki Apps can register source operations, extractors, and renderers at runtime.
- LiteParse validates dynamic PDF extraction.
- JSON Canvas and Excalidraw validate dynamic rendering.
- Native code owns writes, grants, credentials, policy, and provenance.
- Source registration, extraction, and agent ingestion remain separate stages.
- The first implementation supports interactive and user-triggered headless runs, not automatic synchronization.

Open questions for prototypes or later operator choices:

- dedicated XPC worker or another helper process;
- exact direct-network enforcement mechanism;
- package source, signing, and publisher policy;
- safe grant migration across app versions;
- exact structured persistence schema;
- renderer preference scope by format, source, or both;
- Excalidraw or JSON Canvas as the first renderer;
- whether any first release requires raw credentials;
- exact concurrent-version and registration tie-break policy.

These questions do not block this architecture record.
