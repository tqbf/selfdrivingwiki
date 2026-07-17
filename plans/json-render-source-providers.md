# json-render Source Providers

**Status:** Design / not started. Depends on nothing; unblocks the deferred
`json-render` generative-UI item (#249, graph-model §7 Phase 4 close-out).

**Purpose.** Make Self Driving Wiki a **json-render render target**: the wiki can
mount an arbitrary [json-render](https://github.com/vercel-labs/json-render) spec
in a WKWebView tab. The first concrete application is **source provider** UIs —
when you open a source provider, a tab renders an HTML interface (given by
json-render) that displays potential sources and lets you add one into the wiki.

This translates the wiki's own design page *"Source Providers and Extraction
Scripts"* (page id `01KXNXRS`, authored 2026-07-16) into a buildable plan against
the real codebase seams.

---

## Background — what json-render is

json-render is Vercel's "Generative UI framework": a **catalog** of components +
actions constrains what an AI (or any spec producer) can emit; a **registry**
maps catalog component types to real render components; a flat **spec**
(`{ root, elements: { id: { type, props, children, visible, watch } } }`) drives a
`<Renderer>`. State model + `setState` action + dynamic prop expressions
(`$state`/`$cond`/`$template`/`$computed`) + visibility make specs reactive.
A `SpecStreamCompiler` progressively compiles streamed chunks into a spec.

Key packages: `@json-render/core` (catalogs, prompt gen, SpecStream,
directives, validation), `@json-render/react` (React `<Renderer>` + hooks).
`@json-render/react` is a `tsup`-built lib (ESM/CJS), peer-dep on React 19 —
**not** a prebuilt UMD, but bundleable to IIFE via esbuild.

## Existing codebase seams this builds on

- **`Sources/WikiFS/WikiReaderView.swift`** — the WKWebView reader wrapper.
  Established pattern for: inlining vendored JS as an IIFE, a URL scheme handler
  (`BlobSchemeHandler` → `wiki-blob://`), `wiki://` message routing, Mermaid
  bootstrap, dark-mode theming. This is the template for `JSONRenderView`.
- **`Sources/WikiFSCore/SourceMaterializer.swift`** — the provider contract:
  `SourceMaterializer` protocol (`materialize() → MaterializedSource`),
  `MaterializedSource` (filename/data/mime/provenance), `SourceProvenance`
  (agent/activity/plan/externalRef/externalIdentity), `SourceOrigin`. Every
  existing ingest path produces one and flows through `storeMaterialized(_:)`.
  A provider script run becomes one more `SourceMaterializer` conformer.
- **`WikiStoreModel.storeMaterialized(_:)` → `store.addSource(provenance:)`** —
  the single write seam (single-writer, `@MainActor`). Provider output lands here.
- **`wikictl`** (`Sources/WikiCtlCore`) — headless CLI for the agent. Gets
  `source add <script> --args`, `provider list`, `connection list/add/run`.
- **Mermaid vendoring (`build.sh` copies `Resources/mermaid.min.js` →
  `mermaid.js`)** — the precedent for vendoring a JS bundle into the `.app`.
- **Schema/migration ladder** (`SQLiteWikiStore.createFreshSchema…` + migrate
  ladder) — for the `connections` table.

---

## Phases

### Phase 1 — json-render runtime in a WKWebView tab (the "render target")

Make the wiki able to mount any json-render spec. No provider logic yet.

- **Vendor the runtime.** An esbuild bundling step (`tools/jsonrender-bundle/`)
  bundles `react` + `react-dom/client` + `@json-render/core` + `@json-render/react`
  + a small built-in form catalog (`defineRegistry`) into one IIFE
  `jsonrender.runtime.js`, exposed on `window.WikiJSONRender`. `build.sh` copies
  it into the bundle like Mermaid. React 19 production build.
- **`JSONRenderView`** (SwiftUI, modeled on `WikiReaderView`): loads a stub HTML
  that inlines the runtime + a render harness. Swift→JS: `render(spec, state)`.
  JS→Swift: action events via `WKScriptMessageHandler` (`addSource`, `setState`,
  `browse`, `error`).
- **Built-in form catalog** (the set from the design page):
  `TextField`, `PasswordField`, `NumberField`, `Checkbox`, `SelectField`,
  `DateRange`, `FilePicker`. These are the primitives provider forms compose.
- **Prove with a hardcoded spec tab** in the app (a temporary dev entry) that
  renders a sample form and round-trips an `addSource` action back to Swift
  (logged via `DebugLog`; no real store write yet).

**Exit gate:** a hardcoded json-render spec renders interactively in a SwiftUI
tab; a button action is received in Swift. `JSONRenderView` is reusable.

### Phase 2 — provider scripts + manifest discovery (static, deterministic forms)

Provider scripts as described in the wiki design page, minus the AI-generated
form (deferred — see decision below).

- **`scripts/` discovery.** Convention: each provider is a directory containing
  the script + `manifest.json`. A `ProviderManifest` Swift model:
  `name`, `description`, `inputSchema` (JSON Schema), `supportsList`, `icon`,
  `scriptPath`, `version`.
- **Script contract.**
  - `script(args as JSON on stdin)` → stdout raw bytes (+ a header line or
    sidecar `manifest`-declared `display_name`/`mime_type`).
  - `script(args --list)` → stdout JSON `[{ id, label, preview }]`.
  - Failures → nonzero exit + stderr; surfaced in the UI.
- **`ProviderScriptMaterializer: SourceMaterializer`** — runs the script
  off-main (`Task.detached`), captures `data` + `filename` + `mime_type`,
  builds `SourceProvenance` (`agentName = "provider:<name>"`,
  `activityKind = "fetch"`, `externalRef` = invocation id, `plan` = script path).
  Output flows through `storeMaterialized(_:)` unchanged.
- **Workdir** (`--workdir`) for stateful scripts, cleaned up after run.

**Exit gate:** a real provider script (e.g. a `file-picker` or a `tavily`
stub) runs from a discovered `manifest.json`, writes raw bytes, appears as a
stored source with correct provenance via the existing seam.

### Phase 3 — provider tabs in the Sources sidebar

- **Schema-driven form generation.** A deterministic transform maps the
  manifest's JSON Schema → a json-render form spec (Phase 1 catalog). No AI
  needed for the form — reliability by default. (Optional: an AI generation mode
  as a follow-up; URL: deferred.)
- **Provider tab UI.** Each discovered provider becomes a tab in the Sources
  sidebar. The tab renders its form spec in `JSONRenderView`; on "Add", run the
  provider → `ProviderScriptMaterializer` → `storeMaterialized`.
- **Browse step** (`--list`): render results as a picker list with previews
  before the user picks which item to add.
- **Error UI:** stdout/stderr/exit-code status panel + retry (per design page).

**Exit gate:** open a provider tab, fill the form, pick from a `--list` result,
and the source lands in the wiki — fully end-to-end through the existing write
seam.

### Phase 4 — connections table + credentials + `wikictl`

- **`connections` table** (migration):
  `id, script_path, script_args_json, label, credential_refs, created_at`.
  No `kind` column — the script identity is the only discriminator (per design).
- **Keychain credentials.** `PasswordField` captured at configuration time,
  stored keyed by connection ULID, passed to the script as an arg at execution
  (script never sees the keychain).
- **`wikictl` CLI:** `provider list`, `connection list|add|run`, and
  `source add <script> --args '{...}'` (design page's "CLI equivalent"). Same
  script execution, no UI.
- **Edit/re-run** a connection (re-open the provider form pre-filled).

**Exit gate:** configure a provider connection via CLI, run it, source is added.

---

## Decision points (open)

1. **Form spec source: deterministic vs AI-generated.** The design page says
   "the AI sees the input schema and emits a json-render spec." Recommend the
   **deterministic JSON Schema → json-render transform** as the default
   (predictable, testable, offline) and treat AI generation as an optional
   follow-up. Needs operator confirmation before Phase 3.
2. **React bundle size / load strategy.** React 19 + json-render inlined on
   every provider tab (like Mermaid per-page) vs. a single long-lived hidden
   webview reused across tabs. Measure in Phase 1; likely reuse one webview.
3. **Script discovery vs explicit registration** (design page open question).
   Recommend directory discovery now (malleable) with an explicit registry file
   as a later addition.

## Non-goals (this plan)

- AI-authored form specs (optional follow-up to decision #1).
- Extraction-script generalization (the design page's other half) — separate
  effort; current 4 backends already cover it.
- Generative-UI-as-extraction-alternative (`application/vnd.wiki.jsonrender+json`
  graph-model §7) — different feature, stays deferred.
