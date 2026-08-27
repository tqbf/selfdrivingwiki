---
timestamp: 2026-08-26T173000Z
title: Dynamic extractor packages Phase 3b durable machine catalog
branch: feature/dynamic-extractor-packages
status: complete
---

# Dynamic extractor packages Phase 3b durable machine catalog

## Progress

Phase 3b adds the durable machine catalog and the app-only package writer.

- `WikiFSCore` provides a read-only catalog reader and process-safe store coordinator.
- `WikiFSExtractorStore` contains the app-owned catalog writer. The daemon and CLI do not link this target.
- The store reserves each package ID and version digest permanently. Removal does not release the reservation.
- Installation revalidates staging, uses a descriptor-relative no-replace move, revalidates installed bytes, and then publishes the catalog.
- Catalog publication writes a private temporary file, syncs it, renames it atomically, and syncs the directory.
- Removal publishes the new catalog before it deletes package bytes.
- Recovery publishes valid moved packages, removes invalid or unreferenced payloads, and removes empty lineage directories.
- The store lock uses the App Group directory inode as its authority. Store-root replacement cannot create a second lock domain.
- Import admission rejects daemon and CLI roles before it creates staging state.
- Operation cleanup is role-scoped and descriptor-relative. App recovery removes stale app sessions. Daemon startup removes stale daemon sessions only.
- Snapshot creation revalidates the exact installed revision and copies it into a private process session.
- Tests use path-keyed fault injection. Parallel suites cannot consume another fixture's admission fault.

## Verification

The following gates passed on 2026-08-26:

```text
swift test --filter 'ExtractorPackageStoreTests|ExtractorPackageStoreMultiprocessTests|ExtractorPackageCatalogTests|ExtractorDirectoryAdmissionTests|RendererDirectoryValidationTests'
51 tests passed

swift build --product wikid
make lint
swift build
git diff --check
```

The multiprocess tests cover writer exclusion, store-root replacement, daemon reads, daemon mutation rejection, and writer-crash lock release.

LSP diagnostics are clear for the catalog reader, directory admission, catalog writer, and store tests.

## Remaining Phase 3 work

Phase 3 still needs the extractor package command-line tool and reviewed-package overlay integration. Later phases add managed execution and process-scoped reconciliation.
