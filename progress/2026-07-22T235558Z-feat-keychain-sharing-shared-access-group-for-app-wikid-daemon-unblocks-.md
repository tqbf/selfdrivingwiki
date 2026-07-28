---
timestamp: 2026-07-22T235558Z
title: "feat: Keychain sharing — shared access group for app + `wikid` daemon (unblocks daemon Phase B/C)"
branch: null
status: historical
timestamp_source: git-commit
---

# feat: Keychain sharing — shared access group for app + `wikid` daemon (unblocks daemon Phase B/C)

## Progress


**Goal:** let the `wikid` daemon read the ACP/Extraction/Zotero API keys the app
wrote to the Keychain — the #1 real-world snag risk for the daemon migration.
Moves `KeychainSecretStore` to the DataProtection keychain under a shared
`keychain-access-groups` access group; signs the daemon with the entitlement it
needs. The R1 spike (daemon launches with `keychain-access-groups`) already
PASSED; this is the code + build wiring. See `plans/keychain-sharing.md`.

**What changed:**
- **Compile-time access group (no runtime `Bundle.main` lookup; per-developer,
  NEVER hardcoded to one developer's slug):** new codegen
  `tools/keychaingen/main.swift` (mirrors `tools/versiongen`) reads
  `signing/local.config` — an explicit `KEYCHAIN_ACCESS_GROUP` override wins,
  else derives `<TEAM_ID>.<APP_GROUP with 'group.' stripped>`. Writes the
  gitignored `Sources/WikiFSCore/GeneratedKeychain.swift`
  (`public static let accessGroup`). Same constant reaches app + daemon via the
  `WikiFSCore` dependency. Empty when `signing/local.config` is absent (fresh
  clones / CI / `swift test`) → "no group" → legacy file-keychain behavior
  preserved. New `make keychain` target (prereq of build/check/test, alongside
  `version`/`prompts`); CI runs `make version prompts keychain`; `.gitignore`
  excludes the generated file. **`build.sh` and the Makefile derive the SAME
  value (same formula, same override) for the generated entitlements**, so app,
  daemon, and code agree for ANY developer (mirrors how `APP_GROUP`/`BUNDLE_ID`
  are handled per PR #20). `signing/local.config.example` documents the
  optional override.
- **`KeychainSecretStore`** (`Sources/WikiFSCore/Core/KeychainSecretStore.swift`):
  made `public enum` (mirrors `public enum DatabaseLocation`); a shared internal
  `baseQuery(service:account:useDP:accessGroup:)` conditionally adds
  `kSecUseDataProtectionKeychain: true` (when `useDP`) and `kSecAttrAccessGroup`
  (when non-empty) to EVERY read/delete/update/add query. Public
  `read`/`write` route to an internal primitive using the resolved group; the
  three `Keychain*CredentialStore` conformers are unchanged (same public API).
  One-shot, idempotent `migrateLegacyItemsToDataProtection()` (called from
  `WikiFSApp` launch, next to `DatabaseLocation.migrateFromApplicationSupportIfNeeded`)
  copies legacy file-keychain items (service prefix `org.sockpuppet.WikiFS.`)
  onto the DP keychain under the shared group, then deletes the legacy original —
  best-effort, never loses a key, a no-op when no group is configured.
- **`build.sh`:** derives `KEYCHAIN_ACCESS_GROUP="${KEYCHAIN_ACCESS_GROUP:-${TEAM_ID}.${APP_GROUP#group.}}"`
  (per-developer, same formula as the codegen); adds `keychain-access-groups` to
  the **app** entitlements heredoc; and — the load-bearing build fix — signs
  `wikid` WITH `--entitlements "${WIKID_ENTITLEMENTS}"`, a **newly-generated
  per-developer** `build/wikid.entitlements` (heredoc, using `${APP_GROUP}` +
  `${KEYCHAIN_ACCESS_GROUP}`), mirroring how the app/extension entitlements are
  generated (production previously signed the daemon with no entitlements). The
  FileProvider extension is NOT given the entitlement (it doesn't touch the
  Keychain; adding it would risk AMFI killing the sandboxed extension).
- **Deleted the committed `signing/wikid.entitlements`**: it was baked to ONE
  developer's App Group + access-group suffix, so it would break for anyone
  else. The daemon entitlements are now generated at build time (PR #20 pattern —
  no committed static `.entitlements`). The `Makefile` dev path (`install-daemon`)
  generates the same file inline. For the operator's machine the generated
  content matches the R1-spike-verified value, so that result still holds.

**Evidence:** `swift build` (full, all targets incl. app + MLX + `wikid`) clean;
`swift test` — 3668 tests in 304 suites passed. New
`Tests/WikiFSTests/KeychainSecretStoreTests.swift` (3 tests, `#if os(macOS)`)
asserts the `baseQuery` shape (DP flag + access group present when configured,
absent in the legacy path) — deterministic and non-polluting, matching the
sibling `*CredentialStoreTests` convention (real-Keychain + access-group behavior
+ the migration are documented as a manual integration runbook in
`plans/keychain-sharing.md §5.2`; they need a real entitled signed build and
can't round-trip in `swift test`).

**Not done (manual, human-only):** the §5.2 integration runbook — `make build`
(real signing), enter an ACP key, confirm the item's `agrp` via `security
find-generic-password`, run a daemon ACP workload end-to-end, and the negative
control (drop the daemon entitlement → `errSecMissingEntitlement`). Portal
"Keychain Sharing" capability is optional (the `<TEAM_ID>.*` profile wildcard
already authorizes it; R1 spike passed).

## Verification

Historical verification remains in the progress record above.
