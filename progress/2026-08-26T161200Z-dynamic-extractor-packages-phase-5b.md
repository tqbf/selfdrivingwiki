---
timestamp: 2026-08-26T161200Z
title: Dynamic extractor packages Phase 5b catalog reconciler
branch: feature/dynamic-extractor-packages
status: complete
---

# Dynamic extractor packages Phase 5b catalog reconciler

## Progress

Phase 5b adds the catalog reconciler that maps durable machine generations onto the process-local dynamic plugin host.

- `ExtractorPackagePluginReconciler` reads an authoritative catalog generation and applies it through one `host.reconcile(desired:)` call that already owns define, run, observe-waiting, and undefine ordering.
- Unchanged generations short-circuit; `force:` repairs after drift without touching live components.
- All trusted definitions are built and cheaply revalidated before any lifecycle mutation: full secure revalidation of exact installed bytes via the existing validator (digests and normalized modes), so a manifest contradicting its record fails as a typed redacted entry while valid siblings proceed.
- Removal is publish-first by construction: the app deletes catalog membership, the next generation reconciliation undefines the plugin, and its consumed cleanup effect drains both kind namespaces.
- Corrupt or unreadable index keeps the current process graph untouched instead of tearing down known-good state; preparation-time revalidation remains authoritative for any use.
- Per-package failures are bounded (32 entries), redacted (no paths, no multi-line dumps), and retained for inspection; invalid installed bytes produce exactly one package-scoped failure and never register anything.

## Verification

The following gates passed on 2026-08-26:

```text
swift test --filter 'ExtractorPackagePluginReconcilerTests'
5 tests passed

swift test --filter 'ExtractorGeneratedPluginTests|ExtractionBackendRegistryBatchTests|ProcessExtractorProviderTests'
13 regression tests passed

make lint
swift build
git diff --check
```

## Next

Phase 5c: composition cutover — one process-scoped extraction context supplying the five fixed services once per app/daemon process, generated-plugin registration factories consuming `preparePDF`/`prepareHTML`, and removal of the legacy per-wiki extraction ownership rows.
