---
timestamp: 2026-07-22T024137Z
title: "Fix: published apps signed with Apple Development cert, not Developer ID (#746)"
branch: null
status: historical
timestamp_source: git-commit
---

# Fix: published apps signed with Apple Development cert, not Developer ID (#746)

## Progress


**Symptom:** `make dist` / `make release` signed the `.app` + appex + helpers
with the **Apple Development** cert (local-debug only). notarytool rejects
non-Developer-ID signatures and Gatekeeper rejects the app on other machines,
so a published build used the **wrong key** and wouldn't run/install for end
users. Root cause: `Makefile` `release:` passed `SIGN_IDENTITY="$(DEV_IDENTITY)"`
to `build.sh`, so release builds signed with the dev cert; `setup.sh` only
minted a DEVELOPMENT cert (no Developer ID path existed).

**Fix** (4 files, see `plans/fix-signing-cert.md` for the full spec):
- `signing/setup.sh` — added a §2b block that mints a Developer ID Application
  cert via `asc certificates create --certificate-type DEVELOPER_ID_APPLICATION`
  (best-effort: falls back to printed manual-portal instructions if the account
  isn't authorized for Developer ID), imports it to the login keychain with both
  Developer ID G1/G2 intermediates, and writes `DIST_IDENTITY` to
  `signing/local.config`. Mirrors the existing DEVELOPMENT cert mint+import.
- `signing/local.config.example` — documented `DIST_IDENTITY` (mirrors
  `DEV_IDENTITY`); `CERT_NAME` is now an optional override that defaults to it.
- `build.sh` — identity resolution is now CONFIG-aware: `release` uses
  `SIGN_IDENTITY → DIST_IDENTITY → ad-hoc`, `debug` uses `SIGN_IDENTITY →
  DEV_IDENTITY → ad-hoc`. Release does **not** fall back to `DEV_IDENTITY`
  (that was the bug — a release silently picked up the dev cert).
- `Makefile` — added `DIST_IDENTITY` (from `local.config`); `release:` now
  passes `SIGN_IDENTITY="$(DIST_IDENTITY)"`; `CERT_NAME` (used by `make sign`)
  resolves from `DIST_IDENTITY` (backwards-compat: a hand-set `CERT_NAME` still
  wins).

**Cert-type correction:** the issue body suggested `--certificate-type
DISTRIBUTION`, but that mints an **Apple Distribution** cert (for App Store
submission), not a Developer ID Application cert. Used
`DEVELOPER_ID_APPLICATION` (the correct API type) so the minted cert is
actually a Developer ID Application cert (matches the `grep 'Developer ID
Application:'` lookup and the acceptance criterion `Authority=Developer ID
Application: ...`).

**Acceptance:** `make build` (local) still uses `DEV_IDENTITY` → no dev-loop
regression. `make release` / `make dist` now sign all nested components with
`DIST_IDENTITY` inside-out; `make sign` re-signs the outer app with the same
identity + hardened runtime + timestamp for notarization. If `DIST_IDENTITY` is
unset, `make sign` fails loudly (CERT_NAME resolves to a cert not in the
keychain) rather than silently shipping with the dev cert. `swift build` passes
(no Swift changes — all 4 files are shell/Makefile/config).

**Files:** `signing/setup.sh`, `signing/local.config.example`, `build.sh`,
`Makefile`, `plans/fix-signing-cert.md`.

## Verification

Historical verification remains in the progress record above.
