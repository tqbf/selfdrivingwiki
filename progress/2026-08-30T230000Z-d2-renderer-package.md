---
timestamp: 2026-08-30T230000Z
title: D2 as an installable dynamic renderer package (#1134)
branch: feature/d2-renderer-package
status: complete
---

# D2 as an installable dynamic renderer package (#1134)

## Progress

D2 is now a read-only diagram renderer that installs through the existing
dynamic renderer-package path. The repository ships no D2 bytes: the
committed artifacts are the generator (`scripts/make-d2-renderer-package.sh`),
hand-authored wrapper templates (`tools/d2/index.html`, `d2-viewer.js`),
upstream-derived license/notices inputs (`MPL-2.0.txt`), the provenance lock
(`tools/d2/d2-package.lock.json`), and the driver record
(`tools/d2/DRIVER-NOTES.md`). The package is generated on demand into `tmp/`
(`make d2-renderer-package`) and imported through Settings → Renderers.

Production Swift changed only twice, both format-neutral and pinned by tests:

1. `RendererContentSecurityPolicy.headerValue`: `script-src` gained
   `'wasm-unsafe-eval'` (operator-approved Option A) and `connect-src`
   gained the package scheme, so a package can fetch its own declared,
   hash-pinned assets. Golden-tested in
   `RendererCapabilityBoundaryPolicyTests.packageCSPPinsWASMWithoutNetworkOrigins`.
2. `RendererPackageResourceProvider`'s closed MIME table gained
   `ttf → font/ttf` (woff/woff2 were already present), so a package can carry
   TTF font assets. Pinned by `packageSchemeMIMETableStaysClosed`.

No D2-specific branch exists anywhere under `Sources/`;
`D2SourceNeutralityTests` is the executable guard.

The pinned upstream is **d2lang/d2 v0.8.2** (commit `1c0d93ba…e4f5`), built
locally with a locked recipe (Go 1.27.0, `-trimpath -buildvcs=false`, then
`wasm-opt -Oz` with an explicit feature set) and verified by digest. The
original plan pinned the npm 0.1.33 tarball; that artifact turned out to be
unusable without weakening the security model (details in the plan record and
DRIVER-NOTES), so the pin moved to the eval-free source release. The supply
chain is commit + source tarball digest + build recipe + built artifact
digest, with a corrupt-byte tamper leg proving the gate refuses tampering.

Design decisions worth knowing:

- The package matches by `extensionFallback("d2")` only — no MIME claim, so
  it cannot annex plain-text sources.
- Capabilities are exactly `["inputRead"]`, linkPolicy `none`.
- The wrapper drives the WASM on the main thread (workers stay forbidden).
  D2's theme colors and fonts live in `<style>` elements and style
  attributes inside the rendered SVG, which the CSP refuses; the wrapper
  adopts the stylesheet text via `CSSStyleSheet.replaceSync` +
  `adoptedStyleSheets` and re-applies style attributes through
  `element.style.setProperty`. No new authority is involved.
- Dark appearance uses D2's `darkThemeID: 200`; the SVG adapts through an
  internal `prefers-color-scheme` media query.
- The watchdog (10 s, named constant) is best-effort; a non-yielding hang
  remains covered by the existing failure window → safe mode.

Documentation: design record `plans/d2-renderer-package.md` (indexed in
PLAN.md), driver record `tools/d2/DRIVER-NOTES.md`, policy text updated in
`docs/user-guide/renderer-packages.md` (including the `manifestRevision` →
`revision` example bug), the maintainer skill guide, and
`docs/skills/renderer-package-maintainer/{SKILL.md,references/current-package-guide.md}`.

## Verification

- `make build` — clean build and codesign with the new CSP.
- `make d2-renderer-package` — generated the package and passed
  `RendererPackageTool validate` (packageHash `dae86953…685faf`, packageID
  `org.selfdrivingwiki.d2-readonly`, version `0.8.2`, registration `d2`).
- `make d2-renderer-package-check` — full re-derivation matched the lock
  byte-for-byte (deterministic build: two consecutive builds produced
  identical digests, `d2.wasm` = `bd11a89b…89ac9`) and passed validation; the
  tamper leg corrupted the cached source tarball and the generator refused it.
- Offline suites (26 tests, 6 suites):
  `D2RendererPackageMatchingTests`, `D2ViewerTemplateTests`,
  `D2PackageLockTests`, `D2SourceNeutralityTests`,
  `D2GeneratedPackageValidationTests`, `RendererCapabilityBoundaryPolicyTests`
  — all pass.
- Hosted WebKit (`WIKIFS_APP_TESTS=1`, 3 tests):
  `D2RendererHostedValidationTests` — the package's own startup `input.read`
  request renders `x -> y` into a `role="img"` SVG with the dark-mode media
  rule adopted and the error region hidden, in ~0.6 s wall time; a compile
  error surfaces the error region with source bytes intact; install via
  `InstalledRendererHost` promotes the `d2` registration into the machine
  projection without restart and removal preserves source bytes.
- `make test` — full suite: 4,079 tests in 437 suites pass.
- `uv run tools/validate_skills.py` — `renderer-package-maintainer` skill valid.
- Manual runbook for the operator: `make d2-renderer-package` → Settings →
  Renderers → Advanced Local Renderer Package Import → select
  `tmp/d2-renderer-package/D2` → open a `.d2` source (e.g. `x -> y`) → the
  disclosure-row renderer renders it live; removing the package returns the
  source to the Source presentation.

## Limitations

- The watchdog cannot preempt a non-yielding WASM hang (accepted in the
  plan; covered by failure window → safe mode).
- The generated package is 31.8 MiB against the validator's 32 MiB copied
  limit — tight headroom; the validator fails closed and the lock makes the
  size visible per regeneration.
- Diagram sources with external `icon:` URLs keep a broken image under the
  no-network CSP (host policy, unchanged).
