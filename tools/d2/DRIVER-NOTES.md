# D2 WASM driver notes (main thread, no worker)

Recorded from the Phase 4 spike against the pinned bytes. The spike drove the
module the same way `tools/d2/d2-viewer.js` does, first under Node v22 (engine
parity probe) and then through the hosted WebKit session
(`D2RendererHostedValidationTests`, opt-in). Everything below was observed
behavior, not documentation-derived.

## Pinned upstream

- The package pins the **d2lang/d2 source at v0.8.2** (commit
  `1c0d93ba1abffe0d425d45d5c037d9474807e4f5`): source tarball URL + SHA-256,
  the Go/binaryen toolchain versions, the build recipe, and the built
  artifact digest are all in `tools/d2/d2-package.lock.json`. `wasm_exec.js`
  is taken from the same source tree (`d2js/js/wasm/wasm_exec.js`).
- Why v0.8.2 and not the npm 0.1.33 artifact originally pinned by the plan:
  upstream's WASM build until 2026-08-09 ran its dagre/ELK layout engines by
  evaluating JavaScript strings through the browser (`lib/jsrunner` used
  `syscall/js` under the `js && wasm` build tags), which requires
  `script-src` `'unsafe-eval'` — a policy the host declined. Commit
  `b039f25c3e` replaced the JavaScript runners with pure-Go ports
  (`d2lang/dagro`, `d2lang/elk-go`), first released in v0.8.2, making the
  WASM eval-free. The build-from-pinned-commit supply chain mirrors the
  Excalidraw package's exact-commit pin.

## Build recipe

```text
GOOS=js GOARCH=wasm go build -ldflags='-s -w' -trimpath -buildvcs=false \
    -o d2.wasm ./d2js
wasm-opt -Oz --enable-nontrapping-float-to-int --enable-bulk-memory \
    --enable-sign-ext --enable-simd --enable-reference-types -o d2.wasm d2.wasm
```

- Go 1.27.0 and binaryen's wasm-opt 132 (versions pinned in the lock; the
  generator hard-fails on a toolchain mismatch). Get wasm-opt from the pinned
  binaryen release — `binaryen-version_132-arm64-macos.tar.gz` at
  https://github.com/WebAssembly/binaryen/releases/tag/version_132 — not brew:
  brew's bottle version varies by macOS build (CI runners have resolved 131
  against this lock's 132).
- `-buildvcs=false` and `-trimpath` keep the build byte-reproducible; two
  consecutive builds produced identical SHA-256 digests, and the lock pins
  the optimized artifact digest (`bd11a89b…89ac9`, 33,349,990 bytes — just
  under the validator's 32 MiB copied-byte limit).
- `-all` as the wasm-opt feature flag is wrong: it makes binaryen v132 emit
  import kinds Node's V8 rejects. Enable exactly the features Go's output
  uses (the flags above).

## Boot sequence (the worker's drive, worker-free)

The upstream worker boots the module with `new Go(); WebAssembly.instantiate(
bytes, go.importObject); go.run(instance)` and reads the API off
`globalThis.d2` — registered by the Go program during the synchronous prefix
of `run()`. `go.run()` resolves only when the Go program exits and is
intentionally not awaited. Observed boot-to-`globalThis.d2` latency: ~240 ms
in Node; sub-second in the hosted WebKit session.

The stock worker also evals `elk.js` + `setup.js` at init. The wrapper skips
ELK entirely: the dagre layout engine is compiled into the module and ELK is
opt-in per compile request.

## Compile and render (JSON protocol)

The module API is JSON-in/JSON-out:

- Compile request: `{"fs": {"index": "<source>"}, "options": {"layout":
  "dagre"}}`. The `fs` map entry must be keyed `index` (the default
  `inputPath`). v0.8.2 embeds its font faces, so no font bytes are needed —
  the compiled diagram carries `fontFamily: "SourceSansPro"` on its own.
- Compile response: `{"data": {"fs", "inputPath", "diagram", "graph",
  "renderOptions"}}` or `{"error": {"message", "code"}}`. Compile of
  `x -> y`: ~60 ms.
- Render request: `{"diagram": <compileResponse.data.diagram>,
  "options": {"darkThemeID": 200, "noXMLTag": true}}`. **The diagram argument
  must be `data.diagram`**, not the whole compile response — the render
  request decodes a `d2target.Diagram` and Go silently ignores unknown JSON
  fields, so passing the envelope loses the font family and crashes render.
- Render response: `{"data": "<base64 SVG>"}`. Render of `x -> y`: ~120 ms.

Historical note (why the original plan's font-assets step existed): the
previously pinned 0.1.33 npm artifact panicked in `EmbedFonts` unless font
bytes were passed at compile time, and its own integration tests never
exercised render. That whole class of problems disappears with the eval-free
v0.8.2 build, whose fonts are embedded in the module.

## Rendered SVG shape (CSP-relevant)

For `x -> y` (~15 KB):

- Two `<style>` elements inside the inner `<svg class="d2-…">`: one carries
  `@font-face` rules with base64 WOFF2 subsets; the other carries the theme
  color classes (`.fill-N1`, `.stroke-B1`, …) **and** a
  `@media screen and (prefers-color-scheme: dark)` block when `darkThemeID`
  is set. All theme colors live in these stylesheets, not in presentation
  attributes.
- `darkThemeID: 200` is the correct dark-appearance option (themeID stays 0);
  the SVG adapts to system appearance via the media query.
- No `<script>`, no `on*=` handler attributes, no external `http(s)`
  references, no `xlink:href` to foreign resources. Internal `url(#…)`
  marker/mask references only.
- A handful of `style="…"` attributes (stroke-width, text-anchor, font-size).

## Why the wrapper moves CSS instead of relaxing CSP

The package CSP (`style-src renderer-package:`, no `unsafe-inline`) blocks
inline `<style>` elements and inline style attributes when the SVG is mounted
into the DOM. Because D2 puts all theme colors and fonts there, naive
mounting would strip them. The wrapper therefore:

1. extracts the `<style>` text and removes the elements before mounting;
2. adopts the text via `CSSStyleSheet.replaceSync()` +
   `document.adoptedStyleSheets` — CSSOM manipulation is not document
   parsing and is not covered by `style-src`; every byte comes from the same
   pinned module output, so no new authority is involved;
3. re-applies each refused `style="…"` attribute through the element's
   `CSSStyleDeclaration` (`element.style.setProperty`). The attribute then
   re-appears in the DOM as the CSSOM reflection of the applied declarations
   (WebKit serializes it with normalized spacing) — that is the mechanism
   working, not a leftover.

The hosted test asserts the adopted sheet count, the `prefers-color-scheme`
media rule (via `CSSMediaRule.media.mediaText`, since `cssText`
serialization is unreliable), `role="img"`/`aria-label`, the hidden error
region, and that every residual style attribute has live CSSOM declarations.

## Watchdog

`Promise.race` budget of 10 s (named constant) around the whole run. It can
only fire while the module yields to the event loop; a non-yielding hang
shows as an unresponsive pane handled by the existing failure window → safe
mode. Accepted limitation (see the plan).

## Outcome

Main-thread drive is feasible and verified end to end under the approved CSP
(`'wasm-unsafe-eval'`, no JS `'unsafe-eval'`): the hosted session renders
`x -> y` from the package's own startup request in ~0.6 s wall time, with the
dark-mode media query present and no error region. Option C (worker-src
widening) was not needed and was not taken. No security-policy escalation was
required after the re-pin.
