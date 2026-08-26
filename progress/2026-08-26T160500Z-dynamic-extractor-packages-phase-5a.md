# Dynamic extractor packages: Phase 5a

Phase 5a adds typed registry identity, atomic batch registration, and the host-generated plugin definition factory for installed extractor packages.

## Delivered

- `ExtractionAdapterKey` gives the registry a typed identity domain: built-in adapters keep legacy string keys behind `.builtIn`; installed adapters use exact revision-plus-registration references that cannot collide across versions or lineages.
- `ExtractionBackendRegistry.registerBatch` validates every entry, including intra-batch collisions, before any mutation, then commits atomically under one shared token. The returned handle removes exactly its own entries; repeated or stale disposal is a no-op even when an exact key was re-registered since.
- `resolveInstalled(_:kind:)` returns the highest compatible active exact registration by semantic version then revision identity. `installedMatches(kind:)` lists the full ordered view.
- Four fixed host service keys declare the entire dependency contract a package plugin may use: catalog reader, managed process executor, admission checker, store layout (plus the shared backend registry).
- `ExtractorPackagePluginDefinitionFactory` produces one deterministic `dynamic:extractor-package/<digest>` plugin ID per revision and an immutable fingerprint over protocol, normalized registrations, and contract version. Definitions are config-free per the dynamic host contract, declare only the fixed dependencies, and their component body performs cheap authoritative catalog revalidation before building all registration factories and committing one batch through a single cleanup effect.
- `RegisteredExtractionBackend.Factory` is now throwing, so installed-package preparation failures can fail activation and roll back the whole batch. Existing static adapters remain source-compatible.

## Verification

The following gates passed on 2026-08-26:

```text
swift test --filter 'ExtractionBackendRegistryBatchTests|ExtractorGeneratedPluginTests'
10 tests passed

make lint
swift build
git diff --check
```

Coverage includes atomic commit and exact-token disposal, collision-commits-nothing, stale disposer versus newer registration, semantic-version plus digest ranking, kind namespace isolation, deterministic prefixed identity, fingerprint sensitivity to registration changes, full `DynamicPluginHost` activation over a real installed fixture registering both kinds through a live Cordis context, waiting-to-active without a second run once services appear, failed catalog revalidation leaving the registry untouched, and quiescent stop draining both namespaces via the consumed cleanup effect.

## Next

Phase 5b: the reconciler that maps durable catalog generations into define/run/stop/undefine operations on this factory, logical selection resolution in `ExtractionConfig`, and composition cutover to one process-scoped extraction graph.
