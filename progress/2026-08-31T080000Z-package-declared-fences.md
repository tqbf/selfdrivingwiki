---
timestamp: 2026-08-31T080000Z
title: Package-declared rich fences — d2 fences without host Swift
branch: feature/package-declared-fences
status: complete
---

# Package-declared rich fences — d2 fences without host Swift

A Markdown rich-fence alias is registry data now. The closed
`MarkdownRichFenceAlias` enum (mermaid/jsoncanvas/excalidraw) is gone, and the
host contains no format-specific fence knowledge. Design record:
`plans/package-declared-fences.md`.

- `RendererFenceAlias` is a validated string type; `MarkdownFenceInfo.parse`
  validates token shape only. Seven ordinary language labels (html, xml,
  scala, java, swift, json, jsonc — mirroring `CodeLanguage`) stay reserved as
  non-rich.
- `RendererFenceClaim` (alias + inline MIME) lives on
  `RendererDescriptor.fenceClaims`. Manifest revision 2 only; revision 1 with
  claims fails closed. Canonical emission omits the key when empty, so
  claim-less packages keep their reviewed bytes and hashes.
- `RendererRegistrySnapshot.fenceClaims` plus `RendererFenceClaimResolver`
  give one deterministic alias → claimant merge for the registry and the
  render-context build.
- The built-in table claims `mermaid` and `jsoncanvas`; the bundled Excalidraw
  package claims `excalidraw` and bumped 1.0.3 → 1.0.4 (bytes changed, so the
  reviewed version moved with them).
- The validator and activation take an injected `reservedFenceAliases` set;
  activation also rejects an alias another available installed package claims.
  Removal frees the alias.
- `RendererEmbedProjection.richFenceClaims` replaces the closed alias set.
  `WikiStoreModel` receives built-in + enabled-installed descriptors from the
  `ContentView` wiring and invalidates the memoized render context on
  `rendererMachineAvailabilityRevision` changes, so reader, chat transcripts,
  and activity windows follow registry changes without a restart.
- `MarkdownHTMLRenderer` resolves alias → claim → plan; the five per-alias
  switch tables are gone. A parsed alias with no available claimant produces
  the `packageAliasDisallowed` typed raw-code fallback with the
  "not available here" notice. The three pre-existing aliases keep
  byte-identical output (trusted-reference presentation pins; package claims
  derive display text from `displayName`).
- `tools/d2/d2-package.lock.json` declares
  `fenceClaims: [{"alias": "d2", "inlineMIMEType": "text/plain"}]`;
  `scripts/make-d2-renderer-package.sh` emits it. Adding the d2 fence required
  no new format-specific production Swift.

## Progress

- Phase 1–4: alias type, claims, manifest gating, registry claim map,
  validator/activation fail-closed admission, built-in claims, Excalidraw
  1.0.4, model/context wiring, data-driven reader plan. Complete.
- Phase 5: D2 lock + script emit the claim; the package regenerated from the
  pinned v0.8.2 source and passed `RendererPackageTool` validation
  (package hash
  `4d30325c57f48273460509ebca564dabc0825f41ef96b3be564e1d32652b3e1f`).
- Phase 6: manifest/registry/admission/reader-plan suites, extended fence-info
  tests, extended D2 neutrality scan (package-declared fence aliases must not
  appear in `Sources/`), hosted D2 fence test. Docs: user guide, maintainer
  skill + guide, `plans/typed-markdown-embed-pipeline.md` correction, design
  record, PLAN.md row.
- Implementation review (general-purpose subagent over the completed diff)
  found no critical or high issues. Its two medium findings were both fixed:
  the built-in claim injection moved into `ContentView.init` (the
  `onChange(initial:)` placement could let a reader memoize a claim-less
  context before injection, caught by the hosted production-root disclosure
  test), and the unavailable-renderer notice now fires only for aliases the
  store has actually seen claimed — ordinary language fences (`bash`,
  `python`) stay silent plain code. The reserved set also folds in the
  syntax-reserved ordinary-language labels so packages cannot claim them.

## Verification

- `make test` (default graph): 4111 tests, 441 suites, all green — re-run
  after the review fixes.
- New suites pass: `PackageFenceClaimManifestTests` (11),
  `PackageFenceClaimRegistryTests` (5), `PackageFenceClaimAdmissionTests` (5),
  `PackageFenceReaderPlanTests` (10), extended `MarkdownFenceInfoTests` +
  `RendererFenceClaimCodableTests`.
- `WIKIFS_APP_TESTS=1 swift test` (opt-in app-tests target): the fence-related
  suites pass, including `MarkdownHTMLRendererTests` (52 tests with the typed
  markdown suite), `WikiAppWebViewTests` (15, including the hosted
  production-root disclosure expansion), and
  `D2RendererHostedValidationTests.d2FenceRendersThroughPackageClaim`
  (real-window WebKit render of a `d2` fence through the generated package).
- `scripts/check-cordis-boundaries`: verified. `uv run tools/validate_skills.py`:
  valid.
- Pre-existing failures observed in the opt-in app-tests target that are NOT
  from this change (files unchanged from `main`): the
  `SourceDetailRendererArchitectureAuditTests` audit ("JSON Canvas" already in
  `SourceDetailView.swift`) and the `BuiltInRendererRegistryTests` SVG
  source-markdown expectation, plus several environment-dependent suites
  (uv PATH, GEMINI_API_KEY hint, bun.sh readiness, daemon XPC, queue
  `.notStarted`). This target is excluded from the default test graph and CI;
  worth a follow-up issue.
