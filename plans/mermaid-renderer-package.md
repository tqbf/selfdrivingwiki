# Mermaid renderer package

Mermaid is no longer a built-in renderer. All Mermaid rendering and all
save-time fence-syntax validation moved into a reviewed, committed renderer
package at `RendererPackages/Mermaid`, plus one small format-neutral host
mechanism: a manifest revision-3 `fenceValidation` contract that any package
can declare. Production Swift keeps zero Mermaid rendering code and zero
Mermaid JavaScript bytes. `MermaidSourceNeutralityTests` enforces this.

## Distribution

The package follows the Excalidraw model. It is committed in the repository,
SwiftPM does not copy it into the app, and a user imports the folder once per
Mac through Settings → Renderers → Advanced Local Renderer Package Import.
The package ID is `org.selfdrivingwiki.mermaid-readonly`, version `1.0.0`, and
the registration ID is `mermaid`.

Before import, a ` ```mermaid ` fence falls back to typed raw code with the
unavailable-renderer notice. After import, rendering works without a restart.
Removal restores the fallback and preserves Source data.

## Manifest revision 3: the fenceValidation contract

`RendererManifestRevision.current` is 3. A claim may declare a
`validation` object with an engine asset path, a wrapper asset path, and an
entry function name:

- `RendererFenceValidationDeclaration` validates that the two paths are
  distinct package-relative asset paths and that the entry function is one
  JavaScript identifier.
- The declaring descriptor must approve both assets, and both must be in the
  top-level asset list. The validator's regular-file and digest checks then
  cover them like every other asset.
- A revision 1 or 2 manifest that carries a `validation` object fails closed
  with `fenceValidationRequiresCurrentRevision`. The gate runs before the
  claims gate, so a pre-revision-3 manifest cannot smuggle a validation
  contract in through its claims.
- Canonical emission omits the `validation` key when absent and the
  `fenceClaims` key when claim-less. The revision-2 canonical bytes and the
  reviewed revision-2 package hashes did not change. `CanonicalManifestV3`
  routes revision 3.

## The generic host runner

`FenceSyntaxValidator` (WikiFSMarkdown) is a format-neutral JavaScriptCore
runner. It evaluates a list of JavaScript sources, resolves the entry
function by name, calls it with one block's text, flushes the microtask
queue through `JSPerformMicrotaskCheckpoint`, and reads back a holder object
with `done`, `isValid`, `diagramType`, and `errors`. `done == false` is a
hard error, never a silent pass. The block scanner and the warning text take
the claimed alias as a parameter, so the host spells no format name.

`FenceSyntaxValidationService` (WikiFSCore) resolves the claiming packages
from the machine index store, reads the declared assets through the
validated resource provider, and caches one runner per package version.

**Evaluation order is part of the package contract: the wrapper asset runs
first, then the engine asset.** Mermaid v11 bundles DOMPurify, whose factory
captures DOM state while the engine loads. In a bare JavaScriptCore context
the wrapper must install a minimal DOM and timer environment before the
engine evaluates. The entry function is resolved after both. All
Mermaid-specific JavaScript knowledge — the polyfill and the
`__sdw_validate_fence` entry function — lives in `validate.js`, inside the
package.

The service exposes the `FenceSyntaxValidating` protocol (defined beside the
runner in WikiFSMarkdown) so the store and the CLI depend on the seam, not on
the service. The app wiring and `wikictl` construct the concrete service from
the machine renderer package store.

## Save-time behavior

`WikiStoreModel` keeps an injectable `fenceSyntaxValidator` (nil default) and
a `fenceSaveWarning`. A nil validator skips, exactly like the old
nil-validator contract. `wikictl` builds the service from the same machine
store. An invalid claimed fence still hard-blocks the save. A claimed-looking
fence with no installed declaring package saves with a one-line stderr
notice: `validation skipped for <alias>: no installed renderer package
declares it`. The operator accepted that the save guarantee is
package-conditional.

## Rendering

The package claims the `mermaid` fence alias (revision-2 mechanism) and
matches `text/mermaid` sources plus the `.mmd` extension fallback. It renders
in package sessions — disclosure rows, the source renderer pane, and inline
embeds — through the same paths D2 and Excalidraw use. No host branch names
the format.

The viewer follows the engine's own document contract: it seeds a
`<div class="mermaid">` with the source and calls `mermaid.run({ nodes: … })`
with the strict security level. The theme comes from the
`prefers-color-scheme` media query, and the driver re-renders on appearance
changes. An earlier draft of the viewer passed an options object to
`mermaid.render(id, text, container)`, where the engine expects a container
element; the hosted suite caught the failure (`t.createElementNS`) and the
driver now uses `run`.

## Presentation changes (accepted)

- A Markdown document that contains ` ```mermaid ` fences keeps its reader
  presentation. The fences render there as claimed disclosure rows. The
  document no longer gets the old reader-projected "Rendered" tab; the reader
  already renders the same document.
