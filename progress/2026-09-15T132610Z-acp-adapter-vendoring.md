---
timestamp: 2026-09-15T132610Z
title: Vendor the Claude ACP adapter into Contents/Helpers (#1257 Level 2)
branch: feature/acp-adapter-vendoring
status: complete
---

# Vendor the Claude ACP adapter into Contents/Helpers (#1257 Level 2)

## Progress

Level 1 (#1258) canonicalized `npx` / `npm exec` / `bunx` / `bun x` adapter
launches to run through the login-shell-resolved bun. Level 2 finishes the
issue: the Claude ACP adapter (`@agentclientprotocol/claude-agent-acp`)
ships as a digest-pinned single-file bundle in the app, and the canonical
adapter launch is rewritten once more to
`<resolved-bun> run <Helpers>/claude-acp-adapter.js` — the package runner
disappears from the launch, so no `~/.npm` / `~/.bun` cache path is ever
consulted (and the sandbox layers no allowance for them), and the adapter
itself runs under bun.

Shape of the change:

- **Vendor dir** `tools/claude-acp-adapter/` (`package.json` pin,
  committed `bun.lock`, gitignored `node_modules`, `build.mjs`,
  `verify.mjs`) following the `tools/markdownlint-vendor/` model.
  `bun build --target=bun` of the adapter's `dist/index.js` produces a
  3.2 MB single file; the verify script spawns `bun run <bundle>` and
  completes an ACP `initialize` handshake (protocol version 1) over stdio,
  which retired the "dynamic `require` breaks the bundle" risk immediately.
- **Provenance gate** `scripts/sync-acp-adapter.sh` (`sync` / `--check`),
  following the `sync-extractor-packages.sh` model: ONE hand-editable
  version variable generates every record (`adapter.lock.json` with npm
  tarball URL + SHA-512 dist.integrity + legacy dist.shasum + sha256 of
  package.json / bun.lock / bundle; the `package.json` dependency pin; the
  generated `Sources/WikiFSEngine/VendoredAdapterPin.swift`). `--check`
  uses no network and no bun, and the `acp-adapter` make target gates
  `check`, `build`, `release`, `check-release`, and `test` — the same
  targets `extractor-packages` gates.
- **Launch rewrite** in `ACPBackend`: pure `vendoredAdapterRewrite` (matches
  only the vendored spec, bare or pinned at exactly the compiled version)
  composed through the new pure `effectiveAdapterSpawn` (Level 1 → Level 2 →
  configured fallback), consumed by `startProcess`. The composition output
  keeps carrying `usedCanonicalBun` / `bunResolutionUsed`, so the existing
  pinned-bun staleness fallback is unchanged. `vendoredBundlePath` is an
  injectable seam on the initializer (default
  `HelpersLocation.bundledHelperPath("claude-acp-adapter.js")`), mirroring
  the `resolveBunRuntime` / `probeExecutable` seams.
- **`HelpersLocation.bundledHelperPath`** gained an internal
  candidate-directories + FileManager overload so the candidate walk is
  fixture-testable; the public method delegates unchanged.
- **`build.sh`** stages the committed `Resources/claude-acp-adapter.bundle.js`
  into `Contents/Helpers/claude-acp-adapter.js` + `build/` (dev path),
  `chmod +x`, and signs it in both the identity and ad-hoc codesign branches
  (Helpers is a code location — same as pdf2md/defuddle).
- **`WikiFSApp`'s startup launch check** now warns when the vendored adapter
  is missing instead of `bun` (toolchain runtimes are mise-managed and never
  packaged, so the old check fired on every healthy install).

Decisions:

- The bundle is **not** minified — it is a reviewed artifact, matching the
  markdownlint and extractor bundle precedents (the plan text mentioned
  `--minify`; reviewability wins, recorded here and in the plan doc).
- 0.77.0 is still npm latest (only previews above it); the pin is deliberate
  and the bump flow is documented but not exercised against a newer stable.
- Codex-acp vendoring and the `ACPProviderModelProbe` seam are deliberate
  non-goals (documented follow-ups); settings free-form stays the escape
  hatch.
- Known coverage gap (accepted in the plan): the fresh-machine
  zero-home-write property has no automated end-to-end harness. It is pinned
  at the unit level (`vendoredCommandLayersNoHomeSubpaths` proves the
  rewritten command layers no npm/bun allowance in the full wrapped
  seatbelt plan) and flagged for a manual
  `FreshMachineVendoredClaudeACPScenario` run.

## Verification

- `tools/claude-acp-adapter/verify.mjs` — `✓ ACP initialize handshake:
  protocol version 1 confirmed by @agentclientprotocol/claude-agent-acp`
  (bundle speaks ACP under the exact production launch shape).
- `./scripts/sync-acp-adapter.sh --check` executed in all four states:
  fresh checkout → exit 0; hand-edited bundle → exit 1 (digest mismatch);
  stale version variable → exit 1 (five findings); hand-edited package.json
  pin → exit 1. Usage error → exit 2.
- `make -n check build release check-release test` — each prints the
  `sync-acp-adapter.sh --check` prerequisite; `make acp-adapter` exit 0.
- Rebuild determinism: two consecutive `bun build.mjs` runs from the fixed
  tool directory produced byte-identical bundles; `bun install
  --frozen-lockfile` passes against the committed lock.
- `make check` — compiles (including the generated Swift pin and the
  `WikiFSApp` launch-check rewrite). `make lint` — 0 violations in 676
  files.
- `swift test --build-system native` (default graph): **4437 tests in 475
  suites passed, 0 issues** — includes the existing Level 1 suite unchanged
  plus the new `HelpersLocationTests` (4).
- `WIKIFS_APP_TESTS=1 swift test` (the opt-in app-test graph where the ACP
  suites live): `ACPWiringTests` (7 new tests) and `AdapterVendoringLockTests`
  (3) pass. NOTE: ~10–11 OTHER suites in that opt-in graph fail identically
  with the branch stashed (verified by experiment) — pre-existing on this
  machine's Xcode 6.4 toolchain (wrong-value assertions in the first wave of
  suites, no runner summary). Not touched by this branch; flagged for the
  operator.
- Environment notes for future agents: Xcode jumped 6.3.3 → 6.4 mid-session;
  6.4 defaults SwiftPM to the `swiftbuild` build system whose products no
  longer land in `.build/<triple>/debug`, which breaks the fixture-locating
  suites (RaceFreeProcessGroupRunnerTests, IdentifierBoundaryTypecheckTests,
  RendererAssetReferenceExtractorHelperTests) under the default build system.
  `--build-system native` (deprecated but functional) reproduces the old
  layout and a green default-graph run.
- Remaining for the PR: `make build` + `codesign -dv` on the staged helper
  (AC.5's packaged-app observable), manual
  `FreshMachineVendoredClaudeACPScenario` (flagged operator validation).

## Implementation review

Dispatched per the plan: `general-purpose` subagent, read-only diff review,
reported its family as **GPT/OpenAI** (review-model-diversity: GLM authored,
GPT-family reviewed — cross-family holds). Verdict: request-changes; all
four findings addressed:

- **MEDIUM (fixed):** offline sync previously reused the committed lock's
  dist fields when the registry was unreachable, so a format-valid but wrong
  hand edit could be blessed. `ADAPTER_DIST_INTEGRITY` /
  `ADAPTER_DIST_SHASUM` are now authored constants in the sync script (same
  single source of truth); sync cross-checks them against the live registry
  when reachable (hard error on mismatch; a bump with an unreachable
  registry is a hard error); `--check` compares the committed lock's dist
  fields against the constants EXACTLY. Verified: a hand-edited
  format-valid `distIntegrity` now fails `--check`.
- **LOW (fixed):** `--check` gained a second layer — the writers re-render
  all three generated records into a temp dir and byte-compare with the
  committed files, so extra keys / changed comments / formatting drift fail
  (verified with an injected `sneakyExtra` key and an edited pin comment).
- **LOW (fixed):** added `vendoredAdapterRewriteRejectsNonCanonicalShapes`
  (no argv, `x` without spec, already-`run` argv, non-`bun` executable,
  empty spec) and hardened `AdapterVendoringLockTests.provenanceMetadata…`
  to compare the lock's dist fields against the script's constants.
- **NIT (rebutted):** trailing whitespace on 4 whitespace-only blank lines
  of the generated bundle. Left as bun emitted them: the digest pins the
  bundler's canonical output, normalizing would add a post-processing step
  between bun and the reviewed bytes for zero functional gain, and no repo
  gate runs `git diff --check`. Documented in the plan doc.

Post-fix verification: `--check` fresh → 0; tampered dist field / extra key /
edited pin comment → 1; restored → 0. `AdapterVendoringLockTests` +
`ACPWiringTests` (now 8 Level 2 tests) pass. `make lint` clean.
