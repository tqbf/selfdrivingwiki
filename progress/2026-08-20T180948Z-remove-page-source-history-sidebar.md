---
timestamp: 2026-08-20T180948Z
title: Remove page and source history from the right sidebar
branch: feature/remove-sidebar-page-source-history
status: complete
---

# Remove page and source history from the right sidebar

## Progress

Page and source detail views now expose only Metadata and Outline in the right sidebar.
Sources without an outline expose Metadata only. Legacy History selections fall back to Metadata.

## Verification

The focused app test run passed 15 tests:

```text
WIKIFS_APP_TESTS=1 swift test --filter InspectorTabTests
```

The required build and test gates passed:

```text
make build
make test
```

`make test` passed 3,486 tests in 337 suites. `git diff --check` passed.
