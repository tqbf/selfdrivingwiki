---
timestamp: 2026-06-29T151010Z
title: "2026-06-29 — `WikiIdentifiers` reads `signing/local.config` (debug wikictl just works)"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-06-29 — `WikiIdentifiers` reads `signing/local.config` (debug wikictl just works)

## Progress


The plain SwiftPM CLI (`.build/debug/wikictl`) resolved the **wrong** App Group
(`group.org.sockpuppet.wiki`, empty) while the live data lived in
`group.com.willsargent.wiki`: it has no Info.plist (so the `WIKIAppGroupID`
lookup missed) and no `wiki-identifiers.env` sidecar, so it fell through to the
compiled-in default. The GUI app was unaffected (it gets the value from its
Info.plist via `build.sh`).

**Fix:** added `signing/local.config` (the gitignored, per-developer file that
`build.sh` already reads) as a resolution step in `WikiIdentifiers.resolve`,
checked by walking UP from the executable until a repo root containing it is
found. `appGroupID` ← `APP_GROUP`, `fileProviderID` ← `EXT_BUNDLE_ID`. New order:
env → Info.plist → `wiki-identifiers.env` sidecar → `signing/local.config` →
default. Refactored the shared `KEY=VALUE` parsing into `parseKV`.

**Non-breaking:** no per-user value is committed. Fresh clones / CI without
`signing/local.config` fall through to the default unchanged. Verified: `.build/debug/wikictl --wiki "My Wiki" source search --query dissociation` now
returns real hits with NO env var; 1202 tests pass.

## Verification

Historical verification remains in the progress record above.
