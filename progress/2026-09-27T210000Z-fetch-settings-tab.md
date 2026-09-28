---
timestamp: 2026-09-27T210000Z
title: Fetch settings tab — package roles get their own Settings surface
branch: feature/fetch-settings-tab
status: complete
---

# Fetch settings tab — package roles get their own Settings surface

## Progress

Split the package Settings surface by role: **Settings → Extraction** lists
extractors only, and the new **Settings → Fetch** tab owns the installed
fetcher package list and the **Default Fetchers** route table. One view type
(`ExtractionSettingsView`) presents both through an `ExtractionSettingsRoleFocus`
parameter — presentation only; acquisition behavior still comes from
registration claims (`FetchRouteDecision`), never from the focus.

- Both tabs share ONE factory (`WikiFSApp.packageSettingsView(roleFocus:)`) so
  snapshot, credential, import, and removal wiring cannot drift.
- `FocusPresentation` holds COMPLETE per-focus string/id literals (no noun
  interpolation), so the extractor arm's source-contract-pinned literals stay
  byte-identical while the fetch arm gets its own `fetch.*` families.
- Installed package rows filter on `row.role`; FAILED revisions bypass the
  filter and appear in both tabs (no registration → no role to filter on).
- The Fetch tab renders its own route table (`TableColumn("Default
  fetcher")`); the ACP provider section is gated to the extractors focus so
  extractor-scope configuration never leaks into Fetch.

## Verification

`make test` full suite green; `WIKIFS_APP_TESTS=1 swift test` for the hosted
suites (`FetchSettingsHostedTests` new — 5 tests including the ACP-absence
regression and the role-filter model contract; `ExtractionRouteTableHostedTests`
row count returned to 7 and pins the fetch id families; all extractor
settings suites pass). SwiftLint clean.
