---
timestamp: 2026-08-30T183000Z
title: ExtractionConfig retires the backend and htmlBackend stored fields
branch: chore/remove-retired-extraction-config-fields
status: complete
---

# ExtractionConfig retires the backend and htmlBackend stored fields

Issue #1178.

## Progress

`ExtractionConfig` no longer stores `backend` or `htmlBackend`. The decoder
consumes both keys as local migration values inside `init(from:)` and feeds
them into the one-time route-record migration, so an old config file still
resolves to the same selection it always had. Encode never wrote the keys;
now no stored state can hold them either. A decoded-but-never-persisted
field was a trap: a reader could see a value that the next save resets.

The initializer lost its `backend:` and `htmlBackend:` parameters.
`currentModelVersion` is deleted too — it switched on `backend` and had no
callers left.

The two test-only runtimes in `ExtractionCoordinator.swift`
(`ExtractionRuntime` and `LegacyExtractionServices`) received their backend
from the retired field when a caller passed no override. They now require an
explicit `backendOverride` and fail closed with
`ExtractionServicesError.unavailable` when none is supplied. Production is
unchanged: `ProcessExtractionServices` resolves defaults through the route
records, and the Extract wiring already read
`ExtractionConfig.htmlSelectionLabel`, not the retired field.

Tests that asserted `config.backend` or `config.htmlBackend` were removed or
rewritten to assert the migration and the fail-closed contract. The
`WikiStoreModel.htmlBackend` doc comment now names the real injection
source (`htmlSelectionLabel`).

## Verification

- `rg 'htmlBackend|\.backend\b' Sources` shows no `ExtractionConfig` field
  readers. The remaining matches are unrelated properties, Codable keys of
  other types, and comments.
- `make build` passes.
- `make test` passes: 4041 tests in 430 suites.
- `WIKIFS_APP_TESTS=1 swift test --filter ExtractionCoordinatorTests`
  passes: 13 tests. The same run with
  `ExtractorPackageSettingsTests|ExtractionRouteTableHostedTests` passes:
  50 tests in 5 suites.
