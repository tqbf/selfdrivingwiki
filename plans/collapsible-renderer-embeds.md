# Goal

> Superseded scope note, 2026-08-25: Image and media syntax no longer promotes
> content to disclosure rows. Syntax owns the embedding role. Approved rich
> fences use rows. Images and media stay inline. See
> [`typed-markdown-embed-pipeline.md`](typed-markdown-embed-pipeline.md).

Change interactive Markdown embeds into compact disclosure rows. Each row shows a title, places **Open in Window** at the trailing edge, expands an interactive renderer inline, and scales with reader page zoom.

Rows start collapsed. A reader can keep up to four rows expanded at once. The fifth row stays collapsed and can still open in a separate window.

# Implementation Summary

Extend the existing renderer-card and native-attachment design instead of replacing the Markdown reader. The HTML card remains in document flow and becomes the collapsed disclosure row. An expanded renderer remains a native overlay projected onto that card.

This work covers JSON Canvas, Excalidraw, Mermaid, and image content that an approved renderer explicitly claims. Ordinary Markdown images stay unchanged.

Use these title rules:

- `![System architecture](target)` uses `System architecture` as the row title when `target` resolves to an approved interactive image renderer.
- ```` ```mermaid "System architecture" ```` uses the quoted text as the row title.
- Untitled embeds use the registered renderer display name.
- A title is presentation metadata. It does not change renderer bytes, authorization, or the stable block digest.

The main touch points are:

- `Sources/WikiFSTypes/Renderer/RendererPhase3Types.swift`
- `Sources/WikiFS/Reader/MarkdownHTMLRenderer.swift`
- `Sources/WikiFS/Reader/WikiReaderView.swift`
- `Sources/WikiFS/Reader/WikiReaderContainerView.swift`
- `Sources/WikiFS/Reader/RendererAttachmentCoordinator.swift`
- `Sources/WikiFS/Renderer/SourceRendererPresentationPlanner.swift`
- `Sources/WikiFS/Renderer/RendererInlineAttachmentResolver.swift`
- Mermaid bootstrap code in `Sources/WikiFS/Reader/WikiReaderView.swift`
- renderer descriptor, registry, installed-renderer, and authorized-input contracts

Do not execute renderer package JavaScript in the Markdown document. Do not weaken exact-version, MIME, digest, size, capability, or generation checks. Do not change separate-window zoom behavior.

# Implementation Plan

## Phase 0: Prepare the branch and Paseo execution slices

1. Create a Conventional Branch such as `feature/collapsible-renderer-embeds`. Never work on `main`.
2. Enable the repository hooks if needed.
3. Use Paseo subagents for the bounded slices below. Give each subagent one file-ownership area and its named tests.
4. Require each coding subagent to use an appropriate lower-power model, as required by repository guidance.
5. Merge slices in dependency order. Rebase dependent slices before integration. Do not let two subagents edit `WikiReaderView.swift` at the same time.

Recommended Paseo slices:

1. **Fence metadata:** typed fence-info parser, all fence consumers, and type tests.
2. **Keyed host contract:** replace the single-child container API and all host-facing coordinator call sites with keyed APIs and focused hosted fixtures.
3. **Card markup:** title plumbing, stable row DOM actions, and disclosure-row HTML tests.
4. **Typed image projection:** build a document-scoped image projection from exact source facts before Markdown conversion.
5. **Reader integration:** multi-attachment lifecycle, the four-row budget, zoom synchronization, and coordinator tests.
6. **Mermaid row:** keep Mermaid as an HTML/SVG disclosure region and preserve its existing trusted bootstrap boundary.
7. **Interactive image resolver:** consume the typed projection, add inline factory admission, and add security tests.
8. **Hosted validation and docs:** full reader scenarios, accessibility, design records, and progress evidence.

Land slice 2 before slices 3–8. Slice 2 owns `WikiReaderContainerView.swift`, the coordinator host-facing API in `WikiReaderView.swift`, and its focused fixtures. Do not split the single-child replacement across parallel agents. Slice 3 depends only on the stable row DOM and action names from slice 2. Slices 5–7 must rebase on the keyed-host contract.

Run slice 1 before slice 4. Slice 1 owns shared fence types and any fence-related changes in `SourceRendererPresentationPlanner.swift`. Slice 4 must rebase after slice 1 and must not edit those files while slice 1 is active.

Serialize the other shared-file ownership in this order: slice 3, then slice 5, then slice 6, then slice 7. Slice 3 hands off `MarkdownHTMLRenderer.swift`; slice 5 hands off `WikiReaderView.swift`; slices 6 and 7 then take both files in order. Do not run these shared-file slices in parallel.

## Phase 1: Add typed fence title metadata

1. Add a pure fence-info value and parser near `MarkdownFencedBlock` in `WikiFSTypes`.
2. Parse one approved alias followed by one optional quoted title:

   ````markdown
   ```mermaid "System architecture"
   graph TD
     A --> B
   ```
   ````

3. Preserve all existing one-token fences.
4. Preserve the authored title case and internal spaces.
5. Support escaped quotes and backslashes inside a quoted title.
6. Reject unquoted trailing tokens, an unclosed quote, trailing garbage, and an empty title. Keep the existing typed malformed fallback.
7. Parse the alias separately from the title. Do not lowercase the display title.
8. Change canonical fence identity to use the parsed renderer alias and content bytes, not the full normalized info string. Existing one-token rich fences remain byte-stable because their normalized info equals the alias. A title edit must not change `MarkdownBlockID`, placeholder ID, `RendererEmbeddedContent.InlineArtifact`, or authorized payload bytes.
9. Add a typed optional display title to `RendererEmbedPlan` or a small shared embed-display descriptor. Do not overload control labels, accessibility summaries, or raw strings with several meanings.
10. Keep all new types `Codable`, `Hashable`, and `Sendable` where their containing contracts require those conformances.
11. Inventory every fence-info consumer. Update Mermaid validation, `MermaidSourceDetector`, Markdown linting, source-embed conversion, and renderer presentation to use the shared parser or an explicit adapter.
12. Accept the same optional quoted title for backtick and tilde fences when CommonMark supplies the same info string. Preserve CRLF handling.
13. Keep the parsed title out of `language-mermaid` classes, Mermaid source bytes, and canonical block identity.

## Phase 2: Make the HTML card the collapsed disclosure row

1. Change `MarkdownHTMLRenderer.rendererCardHTML` to emit a compact semantic row with:
   - a disclosure control at the leading edge;
   - the authored or fallback title next;
   - **Open in Window** at the trailing edge;
   - an expansion region below the row;
   - a readable fallback summary and failure message when inline rendering is unavailable.
2. Use native document text scale and system-style spacing. Avoid a card-heavy visual treatment.
3. Keep the title on one line. Truncate long titles with an ellipsis before they displace the trailing button.
4. Use the renderer display name as the title fallback. Keep names such as `JSON Canvas` and `Excalidraw` in one mapping rather than scattered string switches.
5. Escape the title as text and as an accessibility value. Never insert authored title text as raw HTML.
6. Make every eligible row collapsed initially. Remove first-visible automatic mounting.
7. Keep the row and its trailing button in normal HTML flow. Use a per-placeholder expanded class or attribute for height reservation and accessibility state.
8. Give the disclosure control `aria-expanded`, `aria-controls`, a useful accessible name, and keyboard activation. Keep **Open in Window** as a separate focusable control.
9. Do not turn an unsupported or failed renderer into an empty row. Preserve readable source, code, summary, or image fallback.

## Phase 3: Replace the single-child native host with a keyed host

1. Replace `WikiReaderContainerView.attachmentChild` with a dictionary keyed by `RendererAttachmentPlaceholderID`.
2. Replace the single clip rectangle with keyed visible rectangles.
3. Add keyed APIs for activation, viewport update, focus, collapse, failure removal, DOM removal, and teardown.
4. Retain each `NSHostingView` while its row remains expanded. Geometry, scrolling, and zoom updates must not recreate the renderer session.
5. Route hit testing to the child whose visible frame contains the pointer. Pass points outside all expanded children to the `WKWebView`.
6. Define deterministic z-order behavior for overlap. The most recently focused child wins only in an actual overlap.
7. Keep document reload and reader dismantle as remove-all operations. Keep DOM removal and renderer failure as remove-one operations.
8. Keep Escape scoped to the focused renderer. It collapses that row and restores focus to the reader.
9. Give each child the authored title for its accessibility label. Avoid the current generic `Interactive renderer` title.
10. Keep **Open in Window** at the trailing edge of the row. Do not duplicate it in an expanded-only native toolbar unless the HTML row becomes occluded by the native projection.
11. If the native projection covers the row, reserve a scaled native header and mirror the same title, disclosure state, and trailing window action. Keep one accessible instance of each action.
12. Use named layout metrics for row height, spacing, insets, and maximum expansion height. Do not add magic numbers at call sites.

## Phase 4: Support independent expansion with a bounded policy

1. Keep `RendererAttachmentCoordinator` as the per-document finite state machine.
2. Retain keyed states for every placeholder. Do not introduce parallel Boolean flags.
3. Introduce a new product resource policy named `maximumExpandedRendererRows` with a value of four per reader document. This replaces the current one-active policy. Do not describe it as an existing renderer-session limit.
4. Enforce the row budget before resolver, factory, native host, or installed WebKit session creation. Apply it uniformly to native and installed inline renderers.
5. Let four rows reach `.active` independently. Do not collapse another row when one expands.
6. Treat the process-wide installed-WebKit permit pool as a separate constraint. Other readers, source panes, and full-renderer windows can consume its four permits.
7. When no WebKit permit is available, keep the row in `.card` and store a typed `RendererAttachmentActivationRefusal.resourcePressure` on its record. Do not add a Boolean flag and do not transition it to terminal `.failed`. Use the typed refusal to produce the accessible explanation.
8. A later expansion attempt must retry after a permit becomes available. **Open in Window** remains a direct user action and can report the same retryable pressure.
9. When the row budget is full, keep another row collapsed and provide a short accessible explanation. Keep **Open in Window** available. The fifth attempt must perform zero resolver, factory, host-child, and session creation calls.
10. Collapse, failure, DOM removal, or teardown of one expanded row frees exactly one row-budget slot and releases its installed session permit when applicable.
11. Change `.showInFullRenderer` handling so cap pressure does not open a window without a direct user action.
12. Remove all single-child checks from `WikiReaderView.Coordinator`.
13. Keep geometry, collapse controls, failure, DOM removal, and session teardown keyed by placeholder.
14. Keep generation rejection and exact activation admission unchanged.
15. Make failure of one renderer preserve all other expanded rows and their interaction state.
16. Keep the pre-existing `maximumMessageByteCount` constant out of this change unless execution proves it has a live message-boundary consumer. Do not claim this feature enforces an unrelated inert constant.

## Phase 5: Synchronize page zoom without double scaling

1. Keep `WKWebView.pageZoom` as the reader zoom source of truth.
2. Continue to convert each CSS rectangle through `RendererAttachmentGeometry.overlayRect(cssRect:pageZoom:readerBounds:)`.
3. Track the last applied reader zoom. Only assign `webView.pageZoom`, reproject children, and request geometry when the value changes.
4. After a reader zoom change in `WikiReaderRep.updateNSView`, reproject every mounted child from the latest stored CSS geometry.
5. Explicitly request one JavaScript geometry report after a zoom change. Do not depend only on WebKit resize notifications or create an update/report loop.
6. Scale the disclosure row through normal `pageZoom` behavior.
7. Let the native child fill its already-scaled frame. Do not apply a second visual transform to the whole child.
8. Scale native header metrics, controls, and type from the same reader zoom value if the header is native. Keep pointer coordinates in the child’s local coordinate space.
9. Verify clicks, drags, panning, selection, and renderer-owned zoom gestures at reader zoom values below and above 100 percent.
10. Keep the renderer’s own canvas zoom independent from reader page zoom. Page zoom changes presentation size. Renderer zoom changes its viewport state.
11. Do not pass reader zoom to a separate renderer window. A new window uses its existing independent presentation state.

## Phase 6: Give Mermaid an HTML/SVG disclosure row

1. Use the same semantic renderer-row markup and title rules as other embeds, but keep Mermaid expansion inside the HTML document.
2. Do not route Mermaid through `RendererInlineAttachmentResolver`, a native child, an installed renderer session, or the four-native-row budget.
3. Preserve the vendored Mermaid 10.9.6 execution boundary. Do not add network loading or package JavaScript to the Markdown document.
4. Update document bootstrap detection so titled Mermaid fences still load the vendored library when available.
5. On an explicit DOM disclosure action, render or reveal the Mermaid SVG inside that row’s expansion region. Report geometry again after rendering.
6. Preserve the existing escaped `textContent`, theme, parse-failure fallback, and no-library readable raw-code behavior.
7. Preserve `.mmd` source embed behavior and the longer-fence handling for embedded backtick runs.
8. Use the quoted fence title when present. Use `Mermaid` when absent.
9. Keep the rendered SVG interactive only to the degree supported today. Do not widen Mermaid capabilities as part of this work.
10. Keep Mermaid outside the four-row native-session budget. Its HTML expansion remains bounded by existing document and Mermaid input limits.

## Phase 7: Admit interactive image embeds without changing ordinary images

1. Keep `MarkdownHTMLRenderer.visitImage` unchanged for images that no renderer claims.
2. Before Markdown conversion, build a `Sendable` document-scoped `MarkdownImageEmbedProjection` or equivalent typed map. Build it from the authoritative exact sibling/source index, immutable pinned source versions and bytes, normalized MIME, registry snapshot, descriptor match, inline-factory capability, activation admission, and generation.
3. Make the pure Markdown renderer consume one typed result per image target: `.ordinary(resolvedURL)` or `.interactive(RendererEmbedPlan, admittedSourceContext)`. Do not make the renderer inspect paths, registry state, stores, or raw `wiki-blob:` URLs.
4. Add an opt-in image-embed planning seam before ordinary `<img>` emission.
5. Convert `![Title](target)` into a renderer disclosure row only when all checks pass:
   - `target` resolves exactly to a source or sibling image entry;
   - the source has immutable bytes and an exact `SourceVersionID` or `SourceMarkdownVersionID`;
   - MIME is normalized and byte-backed;
   - `RendererRegistrySnapshot.matching(RendererMatchInput)` selects an approved descriptor with an explicit image MIME matcher;
   - the selected descriptor supports inline presentation through a registered native or installed renderer factory;
   - descriptor, bridge, decoded-byte, and message caps pass;
   - exact input, capability, document generation, and activation admission match.
6. Preserve the current 48,384-byte authorized bridge-input ceiling for this feature. Images above that limit stay ordinary images. Document the limit for renderer-package authors and do not silently raise the security boundary in this plan.
7. Do not use filenames, basenames, extensions, URLs, or fuzzy path matching as authorization.
8. Reuse the typed `RendererEmbeddedContent.Source` and exact authorized reader where possible. Add a typed image-inline admission or factory seam only where the current source path cannot express inline use.
9. Do not invent an image-shaped `InlineArtifact`. That type remains for page-version Markdown fences.
10. Extend the **Open in Window** activation route for exact pinned `.source` input, or use the registered-context message route only. In either design, cross-check the exact source version, descriptor, capability, and generation against admission. Never authorize a source from URL data alone.
11. Use the Markdown alt text as the row title. Preserve it as the ordinary image alt text in every fallback.
12. If no descriptor claims the MIME, the image exceeds 48,384 bytes, or any admission check fails, render the original image exactly as before.
13. Preserve absolute, data, `wiki-blob:`, and unresolved relative image behavior.
14. Add no built-in generic image renderer merely to satisfy this path. The feature activates when an approved renderer package or built-in renderer explicitly claims the image MIME and supplies an inline factory.

## Phase 8: Accessibility, macOS behavior, and typography

1. Use a compact macOS disclosure-row pattern with progressive disclosure.
2. Use the system font. Match surrounding body text rather than creating a new display scale.
3. Use regular or medium weight for the title. Reserve semibold for a focus or state signal only when needed.
4. Keep a minimum useful pointer target for disclosure and window controls after zoom.
5. Support keyboard traversal, Space or Return activation, Escape collapse, and visible focus rings.
6. Announce title, renderer type when useful, expanded state, cap failure, renderer failure, and the separate-window action.
7. Respect light and dark appearance, system accent color, Increase Contrast, and Reduce Motion.
8. Use a short disclosure transition only when motion is allowed. Do not animate renderer geometry while the user drags inside it.
9. Avoid synchronous SwiftUI state writes from `makeNSView`, `updateNSView`, AppKit setters, or delegate callbacks reached during a SwiftUI update pass.

## Phase 9: Documentation, review, and delivery

1. Update `plans/dynamic-inline-renderer-attachments.md` as the active design record. Replace the one-active and auto-mount policy with disclosure rows, keyed hosts, the four-active cap, title rules, zoom behavior, and exact image admission.
2. Update the retained `plans/markdown-renderer-embeds.md` only with a short supersession note if needed. Do not rewrite retained history.
3. Update `PLAN.md` to describe the current renderer attachment design.
4. Add user-facing authoring syntax to `docs/user-guide/renderer-packages.md` or the closest renderer authoring page:
   - `![Title](target)` for a renderer-claimed image source;
   - ```` ```renderer "Title" ```` for a titled rich fence;
   - the 48,384-byte interactive-image input limit;
   - fallback title and ordinary-image behavior.
