# Package-declared rich fences

Date: 2026-08-31
Status: implemented
Branch: `feature/package-declared-fences`
Follow-up to: `plans/d2-renderer-package.md` (PR #1185)

## Decision

A Markdown rich-fence alias is registry data. The trusted built-in descriptor
table and reviewed renderer package manifests claim aliases; the host contains
no format-specific fence knowledge. A package can add a fenced format by
manifest data alone, and the executable guard for that is a source-neutrality
scan in the D2 suites.

This reverses an earlier stance. The deleted `MarkdownRichFenceAlias` enum
carried the doc comment "Package manifests cannot extend this closed set." The
reversal was an explicit product decision requested by the operator, not drift:
fence *recognition* became package data, while everything that guards a fence
stayed host-side (see Containment).

## What changed

- `RendererFenceAlias` replaces `MarkdownRichFenceAlias`: a validated string
  type (nonempty, lowercase ASCII alphanumerics, ≤ 32 characters), the same
  shape rules as `RendererFileExtension`.
- `MarkdownFenceInfo.parse` validates token shape only. Five ordinary language
  labels (`html`, `scala`, `java`, `swift`, `json`) stay reserved as non-rich so
  ordinary code fences keep their highlighted presentation. Recognition —
  whether any available renderer claims the alias — is a claim-map lookup.
- `RendererFenceClaim` (`alias` + `inlineMIMEType`) is declared on
  `RendererDescriptor.fenceClaims`. Manifest revision 2 may carry claims;
  revision 1 with claims fails closed, matching the `inlineContent` precedent.
- Canonical manifest emission omits `fenceClaims` when empty, so every
  claim-less package keeps its reviewed canonical bytes and package hash.
  Adding claims changes the hash, which is why the bundled Excalidraw package
  moved 1.0.3 → 1.0.4 to claim `excalidraw`.
- `RendererRegistrySnapshot.fenceClaims` maps each alias to its claimant
  (`RendererFenceClaimAssignment`: reference, inline MIME, display name).
  `RendererFenceClaimResolver` is the single deterministic merge, shared with
  the render-context build; collisions that reach it resolve by the existing
  `stableTieBreakKey`.
- The validator and activation take a `reservedFenceAliases` set, injected by
  the app wiring from `BuiltInRendererDescriptors` — one place defines the
  built-in claims. Activation additionally rejects an alias another available
  installed package already claims; removal frees it.
- `MarkdownHTMLRenderer` resolves alias → claim → plan from the projection's
  claim map. The five per-alias switch tables and the hardcoded display-name
  cases are gone. Mermaid's native inline-SVG projection stays keyed to its
  built-in claim (a reference comparison, not an alias branch). The store
  remembers every alias it has served; when that claimant disappears (removal
  or safe-mode suppression), the fence produces the `packageAliasDisallowed`
  typed raw-code fallback with the "renderer not available here" notice. An
  alias nothing ever claimed — an ordinary language label like `bash` — stays
  silent plain code, so no unclaimed fence grows a notice.
- `RendererEmbedProjection.richFenceAliases` (a closed `Set`) became
  `richFenceClaims` (the claim map). `WikiStoreModel` receives the built-in and
  enabled-installed descriptor lists from the app wiring (`ContentView`),
  resolves claims in `WikiRenderContext.build(from:)`, and invalidates the
  memoized context when `rendererMachineAvailabilityRevision` changes — so
  reader, chat transcripts, and activity windows all follow registry changes
  without a restart.
- The D2 package claims `d2` (`text/plain`) in its lock and manifest. Adding
  the d2 fence required no new format-specific production Swift.

## Presentation strings

Manifests carry no per-format presentation strings beyond one MIME per claim
(non-goal). Package claims derive display text from the declaring descriptor's
`displayName`: summary `"<displayName> fence"`, control label `Open`,
accessibility label `"Open <displayName> renderer"`.

The three pre-existing aliases keep byte-identical reader output (an
acceptance criterion). Their exact pre-conversion phrases ("Mermaid diagram
fence", excalidraw's `Interact` label, and friends) are pinned for the trusted
host-known claimants — the built-ins and the reviewed bundled package — in a
reference-keyed catalog inside `MarkdownHTMLRenderer`. A reference comparison
against trusted tables is the established dispatch pattern for host renderers
(`BuiltInRendererFactoryMap`); no package format can ever enter it.

## Containment

Fence authority became package data; fence safety did not:

- Syntax validation, quoted-title rules, and fence budgets stay host-side.
- A claiming descriptor must already fill the disclosure-row role; syntax, not
  the package, still owns the role.
- Admission, capabilities, size limits, and safe mode are unchanged.
- Reserved built-in aliases and install-time collisions fail closed with typed
  errors (`reservedFenceAlias`, `conflictingFenceAlias`,
  `duplicateFenceClaim`, `fenceClaimMissingDisclosureRole`,
  `fenceClaimsRequireCurrentRevision`).
- A fence whose claimant is removed or suppressed degrades to typed raw code
  with a readable notice; reinstall restores rendering without a restart.

## Field rename

`RendererEmbeddedContent.InlineArtifact.fenceKind` became `fenceAlias`. Raw
values are unchanged, and the artifact digest flows from the alias raw value,
so artifact identity and digests are unchanged (pinned by a digest-invariance
test). No durable persisted encoding of the field name is known; the encoded
action-URL payload is rebuilt within each render.

## PR ordering

This branch merges `feature/d2-renderer-package` (#1185) because the D2 claim
and its hosted proof exercise that package. If both PRs are open at once, merge
#1185 to `main` first.

## Verification

- `Tests/WikiFSTypesRendererTests/PackageFenceClaimManifestTests.swift` —
  revision gating, uniqueness, role requirement, MIME validity, canonical-byte
  stability, hash movement.
- `Tests/WikiFSTypesRendererTests/PackageFenceClaimRegistryTests.swift` —
  claim map, tie-break determinism, suppression semantics.
- `Tests/WikiFSTests/PackageFenceClaimAdmissionTests.swift` — validator and
  activation fail-closed admission, same-package upgrade, removal frees alias.
- `Tests/WikiFSAppTests/PackageFenceReaderPlanTests.swift` — d2 plan from claim
  data, unavailable-claimant fallback, golden output for the three existing
  aliases, artifact digest invariance.
- `Tests/WikiFSTests/D2SourceNeutralityTests.swift` — Sources/ contains no
  fence-alias literal for any package-declared format.
- `Tests/WikiFSAppTests/D2RendererHostedValidationTests.swift` — the d2 fence
  renders through the real package session (opt-in, `WIKIFS_APP_TESTS=1`).
