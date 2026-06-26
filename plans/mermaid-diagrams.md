# Inline Mermaid Diagrams (reader + agent authoring)

**Goal.** Render ` ```mermaid ` fenced blocks as diagrams in the WKWebView readers,
and teach the embedded agent (in `SystemPrompt.defaultBody`) when to author one to
aid understanding of a wiki topic.

## Context inventory

- **Render pipeline** (`MarkdownHTMLRenderer.swift`): `visitCodeBlock` (L58) already
  emits ` ```mermaid ` as `<pre><code class="language-mermaid">…escaped…</code></pre>`.
  Nothing reads that class — no syntax highlighting exists. This is the single seam.
- **Main reader** (`WikiReaderView.swift`): `documentHTML(_:)` (L133, `nonisolated
  static`, pure) builds the full `about:blank` HTML with inline CSS and **no
  `<script>` tags**. `loadHTMLString(html, baseURL: about:blank)` (L518).
- **Transcript reader** (`AgentTranscriptWebView.swift`): a separate `shellHTML`
  (L246) loaded once; rows are appended at runtime via `appendRows(html)` →
  `insertAdjacentHTML('beforeend', …)` (L323). Same `MarkdownHTMLRenderer` path.
- **Asset bundling**: none today. `build.sh` already hand-copies `vec0.dylib` and the
  `pdf2md` script into the app bundle (`Contents/Resources` / `Helpers`); mermaid fits
  that pattern, read at runtime via `Bundle.main`.
- **Agent → reader**: agent writes page bodies via `wikictl page upsert`; bodies flow
  unchanged into the same renderer. A ` ```mermaid ` fence reaches the DOM today — only
  the runtime is missing.
- **System prompt**: `SystemPrompt.defaultBody` `## Conventions` holds authoring rules
  (bold-label bullets + fenced examples). It is the **seed/fallback only** — existing
  wikis keep an edited copy in SQLite. Propagating updates to existing wikis is a
  **separate** feature (see Follow-up).

## Key decisions

- **Vendor mermaid locally** (offline; the app is local-only). Pin a recent **mermaid
  v11 UMD build** (`dist/mermaid.min.js`, ~3 MB) that exposes a global `mermaid` and is
  self-contained for the **core diagram types** (flowchart, sequence, state, class, ER,
  mindmap, gantt) — avoid types needing runtime CDN icon fetches (they'd fail under
  `about:blank`).
- **Keep `about:blank` + inline the script.** Do **not** switch to
  `loadFileURL`/`<script src>` — that changes page origin and risks the anchor / find /
  highlight / `wiki://` routing flow. The main reader inlines the runtime **only when a
  diagram is present**; the transcript (dynamic content) always includes it.
