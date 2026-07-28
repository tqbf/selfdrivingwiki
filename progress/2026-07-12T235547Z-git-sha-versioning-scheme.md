---
timestamp: 2026-07-12T235547Z
title: "2026-07-12 — Git SHA versioning scheme"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-07-12 — Git SHA versioning scheme

## Progress


Replaced the `0.0.0-dev` placeholder versioning with a git-derived scheme so
every build is uniquely identifiable. The old scheme resolved `VERSION` from a
tag or `VERSION` file, fell back to `0.0.0-dev`, and wrote the same value into
both `CFBundleShortVersionString` and `CFBundleVersion` — no SHA, no commit
count, every dev build indistinguishable.

**Version scheme:** `CFBundleShortVersionString` = SemVer (tag/`VERSION`
file/`0.0.0`), `CFBundleVersion` = `<commit-count>-<short-sha>` (e.g.
`487-d440699`). Monotone integer for Apple's build-number expectations, SHA
baked in for traceability.

**Two codegen paths:**
1. `tools/versiongen/main.swift` → `Sources/WikiFSCore/GeneratedVersion.swift`
   (checked-in Swift constants: `appVersion`, `gitSHA`, `gitCommitCount`,
   `buildVersion`, `fullVersionString`). Mirrors the `promptgen` pattern:
   `make version` regenerates; `make check-version-gen` is the CI drift gate;
   the generator only writes when content changes (no spurious recompiles).
2. `build.sh` resolves `VERSION` + `BUILD_VERSION` + `GIT_SHA` +
   `GIT_COMMIT_COUNT` and writes them into both Info.plists (app + appex),
   including custom `WIKIGitSHA` / `WIKIGitCommitCount` / `WIKIBuildVersion`
   keys for runtime query.

**Makefile:** `version` and `check-version-gen` targets added; `build`,
`check`, `test`, `release` now depend on `version`. `print-version` enhanced
to show SHA + commit count + build version.

**wikictl:** `version` / `--version` / `-v` subcommand prints build info (plain
text or `--json`). Intercepted before wiki selector requirement — no `--wiki`
needed. Added `.version(json:)` to `ArgumentParser.Command`.

**App:** `ACPBackend` now sends `GeneratedVersion.appVersion` as the ACP client
version (was hardcoded `"1.0.0"`). New `AboutView` added as the first Settings
tab showing app icon, name, version, build, git SHA, and commit count.

**Files changed:**
- `tools/versiongen/main.swift` (new — 120 lines)
- `Sources/WikiFSCore/GeneratedVersion.swift` (new — generated)
- `Sources/WikiCtlCore/ArgumentParser.swift` (`.version` case, parse intercept, usage text)
- `Sources/wikictl/main.swift` (version print + exhaustive switch case)
- `Sources/WikiFS/ACPBackend.swift` (hardcoded `"1.0.0"` → `GeneratedVersion.appVersion`)
- `Sources/WikiFS/AboutView.swift` (new)
- `Sources/WikiFS/WikiFSApp.swift` (About tab in Settings TabView)
- `Makefile` (versiongen variables, targets, prerequisites, help, print-version)
- `build.sh` (BUILD_VERSION, GIT_SHA, GIT_COMMIT_COUNT, Info.plist keys)
- `PLAN.md` (Versioning section)

**Gates:** 2354 tests pass (fast tier). `make check-version-gen` passes. `make
version` + `make print-version` work. `wikictl version` / `--version` / `-v` /
`version --json` all produce correct output. `swift build` clean.

## Verification

Historical verification remains in the progress record above.