5. Add a dated feature progress record under `progress/` with test and review evidence. This is a design-relevant feature, not a bug fix.
6. Use the `ste-writing` skill for all documentation, progress text, PR text, and user-facing messages.
7. Run `swiftui-pro` before implementation decisions and again during final review. Apply macOS 15 and Swift 6.0 compatibility filters.
8. Use `macos-design` and `typography-designer` for the final row layout review.
9. Commit all repository changes with a Conventional Commit. Push the feature branch and open a PR.
10. Do not merge, enable auto-merge, enqueue the PR, or change issue state. Report the exact PR head for operator approval.

# Diagram scroll zoom update

The pointer wheel now controls renderer zoom while the pointer is over a diagram. The renderer consumes only unmodified wheel events. Modified wheel events remain available to system and app shortcuts.

- Mermaid SVG uses a bounded 0.5–3.0 viewport transform in an expanded row. The transform keeps the diagram point below the pointer fixed.
- Generic SVG sources use the built-in inert SVG renderer in Rendered, Split, and separate-window presentations. JavaScript and navigation are disabled, and wheel zoom is bounded to 0.5–3.0.
- The Mermaid window uses the shared app wheel-step monitor and the same 0.5–3.0 scale bounds.
- JSON Canvas now uses its reviewed Web renderer package in both presentations. The package owns bounded wheel zoom and keeps renderer viewport state separate from reader zoom. See [`json-canvas-renderer-package.md`](json-canvas-renderer-package.md).
- Excalidraw uses its shared reviewed package in both presentations. Its existing 0.25–4.0 scale now keeps the diagram point below the pointer fixed.
- Reader page zoom remains separate. It changes attachment presentation size but does not change renderer viewport state.
- Trackpad magnification and keyboard zoom controls remain available where they existed before this update.

