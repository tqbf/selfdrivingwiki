---
timestamp: 2026-09-12T163300Z
title: Canonicalize ACP JS-adapter launches through the resolved bun (#1257 Level 1)
branch: feature/acp-adapter-bun-canonicalization
status: complete
---

# Canonicalize ACP JS-adapter launches through the resolved bun (#1257 Level 1)

## Progress

ACP provider commands are user-configured free-form text, and JS adapters
launched through `npx` depended on the user's node/npm state — the first
wrapped chat died on an `EPERM` write to `~/.npm/_cacache` under the seatbelt.

`ACPBackend.startProcess` now canonicalizes adapter-shaped commands —
executable basename `npx`, `bunx`, `npm exec`/`npm x`, or an already-`bun x`
launch — through the bun resolved via `RuntimeCommandLocator` (the extractor
runtimes' login-shell locator), as `<bun> x <package spec...>`. The shape gate
runs first, so plain provider binaries (claude, codex, gemini) never pay for
the locate. Resolution is memoized per backend actor, including the negative
case (`RuntimeCommandResolution??` — a bun-less machine pays one 10 s-enclosed
locate, not one per start), and a cached resolution is re-probed through
`RuntimeFileProbe` before reuse so a swapped binary invalidates the cache per
the locator's identity contract. An unresolvable bun keeps the configured
command, logged in the agent channel. `ACPProviderModelProbe` applies the same
canonicalization so its cached model list comes from the runtime chat will
actually run. Review findings addressed: M1 (shape gate + negative caching),
M2 (agent-channel fallback log), M3 (probe canonicalization), m1 (log names
old → new command), m2 (`bun x` repoint), m3 (`npm x` alias), m4 (identity
retention + re-probe), m5 (`canonicalizedSpawn` pure + field-preservation
tests), m6 (`-y`/`--yes`/`--` runner-flag stripping, pinned). Level 2
(vendored digest-pinned adapter in `Contents/Helpers/`) remains open on
#1257.

## Verification

- `make build`, `make test` (4374 tests / 469 suites), bare `swift build`:
  green.
- `WIKIFS_APP_TESTS=1 swift test --filter ACPWiringTests`: 30 passed —
  including the adapter-canonicalization suite (npx rewrite with full
  field preservation, npm exec/x aliases and runner-flag stripping, `bun x`
  repoint, non-adapter and missing-bun pass-throughs, shape-gate table,
  `~/.npm` layering for the unresolved-bun fallback).
- Reviewed by a Paseo Claude Opus agent (read-only, plan mode): verdict
  "no CRITICAL findings"; three MAJOR and six MINOR findings, all addressed
  above; its clean-area list (spawn rebuild lossless, seatbelt gate
  untouched, launchHint/persisted-data unaffected, spec preservation,
  Sendable) confirmed.

## Notes

- npx/npm runner flags are stripped rather than passed through: bun 1.4.0
  tolerates them, but that leniency is undocumented.
- The `WikiFSApp` launch check asserting a bundled `Contents/Helpers/bun`
  predates this work and always warns on dev machines (bun is mise-managed);
  adjacent, untouched here.