- A `.mmd` source presents like any other renderer-package text source. The
  Source tab shows the bytes in a neutral 4-backtick code block. With the
  package installed, the generic presentation lifecycle adds the renderer
  pane by MIME or extension match.
- The outline gate derives from the presentation
  (`SourceDetailView.outlineApplicablePresentation`): only a rendered
  Markdown document has headings to outline. A `.mmd` source hides the
  outline with no host format branch.
- `.mmd` wiki embeds use the generic inline package path with its budgets,
  not a host-rendered DOM SVG. Legacy NULL-MIME `.mmd` rows resolve through
  the extension-fallback tier: `RendererEmbeddedContent.Source` gained an
  optional `fileExtension`, and `WikiRenderContext` gained a
  `sourceIDToExtension` map derived from source rows.

## Ingestion is unchanged

`.mmd` sources still ingest with `text/mermaid` through the
`MimeType.mime(forExtension:)` fallback, keep their "File / Mermaid"
provenance labels, and stay native-markdown content with no extraction. These
are content-type data rows in `MimeType.swift`, `ContentTypeRegistry.swift`,
and `SourceProvenanceLabel.swift` — the only Swift files the neutrality suite
allows to name the format.

## Known manual-only verification

Importing through the real Settings UI is manual. Everything else is
automated: the hosted suite covers install, render in both appearances, parse
failure, fence rendering, inline embeds, removal, the no-package Source-tab
leg, and the bundle-absence assertion
(`Bundle.main.url(forResource: "mermaid", withExtension: "js")` returns nil in
the hosted app process). Inspecting an arbitrary separately-built release
bundle remains a manual spot-check; the neutrality suite's `Package.swift`
and `build.sh` scans make a shipped copy structurally impossible, because
nothing copies or declares the asset.

## Deviations from the approved plan

1. The plan ordered Phase 4 and Phase 5 as separate commits with green
   boundaries. The built-in removal and the reader special-case removal
   landed as one commit, because removing the built-in descriptor breaks
   compilation of the reader's Mermaid branches. The plan's per-phase test
   updates are preserved.
2. `MermaidRendererHostedTests` (the old built-in hosted suite) was deleted
   in Phase 5 rather than Phase 7 — it could not compile against the removed
   built-in. Its replacement suite landed with Phase 7 as planned.
3. The viewer's first draft used `mermaid.render(id, text, options)`; the
   hosted run showed the engine requires its `run({ nodes })` document
   contract. The committed viewer uses `run`, and the driver documents the
   contract.
4. The service's store read bridges the async machine store to the
   synchronous save path through a detached task and a bounded semaphore
   wait. The plan named WikiFSCore as the service's home but did not specify
   the bridge; a 10-second bound keeps an unavailable store on the skip path
   instead of hanging a save.
5. The reviewer's app-wiring finding: the editor save warning originally
   stayed dead because nothing injected the service into the app model.
   The app composition now injects `FenceSyntaxValidationService` (resolved
   from the machine renderer layout) at both `WikiStoreModel` construction
   sites in `AppProcessProfileOwner.bootWikiSession`, and
   `AppProfileBootTests` pins that the injected validator is non-nil.
6. AC.6's hosted inline-embed leg is covered by equivalence: the hosted
   suite mounts the `.mmd` source through the same package session the
   inline embed uses, and the offline `DocumentEmbedResolverTests` cover
   both the claimed-arm and no-package transclusion legs. A separately
   hosted `.mmd` embed session would duplicate the identical mount path.
