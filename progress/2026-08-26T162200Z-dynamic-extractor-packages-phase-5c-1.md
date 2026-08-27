---
timestamp: 2026-08-26T162200Z
title: Dynamic extractor packages Phase 5c slice 1 process extraction context
branch: feature/dynamic-extractor-packages
status: complete
---

# Dynamic extractor packages Phase 5c slice 1 process extraction context

## Progress

This slice introduces the single process-scoped extraction context that per-wiki consumers will resolve in slice 2.

- `ProcessExtractionContext` assembles one Cordis context, one `ExtractionBackendRegistry`, one `DynamicPluginHost`, one reconciler, and one catalog reader per app or daemon process, supplying the five fixed services exactly once.
- The fixed-service supply is structurally guarded: any competing supply of an already-provided key fails with Cordis `duplicateSupply`, so no consumer path can introduce a second registry or executor inside a process.
- `RegistryMembershipAdmission` becomes the default admission authority for prepared operations: membership is read from the same registry every batch commit and cleanup effect flows through, so stale plugin definitions cannot admit removed code.
- Cross-process wakes land on `reconcileNow` as hints; unchanged generations short-circuit, forced reconciliation repairs drift.
- Composition identity is proven at unit level: two independently assembled contexts each see exactly their own durable generation, own exactly one hosted plugin, and a probe registration in one graph is invisible from the other.

## Verification

The following gates passed on 2026-08-26:

```text
swift test --filter 'ProcessExtractionContextTests|ExtractorPackagePluginReconcilerTests|ExtractorGeneratedPluginTests|ExtractionBackendRegistryBatchTests'
18 tests passed

make lint
swift build
git diff --check
```

## Next

Slice 2 cuts over live composition: `ExtractionCompositionOwner`'s assembly builds this context, profile bundle rows for `wiki.extraction` / `wiki.extraction.pdf2md` become consumers of the inherited facade, and `ExtractionRuntimeFactory` loses its manual resolver.
