---
timestamp: 2026-08-07T202800Z
title: Dynamic renderers Phase 7 management
branch: feature/dynamic-renderers-07-management
status: active
issue: 1026
phase: 7
---

# Dynamic renderers Phase 7 management

## Progress

Commit `a329e877` adds the native Renderers settings workflow on top of the existing package and wiki stores. Commit `30ea96cc` adds the settings-surface contract test. Commit `4feec364` retains a redacted removal tombstone while deleting the package payload and allows the machine index to read that intentional no-payload state. Commit `e80f0018` corrects settings diagnostic interpolation and the management section heading. Commit `924ecc81` repairs the settings adapter when the active wiki changes, hides removed tombstones from installed controls, normalizes the source picker to a valid source, validates removal paths before mutation, and surfaces payload cleanup failures as explicit diagnostics.

The settings tab shows two scopes. “Installed on This Mac” reports package versions from the machine index. “Enabled for This Wiki” writes only the current wiki enablement row.

Installation accepts one local directory. The existing validator copies and validates the directory before the machine store activates it. Files and archives remain rejected by the picker and by the selection boundary.

Removal retains a redacted `.removed` machine record and deletes the package payload. It does not delete source data or wiki renderer preferences. Safe-mode reset and registry refresh use the existing host. A source version choice writes an exact typed renderer preference, so it does not replace an active pane pin. A removed tombstone retains its expected hash as a fail-closed reservation; reinstalling the same package ID/version must use the same reviewed package hash.

## Verification

- Observed: bare `swift build --jobs 4` passed.
- Observed: `make build` passed, including app assembly and signing.
- Observed: `make test` passed 3,256 tests in 292 suites.
- Observed: bare `swift build --jobs 4` passed.
- Observed: bare `swift test --jobs 4` passed 3,256 tests in 292 suites.
- Observed: `WIKIFS_APP_TESTS=1 swift test --filter 'RendererSettingsManagementViewTests|RendererSettingsPackagePickerTests' --jobs 4` passed two tests.
- Observed: `swift test --filter RendererSettingsManagementTests --jobs 4` passed two tests, including the removed-tombstone contract.
- Observed: the pre-commit lint hook reported zero violations and no new bare `try?` use for both commits.
- Observed: `git diff --check` passed before each commit.
- Observed: the inventory bidirectional resolver passed after adding the removed-tombstone validator path.
- Observed: opted-in settings/picker tests passed again after the diagnostic and heading correction.
- Hosted Settings window validation and PR CI remain pending. The first independent Phase 7 review requested changes; the repaired candidate requires a fresh review.

## Limits

The focused settings test checks the source contract and the machine removal boundary. It does not host a SwiftUI Settings window or exercise real VoiceOver output.

The source-version controls require an open wiki session. They write an exact source preference. They do not rewrite machine records or replace active renderer session pins.

The inventory maps the implementation and focused tests to the Phase 7 branch. It does not claim final PR readiness.
