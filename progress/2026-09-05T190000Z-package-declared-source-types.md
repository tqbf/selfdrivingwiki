---
timestamp: 2026-09-05T19:00:00Z
title: Package-declared source types (manifest revision 6)
branch: bugfix/normalize-mmd-mime
status: implemented
---

# Package-declared source types (manifest revision 6)

## Progress

Renderer packages now own their source-format metadata. Manifest
revision 6 adds a descriptor-scoped `sourceType` declaration with one
canonical MIME type, MIME aliases, and filename extensions. The host
projects those declarations from validated, active descriptors into a
`RegisteredRendererSourceTypes` catalog and uses it at ingest,
presentation, transclusion, content kind, and provenance labels. All
Swift-side Mermaid MIME policy is gone.

The Mermaid package is the proof case. Its manifest declares canonical
`text/vnd.mermaid` with the `text/mermaid`, `text/x-mermaid`, and
`application/vnd.chipnuts.karaoke-mmd` aliases (the karaoke MIME is
what macOS assigns to `.mmd` files), plus the `mmd` and `mermaid`
extensions. All four reviewed packages moved to revision 6 with bumped
immutable versions:

- Mermaid `1.1.0` — hash `bdee86be…4dd81b`
- SVG `1.1.0` — hash `9b9ab53a…f00d05`
- Excalidraw `1.1.0` — hash `713d4d9e…62b91d6`
- JSON Canvas `1.2.0` — hash `8bad1662…b4daae0`

The prior revision hashes stay pinned in repository history; a test
reproduces the old revision-5 JSONCanvas hash through the validator to
prove canonical bytes never moved.

Design and wiring:

- `RendererSourceTypeDeclaration` decodes normalized arrays, rejects
  duplicates, and encodes sorted arrays. Descriptor validation requires
  every declared value to have an equivalent routing matcher.
- `RendererMatchInput` now carries two bounded byte channels: the 4 KiB
  sniff prefix for signatures and a 64 KiB `BoundedArtifactInput` for
  complete bounded-JSON validation. One bounded read feeds both.
- The app derives the catalog from `RendererPreparation` after runtime
  revalidation and safe-mode filtering. Headless CLI and daemon
  profiles project the same claims from the machine index through
  `RendererCatalogResolution` (WebKit-free). Unavailable services
  yield an empty catalog and never block startup.
