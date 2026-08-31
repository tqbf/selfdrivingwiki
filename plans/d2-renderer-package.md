# D2 as an installable dynamic renderer package

Status: implemented (2026-08-30). Issue tqbf/selfdrivingwiki#1134. Sibling
plans: `plans/dynamic-renderers.md` (renderer system), driver-level detail:
`tools/d2/DRIVER-NOTES.md`.

## Summary

D2 (https://d2lang.com) is available as a read-only diagram renderer that
installs entirely through the existing dynamic renderer-package path. The
repository ships **no D2 bytes**: what it ships is a generator
(`scripts/make-d2-renderer-package.sh`), hand-authored wrapper templates
(`tools/d2/`), and a provenance lock (`tools/d2/d2-package.lock.json`). The
user generates the package locally (`make d2-renderer-package`) and imports it
through Settings → Renderers → Advanced Local Renderer Package Import. The app
picks it up live, without restart. Removing it preserves Source.

This is the first WASM-based renderer package and the first fully
script-generated one; it exercises the renderer-package system's data-only
claim end to end.

## The honest test, and the result

Zero format-specific production Swift changes for matching, rendering,
fallback, install, removal, and live refresh. The production Swift diffs in
this work are two format-neutral policy slices (below), which name no format
and know nothing about D2. `D2SourceNeutralityTests` is the executable guard:
`Sources/**/*.swift` must not contain `d2lang`, `terrastruct`, the quoted
`d2` extension literal, `D2`-prefixed identifiers, or any wasm artifact name,
and `Package.swift` must not reference the D2 package or its generated output.

## Policy slices (the only Swift changes)

1. **CSP: WASM compilation.** WebKit blocks `WebAssembly.instantiate` unless
   `script-src` includes `'wasm-unsafe-eval'` (operator-approved Option A).
   `connect-src` widened to the package scheme so a package may fetch its own
   declared, hash-pinned assets — zero network; every network origin stays
   blocked. Workers, frames, eval, storage, and cookies remain forbidden.
   The literal is pinned by a golden test in
   `RendererCapabilityBoundaryPolicyTests`, which CI runs in the D2 step.
2. **Scheme MIME table: `ttf → font/ttf`.** The closed extension→MIME table
   in `RendererPackageResourceProvider` already served woff/woff2 but not
   TTF, so a package carrying text-measured TTF fonts could not fetch them.
   One line, format-neutral: fonts are a normal static-asset class. Pinned by
   `packageSchemeMIMETableStaysClosed`.

No D2-specific branch exists anywhere in `Sources/`.

## Package identity and shape

- packageID `org.selfdrivingwiki.d2-readonly`, version `0.8.2` (mirrors
  upstream), registrationID `d2`, revision 2 manifest.
- matchers: `extensionFallback("d2")` only — D2 has no registered MIME type
  and no magic bytes; a MIME claim like `text/plain` would annex every
  plain-text source.
- capabilities exactly `["inputRead"]`, linkPolicy `none`,
  `supportedEmbeddingRoles ["disclosureRow"]`, presentations `["web"]`,
  48,000-byte input/decoded limits, priority 100.
- assets: `index.html`, `d2-viewer.js`, `d2.wasm`, `wasm_exec.js`,
  `LICENSE.txt`, `THIRD_PARTY_NOTICES.txt`, `PROVENANCE.md`.

## Supply chain: pinned source, locally built

The generator downloads the pinned upstream source tarball
(`https://codeload.github.com/d2lang/d2/tar.gz/refs/tags/v0.8.2`, SHA-256 in
the lock; fail closed on mismatch — `make d2-renderer-package-check` includes
a corrupt-byte tamper leg proving the refusal) and builds the WASM with the
locked recipe (Go 1.27.0, `-trimpath -buildvcs=false`, then `wasm-opt -Oz`
with an explicit feature set). The lock pins the toolchain versions, the
recipe, and the built artifact digest; two consecutive builds produce
identical bytes. `PROVENANCE.md` is byte-reproducible because its generation
date is pinned in the lock instead of taken from the wall clock. Upstream
drift is a deliberate lock edit, reviewable in git.

Licensing: D2 is MPL-2.0 (canonical text committed and digest-pinned as the
package's `LICENSE.txt`); `THIRD_PARTY_NOTICES.txt` is upstream's own notices
file for the d2js artifact, copied verbatim from the pinned source, plus an
assembly note covering Go's `wasm_exec.js` (BSD-3-Clause).

## The driver (see tools/d2/DRIVER-NOTES.md for the full record)

The stock d2.js browser bundle requires Web Workers, which the package CSP
forbids, so the wrapper drives the module on the main thread exactly the way
the upstream worker does: `new Go()`, `WebAssembly.instantiate`, un-awaited
`go.run(instance)`, API on `globalThis.d2`. Two facts gated the design and
are recorded in DRIVER-NOTES:

1. **The render request takes `compileResponse.data.diagram`, not the compile
   envelope** — the render request decodes a `d2target.Diagram` and Go
   ignores unknown JSON fields, so passing the whole envelope silently drops
   the font family and crashes render.
2. **Upstream's earlier npm artifacts (≤ 0.1.33, the then-latest release)
   could not render at all**: their layout engines evaluated JavaScript
   strings through the browser (requiring `'unsafe-eval'`, a policy the host
   declined), and 0.1.33 additionally panicked in `EmbedFonts` without font
   bytes. Upstream removed the JS runners on 2026-08-09 (pure-Go dagro and
   elk-go engines) and shipped the first eval-free build in v0.8.2, which
   also embeds its font faces. This work re-pinned the package to that
   source instead of escalating the CSP — see "The eval escalation that
   wasn't needed" below.

Dark appearance uses `darkThemeID: 200` (themeID stays 0); the SVG adapts to
system appearance via an internal `prefers-color-scheme` media query.

### Styles under the CSP

D2 puts all theme colors and fonts into `<style>` elements inside the SVG,
plus a few `style="…"` attributes. The CSP (correctly) refuses those when the
SVG is mounted. The wrapper extracts the stylesheet text and adopts it via
`CSSStyleSheet.replaceSync` + `document.adoptedStyleSheets` (CSSOM is not
document parsing; every byte comes from the same pinned module output), and
re-applies refused style attributes through `element.style.setProperty` (the
attribute then re-appears as the CSSOM reflection of applied declarations).
The hosted test asserts the adopted sheets, the dark-mode media rule via
`CSSMediaRule.media.mediaText`, and that every residual style attribute has
live CSSOM declarations.

### Resource containment

The module has no ambient authority: its only import surface is the pinned
`wasm_exec.js` `importObject`, and the session layers above it (CSP, scheme
handler, bridge, realm isolation, nonpersistent store, WebContent process
boundary, failure window/safe mode) confine it. The wrapper adds a
best-effort 10-second watchdog (`Promise.race`); a non-yielding hang shows as
an unresponsive pane — the WebContent process spins, not the app — handled by
the existing failure window → safe mode. Hard preemption would need the
rejected worker-based path or host-side WebView termination; accepted.

## The eval escalation that wasn't needed

The hosted render initially failed: the then-pinned npm 0.1.33 WASM ran dagre
through browser `eval`, which `'wasm-unsafe-eval'` does not permit. Per the
plan's escalation clause this was surfaced rather than decided unilaterally,
and an adversarial second-opinion review of the "eval is unavoidable"
conclusion found the escape hatch: upstream had already replaced its
JavaScript layout runners with pure-Go ports (commit `b039f25c3e`, released
in v0.8.2), so building from a pinned eval-free source keeps the security
model exactly as approved. The escalation was resolved by re-pinning, not by
weakening the CSP; no `'unsafe-eval'` was ever adopted.

## Verification

- `make d2-renderer-package` — generate + `RendererPackageTool validate`
  (packageHash `dae86953…685faf` at implementation time).
- `make d2-renderer-package-check` — full re-derivation against the lock plus
  the tamper leg.
- Offline suites: `D2RendererPackageMatchingTests`, `D2ViewerTemplateTests`,
  `D2GeneratedPackageValidationTests` (skips without a generated package),
  `D2PackageLockTests`, `D2SourceNeutralityTests`, plus the CSP golden test
  and the MIME-table pin.
- Hosted (opt-in `WIKIFS_APP_TESTS=1`): `D2RendererHostedValidationTests` —
  the package's own startup request renders `x -> y` into an adaptive SVG in
  ~0.6 s wall time; a compile error surfaces the error region with the source
  intact; install via `InstalledRendererHost` promotes the registration
  without restart and removal preserves source bytes.
- `RendererPackageSchemeHandlerTests` continues to pass against the widened
  CSP by asserting the constant.

## Deviations from the original plan, with reasons

1. **Pinned upstream moved from the npm 0.1.33 tarball to the d2lang/d2
   v0.8.2 source tarball.** The npm artifact's layout engines require JS
   `eval` (rejected) and its render path was broken (fonts); v0.8.2 is
   eval-free with embedded fonts. Supply chain changed from tarball-digest
   pin to commit + source-digest + build-recipe + built-artifact-digest pin —
   the same exact-commit convention as the bundled Excalidraw package.
2. **License/notices files come from upstream.** The 0.1.33 tarball shipped
   no license file; v0.8.2 ships its own d2js notices, which the generator
   copies verbatim. The canonical MPL-2.0 text is committed and pinned.
3. **Font assets were added and then removed.** The 0.1.33 artifact needed
   font bytes at compile; v0.8.2 embeds font faces, so the package ships no
   font files. (The `ttf → font/ttf` MIME mapping remains: packages carrying
   TTF assets are a legitimate static class.)
4. **The wrapper moves SVG styles into adopted stylesheets.** Required for
   any colored diagram to render under the approved CSP. No new capability
   or policy change involved.
5. **The CI D2 step needs no `WIKIFS_APP_TESTS`.** Its filter only runs
   `WikiFSTests` suites, which are always enabled; hosted WebKit suites stay
   local-only per the existing exclusion policy. The step adds
   `actions/setup-go` (1.27.0) and `brew install binaryen` for the locked
   build recipe.

## Out of scope (unchanged)

Markdown `d2` rich fences (the fence alias set is a closed Swift enum),
Mermaid-style inline SVG projection, ELK layout (dagre default), editable
renderers, catalog/signing/remote distribution, and making renderer packages
Cordis `DynamicPluginHost` plugins (that mechanism belongs to the extractor
system; the renderer runtime is assembled through Cordis, but installed
packages are data, not plugins).
