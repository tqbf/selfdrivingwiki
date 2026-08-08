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

Commit `a329e877` adds the native Renderers settings workflow on top of the existing package and wiki stores. Commit `30ea96cc` adds the settings-surface contract test.

The settings tab shows two scopes. “Installed on This Mac” reports package versions from the machine index. “Enabled for This Wiki” writes only the current wiki enablement row.

Installation accepts one local directory. The existing validator copies and validates the directory before the machine store activates it. Files and archives remain rejected by the picker and by the selection boundary.

Removal deletes the machine record and package payload. It does not delete source data or wiki renderer preferences. Safe-mode reset and registry refresh use the existing host. A source version choice writes an exact typed renderer preference, so it does not replace an active pane pin.

## Verification

- Observed: bare `swift build --jobs 4` passed.
- Observed: `WIKIFS_APP_TESTS=1 swift test --filter 'RendererSettingsManagementViewTests|RendererSettingsPackagePickerTests' --jobs 4` passed two tests.
- Observed: `swift test --filter RendererSettingsManagementTests --jobs 4` passed two tests.
- Observed: the pre-commit lint hook reported zero violations and no new bare `try?` use for both commits.
- Observed: `git diff --check` passed before each commit.
- The full `make test`, hosted Settings window validation, independent Phase 7 review, and PR CI remain pending.

## Limits

The focused settings test checks the source contract and the machine removal boundary. It does not host a SwiftUI Settings window or exercise real VoiceOver output.

The source-version controls require an open wiki session. They write an exact source preference. They do not rewrite machine records or replace active renderer session pins.

The inventory maps the implementation and focused tests to the Phase 7 branch. It does not claim final PR readiness.