- **`securityLevel: 'strict'`** (mermaid default). Diagram text is semi-trusted
  (agent/user authored); never use `'loose'` (mermaid's historical XSS vector). Combined
  with `about:blank` (no network) this is the safe posture.
- **Render in both surfaces** (pages/sources/system prompt/changelog **and** live
  transcript).
- **Theme**: pick mermaid `theme` from `prefers-color-scheme` at init.

## Approach (chosen)

A vendored `mermaid.min.js` is copied into `Contents/Resources` by `build.sh` and read
once via `Bundle.main` (cached in a `MermaidAsset.js` static). The renderer emits
`<pre class="mermaid">…</pre>`. `documentHTML` gains an optional `mermaidScript:`
param; the caller passes the cached JS only when the rendered body contains a mermaid
block, and `documentHTML` appends `<script>…runtime…</script>` + an init/run script.
The transcript shell always carries the runtime and calls `mermaid.run()` after each
`appendRows`. `documentHTML` stays pure (script injected as a parameter → unit-testable).

*Rejected:* (a) `WKUserScript` injection — pays the ~3 MB parse cost on every page,
diagram or not. (b) `loadFileURL` + `<script src>` — larger blast radius on the load
path the highlight/anchor flow depends on. (c) embedding the JS as a Swift string
literal — bloats compile, no build change but ugly.

## Steps

**1 — Renderer emits a mermaid container.**
`MarkdownHTMLRenderer.visitCodeBlock`: when `language == "mermaid"`, return
`<pre class="mermaid">\(escape(code))</pre>` (mermaid reads decoded `textContent`, so
keep escaping); all other languages unchanged.
*Files:* `Sources/WikiFS/MarkdownHTMLRenderer.swift`,
`Tests/WikiFSTests/MarkdownHTMLRendererTests.swift`.
*AC:* a ` ```mermaid ` block renders `<pre class="mermaid">` with escaped source; a
` ```swift ` block still renders `<pre><code class="language-swift">`. Tests pass.

**2 — Vendor the runtime + loader + bundle copy.**
Commit `Resources/mermaid.min.js` (pinned v11 UMD). Add `MermaidAsset` (in `WikiFS`)
with a cached `static let js: String` read from `Bundle.main.url(forResource:"mermaid.min",
withExtension:"js")` (empty string if absent — dev/test outside the bundle). Add a
`build.sh` line copying it into `Contents/Resources` (mirror the `vec0.dylib` copy).
*Files:* `Resources/mermaid.min.js` (new), `Sources/WikiFS/MermaidAsset.swift` (new),
`build.sh`.
*AC:* `make` produces `Self Driving Wiki.app/Contents/Resources/mermaid.min.js`;
`MermaidAsset.js` is non-empty in a bundled run. `swift build` clean.

**3 — Wire the main reader.**
`documentHTML(_ body:mermaidScript:)` gains an optional script param; when non-nil,
append `<script>\(script)</script>` + an init script
(`mermaid.initialize({startOnLoad:false, securityLevel:'strict', theme: <scheme>})`
then `mermaid.run()`). `WikiReaderRep.startLoad` computes
`needsMermaid = body.contains("<pre class=\"mermaid\"")` and passes
`needsMermaid ? MermaidAsset.js : nil`.
*Files:* `Sources/WikiFS/WikiReaderView.swift`,
`Tests/WikiFSTests/WikiReaderRoutingTests.swift` (or a new test file).
*AC:* `documentHTML` with a script arg includes exactly one runtime `<script>` + an
init that sets `securityLevel:'strict'`; with `nil` it includes none (pure, unit-
tested). Live: a page with a flowchart fence renders an SVG diagram (manual gate).

**4 — Wire the transcript reader.**
`AgentTranscriptWebView.shellHTML` always includes the runtime + `mermaid.initialize`
(it has no body at load time). `appendRows` calls
`mermaid.run({ querySelector: '.mermaid:not([data-processed="true"])' })` after the
`insertAdjacentHTML`, so diagrams in newly streamed rows render.
*Files:* `Sources/WikiFS/AgentTranscriptWebView.swift`.
*AC:* the shell contains the runtime + a strict init; `appendRows` re-runs mermaid on
unprocessed nodes. Live: a ` ```mermaid ` block in an agent reply renders mid-chat
(manual gate).

**5 — Teach the agent + index the docs.**
Add a `## Diagrams` section to `SystemPrompt.defaultBody` (after `## Conventions`):
*when* to draw one (a process/sequence, hierarchy, relationships/architecture, state
machine, timeline — only when it aids understanding, never decoratively), keep them
small, prefer the supported core types, and the ` ```mermaid ` fence syntax with one
worked `flowchart` example (mirror the footnote-example pattern). Add the `PLAN.md`
doc-index row for this file.
*Files:* `Sources/WikiFSCore/SystemPrompt.swift`,
`Tests/WikiFSTests/SystemPromptTests.swift`, `PLAN.md`.
*AC:* `defaultBody` contains a `## Diagrams` section with a valid mermaid example;
existing `SystemPromptTests` updated and green.

## Definition of done

- All step ACs met; `swift build` + `swift test` clean (new renderer/documentHTML/system
  prompt tests added, existing suites green).
- A `flowchart` authored in a page body renders as an SVG in the main reader, and one
  authored in a live agent reply renders in the transcript.
- No network access at render time; `securityLevel:'strict'`; non-diagram pages inject
  no runtime (no per-page parse cost).
- New wikis seed the `## Diagrams` guidance; existing wikis are unaffected (by design —
  see Follow-up).

## Notes

- **Perf:** ~3 MB runtime is inlined only on diagram-bearing main-reader pages and once
  in the persistent transcript webview; parse cost is a one-time ~tens-of-ms per such
  load. Acceptable for a local desktop app.
- **Out of scope:** re-theming a rendered diagram on a live light/dark switch (a
  navigation reload re-themes); invalid-syntax UX beyond mermaid's default error block.

## Follow-up (separate plan)

`SystemPrompt.defaultBody` additions only reach **new** wikis — a general gap affecting
every convention add (footnotes, anchors, citations). The fix —
**system-prompt upgrade reconciliation** (version-stamp `defaultBody`; detect
pristine-vs-user-edited stored prompts; on first launch after an upgrade, fast-forward
pristine wikis and *offer* a diff-based update for edited ones) — is its own quick-plan.
Once it ships, this mermaid guidance and all future convention adds propagate to existing
wikis for free. Tracked separately; not a dependency of this work.
