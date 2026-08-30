---
timestamp: 2026-08-30T001336Z
title: Separate extractor package import settings
branch: feature/separate-local-package-import
status: complete
---

# Separate extractor package import settings

## Progress

The Extraction settings page now shows local package import in its own top-level
section. The Installed Extractor Packages section now contains package lifecycle
controls and package rows only.

The import disclosure, directory picker, trust warning, mutation gates, and
accessibility identifiers remain unchanged. Read-only and headless views still
hide the import section when the app does not provide an import action.

## Verification

- `git diff --check` passed.
- LSP reported no diagnostics for `ExtractionSettingsView.swift`.
- `make build` passed.
- `WIKIFS_APP_TESTS=1 swift test --filter ExtractorPackageSettingsTests` passed
  with 21 tests.
- An initial `make test` run reached 3,974 tests and found one transient
  filesystem failure in
  `ProcessExtractorProviderTests/pdfConversionPreservesCancellationIdentity`.
- The provider test passed when rerun alone with
  `swift test --filter ProcessExtractorProviderTests/pdfConversionPreservesCancellationIdentity`.
- A final `make test` run passed all 3,974 tests in 424 suites.
