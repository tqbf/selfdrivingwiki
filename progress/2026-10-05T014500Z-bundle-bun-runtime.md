---
timestamp: 2026-10-05T014500Z
title: Bundle the bun runtime into the app
branch: feature/bundle-bun-helper
status: complete
---

# Bundle the bun runtime into the app

## Progress

The app's launch check expects `Contents/Helpers/bun`, and its comment
claims `build.sh` hard-fails when bun is absent. Neither was true:
`build.sh` never copied bun, no gate enforced it, and every launch logged
`⚠️ LAUNCH CHECK: bun NOT found in Contents/Helpers`. Ingestion still
worked because the daemon's login-shell locator resolved the
mise-installed bun at runtime — a silent dependency on the dev
environment that breaks on a clean machine.

`build.sh` now bundles bun:

- A resolution gate runs BEFORE `swift build` so a machine without bun
  fails in seconds. Order: explicit `BUN_BIN`, then `mise which bun`
  (mise.toml pins 1.4.0), then PATH.
- A resolution that is a script or sits under a `shims/` directory is a
  hard error. Modern mise shims are compiled Mach-O binaries, so `file`
  cannot distinguish them from the real runtime; the path check catches
  them.
- The binary is copied into `Contents/Helpers/bun`, covered by the
  bundled-helper contract, and signed inside-out in both the real
  identity and ad-hoc branches.

Runtime behavior is unchanged. The login-shell locator still resolves
bun for development; the bundle makes the shipped app self-contained and
silences the launch warning on real installs.

Closes the bun observation noted in issue #1364.

## Verification

- Negative: `BUN_BIN` set to a script, to a mise shim, and to a missing
  path each fails fast with exit 1 and a clear message.
- `make build` passed. The bundle contains `Helpers/bun` (Mach-O arm64,
  63.5 MB), runs (`--version` → 1.4.0), and the helper contract verifies.
- `codesign --verify --deep --strict` passes and explicitly validates
  `Contents/Helpers/bun`.
- `make test` passed (default graph, 0 failed runs).
