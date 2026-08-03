# Fix: published apps signed with Apple Development cert (not Developer ID Application) — #746

> Source spec for this work. Issue #746 body, verbatim.

## Bug: published apps are signed with an Apple Development cert (not a Developer ID Application cert)

### Symptom
Published/distributed `.app` builds (e.g. via `make dist` / the notarization
pipeline) are signed with an **"Apple Development"** certificate. This cert is
**local-debug only**:
- Gatekeeper rejects the app on other machines.
- It **cannot be notarized** (notarytool rejects non-Developer-ID signatures).
So a published app signed today uses the **wrong key** and won't run/install for
end users.

### Root cause
`signing/setup.sh:84` mints the developer certificate with:
```sh
asc certificates create --certificate-type DEVELOPMENT --generate-csr \
  --common-name "Self Driving Wiki Dev" ...
```
`--certificate-type DEVELOPMENT` produces an **"Apple Development"** certificate
(`signing/local.config` `DEV_IDENTITY` resolves to
`"Apple Development: Created via API (9W5F26LY3S)"`; the login keychain holds
only that one identity — no Developer ID cert is installed).

`build.sh:317` resolves the codesign identity as
`IDENTITY="${SIGN_IDENTITY:-${DEV_IDENTITY:--}}"`
and signs every target (app, appex, helpers) with `--sign "${IDENTITY}"`
(`build.sh:382,389,394,400,405,409`). The `Makefile` `dist`/`release`/`notarize`
targets pass `SIGN_IDENTITY` from `DEV_IDENTITY` (the dev cert), so release
builds sign with the Development cert → wrong key.

### The fix (spans 3 files)
1. **`signing/setup.sh`** — add a **DISTRIBUTION cert mint path** alongside the
   existing DEVELOPMENT path:
   ```sh
   asc certificates create --certificate-type DISTRIBUTION --generate-csr \
     --common-name "Developer ID Application: Self Driving Wiki" ...
   ```
   Keep the DEVELOPMENT cert for local dev (`make build` / `make run`); add a
   separate mint + import for the Developer ID Application cert and a
   `DIST_IDENTITY` lookup (`grep 'Developer ID Application:'`).
2. **`signing/local.config` / `local.config.example`** — add a `DIST_IDENTITY`
   variable (the Developer ID Application cert name), mirroring `DEV_IDENTITY`.
3. **`build.sh`** — resolve `DIST_IDENTITY` alongside `DEV_IDENTITY`; use
   `DIST_IDENTITY` for the `dist`/release path (keep `DEV_IDENTITY` for local
   builds). Mirror the `security find-identity` validation + ad-hoc fallback.
4. **`Makefile`** — wire `dist` / `release` / `notarize` / `zip-notary` to pass
   `SIGN_IDENTITY=$(DIST_IDENTITY)` so release builds sign with the Developer ID
   cert (not the dev cert).

### Prerequisite (manual, Apple-portal step — cannot be automated)
A **Developer ID Application** certificate must be issued from the Apple
Developer account (App Store Connect → Users and Access → Certificates →
"Developer ID Application"). `setup.sh` can mint it via `asc certificates create
--certificate-type DISTRIBUTION` **only if** the account is authorized; otherwise
create it in the portal, download the `.cer`, and import to the login keychain
(the existing `security import` block in `setup.sh:96` is the model).

### Acceptance
- `make build` (local) still signs ad-hoc / with the Apple Development cert
  (no regression to dev workflow).
- `make dist` signs the `.app` + appex + helpers with the **Developer ID
  Application** cert; `make notarize`/`staple` succeed without a signature-type
  rejection.
- `codesign -dvvv` on the built `.app` shows `Authority=Developer ID
  Application: ...` (not `Apple Development: ...`).
- `signing/local.config.example` documents the new `DIST_IDENTITY` variable.

### Notes
- The release/notarization pipeline is documented as "wired but unused until v0
  ships" (`Makefile:12-14`) — so this is a forward-looking fix, but it's the
  blocker the moment a v0 ship is attempted.
- Related but distinct: the App Group / bundle-id key resolution
  (`build.sh:249,303,307` `WIKIAppGroupID=${APP_GROUP}`) is per-developer and
  correct; only the **codesign identity** is wrong here.

---

## Implementation notes (added during implementation)

### Cert type clarification
The issue body suggests `--certificate-type DISTRIBUTION` to mint a Developer ID
Application cert. The App Store Connect API's `DISTRIBUTION` type produces an
**"Apple Distribution"** cert (for App Store submission), **NOT** a "Developer ID
Application" cert. For Developer ID Application (direct-download / notarized
distribution outside the App Store), the correct API certificate type is
`DEVELOPER_ID_APPLICATION`. This implementation uses `DEVELOPER_ID_APPLICATION`
so the minted cert is actually a Developer ID Application cert (matching the
`grep 'Developer ID Application:'` lookup and the acceptance criterion:
`Authority=Developer ID Application: ...`). Minting is best-effort — if the
account isn't authorized for Developer ID certs via the API, the script falls
through to printed manual-portal instructions (create in portal, download `.cer`,
import to login keychain). See `plans/signing.md` for the manual checklist.

### Identity precedence (build.sh)
- **Debug/local builds (`make build`, `./build.sh debug`):** `SIGN_IDENTITY` →
  `DEV_IDENTITY` → ad-hoc `-`. No `DIST_IDENTITY` fallback — a local debug build
  must never silently pick up the distribution cert.
- **Release/dist builds (`make release`, `make dist`, `./build.sh release`):**
  `SIGN_IDENTITY` → `DIST_IDENTITY` → ad-hoc `-`. Does **not** fall back to
  `DEV_IDENTITY` — falling back to the Apple Development cert would reintroduce
  #746. Ad-hoc `-` is the only fallback (and `make sign` then re-signs the outer
  app with Developer ID + hardened runtime + timestamp for notarization).

### Makefile wiring
- `build:` passes `SIGN_IDENTITY="$(DEV_IDENTITY)"` (unchanged — local dev).
- `release:` passes `SIGN_IDENTITY="$(DIST_IDENTITY)"` (was `$(DEV_IDENTITY)` —
  the bug). `build.sh` then signs all nested components (appex, helpers) with
  Developer ID inside-out, and `make sign` re-signs the outer app with the same
  identity + `--options runtime` + `--timestamp` (notarization-ready).
- `CERT_NAME` (used by `make sign`) now resolves from `DIST_IDENTITY` (with
  backwards-compat: a hand-set `CERT_NAME` in `local.config` still wins).
- `zip-notary` / `notarize` / `staple` don't call `build.sh` (they zip / submit /
  staple only), so they need no `SIGN_IDENTITY` — they inherit the
  `release`→`sign` dependency chain.