- Ingest resolves a unique claim after byte/signature safety checks.
  Extension fallback applies only to inconclusive MIME (nil,
  octet-stream, or the sniffer's generic text verdict). A
  caller-declared MIME either matches a claim or conflicts. Ambiguous
  claims fail closed. Binary signatures always win.
- `wikictl admin repair-mime` keeps dry-run-first behavior. A typed
  `MIMERepairDecision` classifies candidates as detector repair,
  package alias normalization, canonical no-op, conflict, ambiguity,
  byteless, or inconclusive. Candidates are active rows with a NULL
  mirror or a mirror equal to a declared claim MIME. Repair updates
  both active mirrors, emits one `.source/.updated` event per changed
  source, and reads the full 64 KiB artifact channel.
- The store/model/session/CLI composition propagates the catalog
  parallel to `registeredExtractionInputs`. Renderer lifecycle
  operations never write wiki databases.

## Verification

All four packages validate with
`swift run RendererPackageTool validate RendererPackages/<name>`.

New and updated suites, all green:

- `RendererSourceTypeManifestTests` (6) — revision gating, duplicates,
  matcher drift, canonical ordering, legacy descriptor bytes.
- `RegisteredRendererSourceTypesTests` (6) — alias normalization,
  conflicts, ambiguity, the 4 KiB/64 KiB artifact bounds, and the
  signature channel staying off the artifact channel.
- `RendererSourceTypeIngestTests` (7) — ingest-level alias, extension,
  conflict, signature, ambiguity, and artifact-bound coverage.
- `MIMERepairTests` (14) — the original seven plus dry-run, apply,
  idempotence, ambiguity, package absence, and both artifact-boundary
  repair cases against the real Mermaid claim.
- `RendererSourceTypeNeutralityContractTests` — scans production
  Swift for the removed Mermaid policy literals and pins the reviewed
  manifest surface.
- `RendererSourceTypeRuntimeTests` (4, hosted) — install, suppression,
  reset, removal, and the no-wiki-write lifecycle guarantee.
- `RendererSourceTypeCompositionTests` (3, hosted) plus
  `RendererSourceTypeSessionCompositionTests` (1) — model/store,
  CLI repair, unavailable-services, and SessionManager fan-out.
- `MermaidSourceTypeIntegrationTests` (4, hosted) — karaoke ingest,
  transclusion both ways, package-name provenance, and generic
  fallback.
- `RendererSourceTypeDocumentationConsistencyTests` — parses all four
  manifests and asserts the user and maintainer guides carry the
  matching identities, versions, and canonical MIME values.
- Portable sweeps: `RendererModelTests`,
  `MermaidRendererPackageMatchingTests`,
  `SVGRendererPackageManifestTests`, `SourceProvenanceLabelTests`,
  `MimeTypeTests`, `ContentTypeRegistryTests`,
  `RendererArtifactMatcherTests`,
  `PackageFenceValidationManifestTests` — 171 tests green.

Full gates `make build` and `make test` pass (4221 tests, 462 suites).
The plan's `scripts/validate-skills` entry has no matching script in the
repository; the skill contract is pinned by
`RendererPackageDocumentationTests` instead, which passes.

Known pre-existing failures in the opt-in `WIKIFS_APP_TESTS=1` full
suite (verified by stashing this branch and rerunning at HEAD):
`SourcesTests` MIME expectations from before the centralized detector's
generic-text verdict, the renderer architecture audit's
`installedRendererFactoryInputs` wiring count, several fence-plan
presentation tests, and environment-dependent extraction/chat suites.
They are unchanged by this branch; the named hosted filters for this
plan all pass.

## Implementation review (cross-model)

An independent Claude (Opus, via Paseo) review of the committed change
returned REQUEST_CHANGES with two blocking findings; both are fixed:

- **H1 — repair precedence.** `MIMERepairDecision` ran detector repair
  before the catalog, so a NULL-mirror `.mmd` row was written
  `text/plain` and stranded outside the candidate set, and a half-null
  karaoke row lost its alias. The decision now resolves the catalog
  first (mirroring ingest: nil/octet-stream/generic-text mirrors are
  inconclusive, so the extension claim may resolve), and detector
  repair only follows when no claim resolves. Regression test:
  `packageNormalizationPrecedesDetectorRepairForNullMirrors`.
- **H2 — unbounded transclusion read.** `TransclusionEmbedder` read the
  full blob before text gating. A cheap metadata pre-filter
  (`mightPresentAsText`) now skips the byte read unless the stored MIME
  or extension could resolve to a text-canonical claim.

Also adopted: deterministic winning claim via `stableTieBreakKey`
(M3), corrected the store property doc comment (M2), removed the
unreachable conflict guard and the unused validation error case, moved
the signature-conflict check ahead of `canonicalNoOp` (L4), and
strengthened two artifact-bound tests (L5/L6).

Rebutted/deferred: M1 (canonical MIMEs stay in the repair candidate
set — the plan defines candidates that way, and canonical rows are
counted as scanned no-ops, not repairable; the memory note is a
candidate for a follow-up two-phase fetch); M4 (the unsynchronized
catalog property mirrors the pre-existing `registeredExtractionInputs`
pattern; the invariant is documented at the protocol and a lock-backed
variant is a follow-up); L9/L10 recorded as intentional behavior.

A second Claude review pass over the post-fix state returned no
CRITICAL/HIGH findings and one MEDIUM, adopted: claim coalescing now
compares only canonical MIME and display name (presentation identity),
not the full matcher arrays — two claims that present identically but
carry different extra routes or artifact predicates coalesce instead of
failing closed, matching the design contract. Covered by
`sameCanonicalAndLabelCoalesceAcrossDifferentMatcherSets` in both
byte-aware and metadata-only resolution; the fixture helper now
propagates `displayName`, which also restored the intended
different-label ambiguity case.

## Notes

- The old `.mmd` → `text/mermaid` ingest fallback is intentionally
  gone. Without the package, `.mmd` stores the generic text MIME and
  stays readable; with it, imports store `text/vnd.mermaid` and
  repair normalizes history.
- `SourceDetailView.isMarkdownNative` and provenance labels consult
  the catalog through the same validated inputs the renderer panes
  use, so no new host state was added.
- The stored schema stays at version 52; repair is an explicit
  operation, not a migration.