# Acceptance Criteria

- **AC.1:** Every eligible interactive embed starts as a collapsed line item with a disclosure control, a readable title, and a trailing **Open in Window** action.
- **AC.2:** A titled rich fence accepts ```` ```renderer "Title" ```` syntax. Existing one-token fences remain valid, malformed title syntax fails closed, and title edits do not change the block digest.
- **AC.3:** A renderer-claimed `![Title](target)` uses `Title` when its authorized bytes are at most 48,384 bytes. An oversized, unclaimed, unresolved, external, or ordinary image renders exactly as an ordinary image with its alt text.
- **AC.4:** Selecting a disclosure row expands its interactive renderer inline. Selecting it again or pressing Escape collapses only that row.
- **AC.5:** Four rows can remain expanded independently. A fifth row remains collapsed, explains the row limit accessibly, and can request a new window. Process-wide WebKit permit pressure keeps either action retryable and does not permanently fail the row.
- **AC.6:** Scrolling, resizing, document mutation, and geometry from another embed do not move, recreate, or close an unrelated expanded renderer.
- **AC.7:** Reader zoom scales collapsed rows and expanded renderers. Pointer interaction remains aligned at 50, 100, 150, and 300 percent reader zoom.
- **AC.8:** Renderer-owned canvas zoom remains independent from reader zoom. Separate windows do not change when reader zoom changes.
- **AC.9:** Mermaid uses the same disclosure interaction while preserving existing SVG rendering, escaping, theme, source-embed, and raw-code fallback behavior.
- **AC.10:** Exact source or page version, MIME, digest, descriptor, size, capability, and generation checks still gate renderer activation. No raw URL or path string becomes an authorization token.
- **AC.11:** DOM removal, renderer failure, reload, and teardown close the correct renderer sessions. One-row failure does not affect other rows.
- **AC.12:** Titles and controls work with keyboard navigation and accessibility APIs. Long titles truncate without covering the window action.
- **AC.13:** The required SwiftPM build and test gates pass on macOS, and the implementation review has no unresolved critical findings.
- **AC.14:** Active design, user syntax, master index, and dated feature progress documentation match the shipped behavior.

# Test Strategy

Use Swift Testing for new unit and integration tests. Keep hosted AppKit/WebKit suites serialized and time-bounded. Reuse the repository’s nonblocking JavaScript and process wait helpers.

| Acceptance criterion | Named regression tests |
| --- | --- |
| AC.1 | `MarkdownHTMLRendererTests.interactiveEmbedsRenderInitiallyCollapsedDisclosureRows`; `disclosureRowHasTrailingIndependentWindowActionAndARIAControls` |
| AC.2 | `MarkdownFenceInfoTests.acceptsUntitledApprovedAlias`; `parsesQuotedTitleAndEscapes`; `rejectsMalformedTitleForms`; `untitledAndDifferentlyTitledFencesShareBlockDigestAndPlaceholder`; Mermaid validator/detector/linter titled-fence tests |
| AC.3 | `MarkdownHTMLRendererTests.claimedImageUsesAltAsRendererTitle`; `oversizedOrUnclaimedImageRemainsOrdinaryImage`; `SiblingResolutionRenderTests.externalAndUnresolvedImagesRemainUnchanged` |
| AC.4 | `RendererAttachmentCoordinatorTests.disclosureExpandsAndCollapsesOnlySelectedAttachment`; `escapeCollapsesFocusedAttachmentAndRestoresReaderFocus`; hosted Space/Return activation scenario |
| AC.5 | `RendererAttachmentCoordinatorTests.fourAttachmentsExpandIndependently`; `fifthAttachmentCreatesNoResolverFactoryHostOrSession`; `RendererSessionIsolationTests.sessionPoolExhaustionKeepsRowCollapsedAndRetryable`; `retrySucceedsAfterPermitRelease` |
| AC.6 | `RendererAttachmentCoordinatorTests.keyedGeometryUpdatesOnlyMatchingChild`; `collapseFailureAndRemovalPreserveOtherChildren`; `retainedChildPreservesInteractionStateAcrossGeometryUpdates` |
| AC.7 | `RendererAttachmentCoordinatorTests.zoomReprojectsEveryMountedChild`; `RendererAttachmentSpikeHostedTests.multipleAttachmentsStayAlignedAt50_100_150_300Percent`; `JSONCanvasAttachmentHostedTests.readerZoomKeepsClickAndDragAligned` |
| AC.8 | `JSONCanvasAttachmentHostedTests.readerZoomPreservesCanvasViewportState`; `RendererActivationPresentationTests.separateWindowStateIgnoresReaderZoomChanges` |
| AC.9 | `MarkdownHTMLRendererTests.titledMermaidPreservesLanguageAndEscaping`; `mermaidSourceEmbedStillUsesLongFence`; `RendererAttachmentSpikeHostedTests.mermaidExpandsToRenderedSVGAndFallsBackWithoutLibrary` |
| AC.10 | `RendererAuthorizedInputReaderTests.imageInlineInputRequiresExactPinnedSourceAndDerivedSizeCap` asserts code behavior against `WikiAppWebViewPolicy.maximumBridgeInputPayloadByteCount`; `RendererArtifactMatcherTests.imageMIMERequiresExplicitStrongMatcher`; `RendererActivationPresentationTests.imageWindowActionRejectsForgedSourceAndStaleGeneration` |
| AC.11 | `RendererAttachmentCoordinatorTests.domRemovalClosesOnlyMatchingChild`; `failureClosesOnlyMatchingSession`; `reloadAndDismantleCloseAllChildren` |
| AC.12 | `MarkdownHTMLRendererTests.disclosureRowEscapesTitleAndExposesExpandedState`; `RendererAttachmentCoordinatorTests.longTitleTruncatesBeforeTrailingAction`; hosted keyboard and accessibility scenario in `RendererAttachmentSpikeHostedTests` |
| AC.13 | `make build`; focused suites during each slice; `make test`; `make prompts && make version && swift build`; `make prompts && make version && swift test`; `scripts/test-with-watchdog.sh` when the full suite needs the repository watchdog |
| AC.14 | Add `RendererDocumentationContractTests.collapsibleEmbedSyntaxAndLimitsMatchDesignRecord`, or extend the repository’s existing renderer-package documentation contract suite to assert the author syntax, 48,384-byte limit, design-record link, and `PLAN.md` index entry. |

Also run focused tests after each Paseo slice:

1. Fence parser, Mermaid validator/detector/linter, and digest tests.
2. `MarkdownHTMLRendererTests` and renderer type tests.
3. `RendererAttachmentCoordinatorTests`.
4. `RendererAttachmentSpikeHostedTests` and `JSONCanvasAttachmentHostedTests`.
5. Renderer registry, matcher, authorized-input, installed-host, and session-isolation tests.
6. Full `make test` before PR creation.

Replace or rename the existing tests that encode superseded behavior: `admittedJSONCanvasFenceAutoMountsWithoutActivation`, `packageStyleInlineResolverAutoMounts`, and `activationLimitPreservesExistingAttachment`. Their replacements must assert initial collapse, explicit activation, four-row admission, zero work on the fifth attempt, and retry after resource release.

Run scoped mutation testing for the new pure fence parser if the installed mutation tool is available. Record the result, but do not make mutation testing a release blocker.

Manual validation remains useful for visual quality, but it does not replace the named tests. Check these scenarios in a signed app:

- light and dark appearances;
- long and short titles;
- keyboard-only expansion and separate-window opening;
- four expanded rows and a blocked fifth row;
- zoom at 50, 100, 150, and 300 percent;
- pointer selection and drag inside JSON Canvas;
- Mermaid SVG expansion;
- an approved interactive image package and an ordinary image fallback.

# Review Strategy

Before implementation, the plan receives a `plan-reviewer` pass. Fix or rebut all findings. Repeat the review after any critical or high finding.

During execution:

1. Give each Paseo slice an independent review agent after its focused tests pass.
2. Do not let an agent review its own changes as the only review.
3. Use heterogeneous model families for independent reviews, as required by `review-model-diversity`.
4. Run `swiftui-pro` on `WikiReaderContainerView.swift`, `WikiReaderView.swift`, and renderer SwiftUI surfaces.
5. Run a security review on image admission, exact input authorization, installed renderer sessions, generation handling, and teardown.
6. Run an accessibility and macOS interaction review on disclosure semantics, focus, keyboard controls, title truncation, and appearance.
7. Run a final general-purpose implementation review after all automated tests pass.
8. Fix or explicitly rebut every finding. If a review reports a critical finding, fix it and repeat that review before PR submission.

# Documentation Strategy

Update these documents:

- `plans/dynamic-inline-renderer-attachments.md`: active architecture and policy.
- `PLAN.md`: master index entry.
- `docs/user-guide/renderer-packages.md` or the nearest renderer authoring guide: title syntax and interaction.
- `progress/<date>-collapsible-renderer-embeds.md`: implementation and validation evidence.

Keep `plans/markdown-renderer-embeds.md` as retained history. Add only a supersession pointer when needed.

Use Simplified Technical English. Name the UI consistently as a **renderer row**. Name its two states **collapsed** and **expanded**.

# Risks, Blockers, and Required Decisions

- **Mermaid compatibility:** Mermaid currently uses a separate HTML/SVG bootstrap path. The migration must preserve escaping, theme, no-library fallback, and source-embed behavior.
- **Image admission:** The current image path has no generic inline renderer factory. This plan includes a typed exact-source admission seam. It does not convert every image and does not create a generic renderer claim. The existing authorized bridge limits image input to 48,384 bytes, so larger images remain ordinary images.
- **Resource use:** Four expanded native or installed renderers are a new reader-document product budget, not an existing package-session guarantee. Enforce it before resolver or session creation. The fifth row must remain collapsed and must create no renderer resources.
- **Process-wide permits:** Installed renderer WebKit sessions share a four-permit process pool with other readers, panes, and windows. Permit exhaustion must leave a row collapsed and retryable. It must not become terminal `.failed`.
- **Geometry timing:** `pageZoom` changes may not produce a reliable WebKit resize callback. The reader must request geometry and reproject all children explicitly.
- **Double scaling:** Native frame conversion already multiplies CSS geometry by `pageZoom`. A second whole-view transform would break hit testing.
- **Session state:** Collapsed rows release their inline child and can lose renderer-owned state. Expanded rows retain state across scroll, resize, and page zoom. This is intentional for bounded resource use.
- **Fallback integrity:** Any parse, match, authorization, package, size, or session failure must preserve readable code or image content.
- **Paseo integration:** Slices 1, 2, and 3 can proceed with agreed APIs. Reader integration must wait for the keyed host. Mermaid and image slices must rebase after common card and lifecycle changes.
- **Platform boundary:** macOS 15 and Swift 6.0 are authoritative. Filter out skill guidance that requires newer platforms or Xcode-only build features.