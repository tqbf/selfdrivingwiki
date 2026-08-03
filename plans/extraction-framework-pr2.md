# Plan: Extraction Framework PR2 — HTML Extraction Trigger (#799)

**Parent plan:** [`plans/extraction-framework.md`](extraction-framework.md) (4-PR staged
plan to bring HTML + Podcast extraction to parity with PDF). This doc is the deep
dive for PR2 only — the trigger UI + inline extraction wiring that must ship
BEFORE PR3 removes auto-extraction at ingest.

PR1 (merged in `69fe6e9`, #802) shipped the typed enums
(`HtmlExtractionBackend { defuddle, tagBased }`, `PodcastTranscriptionBackend`)
and the `ExtractionConfig.htmlBackend` / `.podcastBackend` optional fields, plus
the Settings pickers. No behavior change — extraction still auto-runs at ingest
with the current `enrichWithDefuddle` path. This PR builds on those types.

## Goal

Add the "Extract" button and the "Re-extract with" menu for HTML sources, using
the **existing inline extraction path** (not the queue engine — that's a
separate, PDF-coupled sub-project deferred per the parent plan's "Out of scope"
section). After this PR, an HTML source with no extracted markdown shows a
prominent "Extract" call-to-action; once extracted, the provenance chip offers
"Re-extract with Defuddle / Tag-based", with each alternative coexisting (no
clobber) — exactly mirroring the PDF lifecycle.

**Critical ordering constraint:** this PR ships BEFORE PR3 (which removes the
`enrichWithDefuddle` calls at ingest). At every intermediate state the user
must have a way to extract — either via the existing auto-extraction (still in
place in PR2) or via the new Extract button (added in PR2). PR3 lands after
this PR is merged, at which point auto-extraction goes away but the Extract
button remains.

## Design summary

The HTML trigger intentionally mirrors the PDF trigger's surface — same
`needsExtraction` gate, same provenance chip, same "Re-extract with" menu —
but the underlying mechanism is different. The PDF path routes every
extraction (initial + re-extract) through the queue engine
(`QueueItemRequest(payload: QueueItemPayload(sourceIDs:))`), which is
PDF-coupled in three places: `ExtractionResolution.pdfData`,
`convert(pdfData:)`, and `seedPdfMarkdown`. Generalizing the queue to handle
arbitrary content types is a sub-project in its own right (deferred — see
parent plan "Out of scope"). Instead, HTML extraction uses the **simpler
inline path** already used by `enrichWithDefuddle` at ingest time:

1. `WikiStoreModel.extractHtml(sourceID:backend:)` reads the source's HTML
   bytes via `store.sourceContent(id:)` (the existing CAS-resolved read).
2. Runs the chosen extractor — `defuddle` (the injected `htmlMarkdownExtractor`)
   or `TagBasedHtmlExtractor` (the new `HtmlMarkdownExtractor` conformer around
   `HTMLToMarkdown.convert`).
3. Writes the result via `store.appendProcessedMarkdown(...)` (the same write
   path `enrichWithDefuddle` → `appendExtractedMarkdown` uses), stamping the
   technique (`"defuddle"` or `"html-to-markdown"`) so the alternatives UI
   shows the producer.

`appendProcessedMarkdown` always appends a new version (does not clobber);
the FIRST version becomes HEAD by the default-active rule, later ones ride as
alternatives until nominated via `setActiveMarkdown`. This means re-extract
naturally creates a coexisting alternative — no special "append alternative"
path needed.

### Config wiring

`WikiStoreModel` is deliberately NOT config-aware (config is read by
`ExtractionCoordinator` in `WikiFSEngine`, and `WikiStoreModel` lives in
`WikiFSCore` — core can't depend on the engine). Following the same pattern as
the existing `htmlMarkdownExtractor` injection (`:318`), the chosen HTML
backend is injected as a new `@ObservationIgnored public var htmlBackend:
HtmlExtractionBackend?` on `WikiStoreModel`. `nil` means "no default chosen" —
the UI prompts the user to pick; the Extract button uses the configured backend
or falls back to a flat list of `HtmlExtractionBackend.allCases` in the menu.

Wired at app scope in the same place `htmlMarkdownExtractor` is injected today
(`WikiSession.init` at `:231`): `model.htmlBackend = htmlBackendResolver()` —
the resolver reads `ExtractionConfig.htmlBackend` once per session and is
provided by `SessionManager.htmlBackendResolver` (mirroring
`htmlMarkdownExtractorFactory`). The `WikiSession` initializer carries the new
`htmlBackendResolver` parameter with a `{ nil }` default (headless/daemon/test
callers stay untouched), and `SessionManager.init` carries the matching resolver
with the same default. `WikiFSApp` resolves the config in the same constructor
block where it already constructs `ExtractionCoordinator` (around `WikiFSApp.swift:133`).

## Concrete changes

### 1. Wrap `HTMLToMarkdown` in an `HtmlMarkdownExtractor` conformer

`Sources/WikiFSMarkdown/HTMLToMarkdown.swift` — append a `public struct
TagBasedHtmlExtractor: HtmlMarkdownExtractor`. The conformer is a thin adapter
around `HTMLToMarkdown.convert(_:)` (which already scopes to main content,
strips noise containers, decodes entities, and returns `Result(markdown:title:)`).
It's a `struct` not an `enum` because the protocol requires instance
conformance (matches the `LocalDefuddleExtractor` shape in
`Sources/WikiFS/Sources/DefuddleExtractionService.swift:387`). The `markdown`
rides on `Result.markdown`; the `title` carries through to
`HtmlExtractionResult.title` so the provenance chip / filename stem remains
consistent with the defuddle path. `author`/`description`/`published`/`wordCount`
are `nil` — the tag-based converter doesn't extract frontmatter.

Lives in `WikiFSMarkdown` (not `WikiFS`) so it's link-safe from `WikiStoreModel`
in `WikiFSCore` — `WikiFSCore` already depends on `WikiFSMarkdown`
(`MarkdownExtractor` lives there). Mirrors how the defuddle conformer in the
WikiFS target is reachable from `WikiStoreModel` only via the injected protocol.

### 2. Generalize `SourceDetailView` predicates

Three concrete edits (line numbers refer to `SourceDetailView.swift` before
this PR — see the implementation commit for final positions):

- **`needsExtraction` (`:300`)**: change from `isPDF && !hasMarkdown` to
  `isExtractable && !hasMarkdown` where `isExtractable` is a new computed prop
  equal to `isPDF || isHTMLSource`. This single gate then drives the Extract
  button for both content types. The exclusivity comment ("an unextracted PDF
  shows Extract, so Refresh is suppressed") is updated to mention HTML.
- **`extractionProvenanceChip` (`:659`)**: the chip's gate changes from
  `if isPDF, hasMarkdown, let head = headVersion` to `if isExtractable,
  hasMarkdown, let head = headVersion`. The chip body stays the same —
  `processedMarkdownHistory` returns versions for both PDFs and HTML sources
  uniformly.
- **Re-extract menu (`:1387`)**: the current `ForEach(ExtractionBackend.allCases,
  id: \.self)` is split into two content-type-aware branches — `isHTMLSource` →
  `ForEach(HtmlExtractionBackend.allCases, id: \.self)` calling
  `runHtmlReExtraction(with:)`; otherwise the PDF branch stays unchanged. The
  two branches are mutually exclusive (a source is either HTML or PDF, never
  both — `isHTMLSource` excludes the PDF MIMEs and vice versa).

### 3. HTML extraction trigger (inline, NOT through queue)

`Sources/WikiFSCore/Store/WikiStoreModel.swift` — add:

```swift
@discardableResult
public func extractHtml(
    for sourceID: PageID,
    backend: HtmlExtractionBackend
) async -> SourceMarkdownVersion? {
    guard let data = try? store.sourceContent(id: sourceID),
          let html = String(data: data, encoding: .utf8)
              ?? String(data: data, as: UTF8.self).data(using: .utf8).flatMap({ String(data: $0, encoding: .utf8) }) else {
        DebugLog.store("WikiStoreModel.extractHtml: source bytes unreadable (source=\(sourceID.rawValue))")
        return nil
    }
    let (markdown, technique) = await Self.extractHtml(html: html, backend: backend, using: htmlMarkdownExtractor)
    guard !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        DebugLog.store("WikiStoreModel.extractHtml: extractor returned empty markdown (source=\(sourceID.rawValue), backend=\(backend.rawValue))")
        return nil
    }
    do {
        return try store.appendProcessedMarkdown(
            sourceID: sourceID, content: markdown,
            origin: .extraction, note: "extract via \(backend.displayName)",
            technique: technique)
    } catch {
        DebugLog.store("WikiStoreModel.extractHtml appendProcessedMarkdown failed (source=\(sourceID.rawValue)): \(error)")
        return nil
    }
}
```

(`extractHtml(html:backend:using:)` is a private static helper that dispatches
to the defuddle extractor or `TagBasedHtmlExtractor` based on the backend
value — keeps the public method small.)

`WikiStoreModel` already had `htmlToMarkdownTechnique = "html-to-markdown"` —
the new path reuses it; the defuddle branch adds a
`defuddleTechnique = "defuddle"` constant (which is what `FormatMaterializer.enrich`
returns when defuddle succeeds today; `appendExtractedMarkdown` already stamps
this from `m.extractionTechnique`).

`reExtractHtml(for:backend:)` is the same method: `appendProcessedMarkdown`
always appends — the first call creates the HEAD; subsequent calls append
coexisting alternatives. The view-level `runHtmlReExtraction` mirrors
`runReExtraction(with:)` (`:1426`): sets `isExtracting`, calls
`extractHtml(for:backend:)`, refreshes `headVersion` on success. Same as PDF.

### 4. Config wiring (`WikiStoreModel` injection)

`Sources/WikiFSCore/Store/WikiStoreModel.swift` `:318` — beside the
`htmlMarkdownExtractor`:

```swift
/// The configured HTML extraction backend (issue #799). Set at app wiring
/// time from `ExtractionConfig.htmlBackend` so the Extract button and the
/// "Re-extract with" menu have a default. `nil` = no default; the menu
/// lists all `HtmlExtractionBackend.allCases` so the user picks.
@ObservationIgnored public var htmlBackend: HtmlExtractionBackend?
```

`Sources/WikiFSEngine/SessionManager.swift` `:68` — beside
`htmlMarkdownExtractorFactory`:

```swift
public let htmlBackendResolver: @MainActor () -> HtmlExtractionBackend?
```

`Sources/WikiFSEngine/WikiSession.swift` `:158` (init param) + `:231` (assignment):

```swift
htmlBackendResolver: @escaping @MainActor () -> HtmlExtractionBackend? = { nil },
// ...
model.htmlBackend = htmlBackendResolver()
```

`Sources/WikiFS/Window/WikiFSApp.swift` around `:218` (where `SessionManager`
is constructed): add a `htmlBackendResolver` closure that reads
`ExtractionConfig.load(from: directory).htmlBackend`. Pass it through to the
session manager. Run once per session — the config file is re-read on each
session construction (matching `ExtractionCoordinator`'s behavior).

### 5. UI wiring in `SourceDetailView`

The Extract button (`:662`) already uses `needsExtraction` — once generalized
(`isExtractable && !hasMarkdown`), the button appears for HTML. The action
targets `runExtraction()` (`:1314`) which is PDF-coupled (queue engine) — add a
new `runHtmlExtraction()` that calls `store.extractHtml(for: file.id, backend:
chosenBackend())`. `chosenBackend()` resolves `store.htmlBackend` first, then
falls back to `.defuddle` if no default is set (the menu still lets the user
pick a different one explicitly).

The provenance chip's alternatives section is already content-agnostic —
`processedMarkdownHistory(for:)` returns version rows for both PDFs and HTML
sources; the labels render via `ExtractionAlternative.backendDisplayName(agentName:`
which is fed by `processedMarkdownAgentNames(for:)`. The technique is
the only thing that varies ("defuddle" / "html-to-markdown" vs "pdf2md" /
"claude" / etc.) and is already stamped on the version row.

## Acceptance criteria

- **AC.5**: "Extract" button appears on an HTML source with no markdown. Clicking
  it with defuddle creates a markdown version (technique `"defuddle"`).
- **AC.6**: "Extract" with tag-based creates a markdown version (technique
  `"html-to-markdown"`).
- **AC.7**: "Re-extract with" on an HTML source creates a coexisting alternative.
  The provenance chip shows both versions in the alternatives menu.
- **AC.8**: Existing auto-extraction at ingest still runs (PR3 hasn't landed yet).

## Tests

`Tests/WikiFSTests/WikiStoreModelHtmlExtractionTests.swift` (new) — covers
AC.5–AC.8:

- `extractHtml_withTagBased_stampsHtmlToMarkdownTechnique` — ingests an HTML
  source via `storeMaterialized` with no extractedMarkdown sidecar (bare HTML
  bytes), runs `model.extractHtml(for:backend:.tagBased)`, asserts the head
  version's technique is `"html-to-markdown"` and content is non-empty.
- `extractHtml_withDefuddleFallback_whenNoExtractorInjected` — same setup, calls
  `extractHtml(for:backend:.defuddle)` without injecting an
  `htmlMarkdownExtractor` (the model's `htmlMarkdownExtractor` is `nil`); asserts
  the call degrades to tag-based (technique `"html-to-markdown"`) and writes a
  version, rather than silently returning nil. Mirrors
  `FormatMaterializer.enrich`'s fallback semantics.
- `reExtractHtml_appendsCoexistingAlternative` — extract HTML with tag-based,
  then extract again with tag-based. Asserts the first version's row is still
  present, a second version was appended, and the two coexist (different ids,
  same parent chain).
- `extractHtml_onEmptyHtml_doesNotAppendEmpty` — guards the test in step 1
  against a future extractor change that returns an empty string.

SourceDetailView-level tests are minimal — the queue-coupled PDF tests
(`QueueExtractionTests.swift`) are the production-level surface, and the HTML
trigger is a direct method call (no queue). The view-level
`isExtractable`/`needsExtraction` predicate and the menu branch render are
covered by reading the code + the existing
`WikiFSAppTests/SourceDetailWebViewMenuTests.swift`.

## Build & test

```bash
make prompts && swift build       # compile (GeneratedPrompts.swift regen)
swift test                        # full suite — ~1.5 min (in-memory fixtures #658)
```

## Files touched

- **New:** `Tests/WikiFSTests/WikiStoreModelHtmlExtractionTests.swift`
- **Edit:** `Sources/WikiFSMarkdown/HTMLToMarkdown.swift` (conformer),
  `Sources/WikiFSCore/Store/WikiStoreModel.swift` (`extractHtml` + `htmlBackend`),
  `Sources/WikiFSCore/Store/WikiStoreModel.swift` (`htmlBackend` field),
  `Sources/WikiFSEngine/WikiSession.swift` (resolver param + assignment),
  `Sources/WikiFSEngine/SessionManager.swift` (resolver param + pass-through),
  `Sources/WikiFS/Window/WikiFSApp.swift` (resolver from config),
  `Sources/WikiFS/Sources/SourceDetailView.swift` (predicates + menu + trigger)

## Out of scope (covered by parent plan)

- Queue engine generalization — HTML extraction uses the inline path; the
  PDF-coupled queue stays PDF-only (deferred per parent plan).
- Auto-extraction at ingest — STILL RUNS in this PR. The three
  `enrichWithDefuddle` callers are NOT touched; PR3 removes them.
- The `addURLViaWebsite` website-snapshot-with-images path is unchanged —
  snapshots with images keep auto-extracting (image-src rewriting is
  inseparable from extraction, per parent plan §PR3 decision).
