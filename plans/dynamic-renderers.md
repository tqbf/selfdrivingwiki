# Dynamic renderers

Last revised: 2026-08-01

> Historical note: The original Excalidraw bundling and host-projection design in
> this record is superseded by [`plans/excalidraw-renderer-package.md`](excalidraw-renderer-package.md).
> Keep this record as historical evidence for the shared renderer runtime.

Tracking issue: [#1026](https://github.com/tqbf/selfdrivingwiki/issues/1026)

## 1. Goal

Add new read-only source renderers without adding one routing branch for each
format. A renderer can be a built-in native view or an installed static WebView
package.

This feature set is independent from extraction workers, source workflows, and
agent ingestion. It proves the smallest useful registration and package model.

Excalidraw issue #593 and JSON Canvas issue #594 are the first validation cases.
They remain separate format issues. This plan defines the shared renderer path.

## 2. User experience

`SourceDetailView` asks the registry for available presentations. The source
reader remains available for every source.

The detail toolbar uses the existing presentation selector:

- **Source** shows the durable source or extracted text.
- **Rendered** shows the selected renderer.
- **Split** shows Source and Rendered together.

The selector appears only when a renderer is available. The content remains the
main part of the window. Renderer controls stay inside the rendered pane.

The app preserves the selected presentation for that source. If the selected
renderer becomes unavailable, the app selects Source and explains why.

Every renderer must support keyboard navigation, VoiceOver labels, light and
dark appearance, and Reduce Motion. A rendered pane must not create a keyboard
trap.

## 3. Scope

The first release includes:

- typed renderer identifiers and references.
- built-in and installed renderer descriptors.
- deterministic matching and selection.
- immutable, hash-pinned WebView assets.
- per-machine package installation.
- per-wiki renderer enablement.
- read-only `WikiAppWebView` sessions.
- Source, Rendered, and Split presentations.
- safe fallback to Source.
- renderer diagnostics and crash safe mode.
- Excalidraw and JSON Canvas validation cases.

The first release does not include:

- `uv`, `bun`, or another worker runtime.
- network access.
- credentials.
- renderer-controlled durable writes.
- editable renderers.
- extraction or ingestion prompts.
- source registration.
- schedules or background runs.
- third-party signing or distribution.

## 4. Model

### 4.1 Typed identifiers

Use separate identifier types:

- `RendererPackageID` identifies an installed renderer package.
- `RendererPackageVersion` identifies one immutable package version.
- `RendererRegistrationID` identifies one registration inside a package.
- `RendererReference` identifies one exact package version and registration.
- `LogicalRendererReference` identifies a compatible renderer across versions.

Raw strings cross only JSON, SQLite, and external-format boundaries.

### 4.2 Descriptor

A `RendererDescriptor` declares:

- its exact and logical references.
- its display name.
- its implementation kind.
- bounded content matchers.
- supported presentations.
- approved asset hashes.
- input and decoded-size limits.
- link behavior.
- accessibility support.
- compatibility revisions.

The implementation kind is a tagged value:

```swift
enum RendererImplementation {
    case builtIn(BuiltInRendererID)
    case webPackage(RendererWebEntryPoint)
}
```

Installed packages cannot provide native Swift. Native renderers use a closed
built-in identifier and ship with the host.

### 4.3 Package

A renderer package contains:

- one normalized manifest.
- immutable HTML, CSS, JavaScript, fonts, and images.
- one or more renderer registrations.
- a content hash for each file.
- a package hash over the normalized manifest and assets.

The package contains no executable backend, dependency manager, or prompt. A
manifest cannot request worker, network, credential, or write capabilities.

Installation is per machine. Enablement and renderer preference are per wiki.
The package payload does not enter wiki storage or sync.

## 5. Registry and resolution

`RendererRegistry` combines built-in descriptors with enabled installed
descriptors. It exposes pure queries over an immutable registry snapshot.

The host evaluates all matchers. Renderer code cannot inspect the wiki to claim
additional formats.

Matcher inputs can include:

- normalized MIME type.
- file extension as a fallback.
- bounded content signatures.
- a typed artifact kind.

Resolution uses explicit priority and stable tie-break rules. Installation order
cannot change the result.

A source can follow a logical renderer preference or pin an exact renderer. The
first implementation should prefer logical references so compatible updates can
replace older package versions.

An active renderer session pins one exact `RendererReference`. Registry changes
do not replace the renderer until the session closes.

## 6. Session security

Renderer input is untrusted. Renderer assets are also untrusted unless they ship
as a built-in host resource.

Each WebView renderer uses:

- a nonpersistent website data store.
- an isolated content world and message-handler set.
- a restrictive Content Security Policy.
- no direct network access.
- no file URL access outside its package resources.
- one authorized source or artifact version.
- host-mediated resolution for approved linked targets.
- full handler removal when the session ends.

Document links are requests, not authorization. A user gesture can open an
external URL in the default browser. The renderer cannot fetch that URL.

The first bridge exposes only `input.read` for the authorized version. It can
also expose typed link-navigation requests if the renderer declares that need.
It exposes no generic file, shell, network, clipboard, or write handler.

Vendored built-in bundles are part of the trusted computing base. The host pins
their hashes and updates them in reviewed changes.

## 7. Presentation lifecycle

The registry returns zero or more renderer choices for a source. The model then
applies the stored preference and deterministic default selection.

The view lifecycle is:

1. Resolve and pin one exact renderer descriptor.
2. Validate the input size and descriptor compatibility.
3. Create the native view or isolated WebView session.
4. Supply only the authorized input version.
5. Display diagnostics inside the rendered pane when loading fails.
6. Tear down handlers, transient data, and the session when the pane closes.

Renderer sessions do not use `GenerationGate`. A named policy limits concurrent
WebViews and decoded content size.

Repeated renderer crashes activate safe mode. Safe mode disables installed
renderers and keeps built-in Source presentation available.

## 8. Failure and fallback

Source is the permanent fallback. The app selects Source when:

- no descriptor matches.
- the selected package is missing.
- the renderer is disabled.
- the descriptor is incompatible.
- an asset hash fails.
- input exceeds a declared limit.
- the renderer crashes or fails to load.

The source remains readable after package removal. Renderer preferences can
remain as inactive references so reinstalling a compatible package restores the
choice.

The UI shows a short reason for fallback. Detailed diagnostics go through
`DebugLog` with redacted source content.

## 9. Validation cases

### 9.1 Excalidraw

Excalidraw proves an installed static WebView package:

- match `.excalidraw` JSON with bounded sniffing.
- load a hash-pinned viewer bundle.
- support pan and zoom.
- deny network and writes.
- open external links only after a user gesture.
- fall back to raw source JSON.

Issue #593 owns Excalidraw-specific behavior and bundle selection.

### 9.2 JSON Canvas

JSON Canvas proves a built-in native renderer registration:

- match `.canvas` JSON with bounded sniffing.
- decode nodes and edges into typed values.
- support pan, zoom, selection, and outline navigation.
- resolve file and wiki links through the host.
- fall back to raw source JSON.

Issue #594 owns JSON Canvas parsing and native presentation details.

Together these cases prove that one registry can select both implementation
kinds without putting format branches in `SourceDetailView`.

## 10. Persistence

Renderer package records are machine-scoped. Store package identity, versions,
manifest hashes, asset hashes, and installation state outside wiki databases.

Wiki databases store only renderer enablement and preferences that belong to a
wiki. A preference stores a logical or exact typed reference.

A read-only renderer session does not create a provenance activity. Rendering
does not create a new source or page version.

## 11. Tests

Add these test groups:

- `RendererDescriptorValidationTests` for manifest and archive rules.
- `RendererRegistryTests` for matching, priority, and stable tie-breaks.
- `RendererPreferenceTests` for logical and exact references.
- `RendererPackageHashTests` for immutable assets.
- `WikiAppWebViewBridgeTests` for typed decoding and handler teardown.
- `RendererNetworkIsolationTests` for blocked requests and redirects.
- `RendererSessionIsolationTests` for cookie and storage separation.
- `RendererFallbackTests` for missing, disabled, incompatible, and failed
  renderers.
- Excalidraw and JSON Canvas golden characterization tests.
- keyboard, VoiceOver, light appearance, dark appearance, and Reduce Motion
  checks.

All Swift code must compile with SwiftPM. Use `make build` and `make test` for
final verification.

## 12. Delivery slices

### Slice 1: Built-in registry adapters

Add typed descriptors and a registry around current built-in presentations.
Keep current behavior unchanged. Add golden characterization tests first.

### Slice 2: Generic presentation routing

Make `SourceDetailView` request presentations from the registry. Remove new
format-specific routing from this view. Preserve Source fallback.

### Slice 3: Web renderer session

Add the read-only WebView package loader, isolation policy, typed input bridge,
and package validation. Do not add a worker runtime.

### Slice 4: Validation renderers

Register Excalidraw as the first installed WebView renderer. Register JSON
Canvas as a built-in native renderer. Verify Source, Rendered, and Split modes.

### Slice 5: Package management UI

Add renderer installation, enablement, version, diagnostics, rollback, and
removal controls. Preserve source content and inactive preferences on removal.

## 13. Exit criteria

The feature set is complete when:

- a renderer package adds a format without a host routing change.
- built-in and installed renderers use one registry contract.
- renderer selection is deterministic.
- an active session pins one exact descriptor.
- installed renderers have no network or durable write path.
- Source mode survives every renderer failure.
- Excalidraw and JSON Canvas pass their validation suites.
- `make build` and `make test` pass.
