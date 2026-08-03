# Plan: Content-Type Registry (fixes continuous ingestion enqueues no-markdown sources)

> **Issue:** Continuous ingestion enqueues sources with no path to markdown (PNG, XML, etc.)
> **Directive:** "We should have a content type registry that everything runs through that tells us if we can extract and ingest it."
> **Branch:** `content-type-registry`
> **Scope (PR1, per §11 corrected):** Registry + `WikiStoreModel.shouldAutoIngest` + `BackgroundIngestCoordinator.scanWiki` fix + exhaustive tests. The chokepoint (`QueueIngestionHelper`) is DEFERRED to PR2.
> **House rules:** never merge to `main`; `DebugLog` not `print`; no bare `try?`; Swift Testing for new tests; scratch to `tmp/` (never `/tmp`).

---

## 1. Problem & root cause

### The bug

`BackgroundIngestCoordinator.scanWiki` enqueues every un-ingested source that passes
`store.canIngest(source)`. But `canIngest` is a **byte check, not a markdown-path check**:

```swift
// Sources/WikiFSCore/Store/WikiStoreModel.swift:2907-2909
public func canIngest(_ source: SourceSummary) -> Bool {
    hasProcessedMarkdown(for: source.id) || source.byteSize > 0
}
```

So a PNG / XML / random binary source with `byteSize > 0` **passes**, gets enqueued by the
continuous scanner, and then either:

- fails at the staging path (`AppQueueIngestionProvider` reads raw bytes but the agent has no
  useful markdown to summarize), or
- gets silently dropped at the `enqueueIngestion` chokepoint
  (`Sources/WikiFS/Queue/QueueIngestionHelper.swift:86-89`) — *if* the source has no markdown
  *and* no bytes. But a byte-bearing PNG sails through that gate too, because `canIngest` is the
  same byte predicate.

Either way the result is wasted agent runs on content that can never produce a useful summary,
and noisy failures. **Continuous ingestion should only auto-ingest sources that have a real path
to markdown: PDF, markdown, HTML, text, podcast transcript, YouTube transcript.**

### Why it's spread out (the reason a registry is the right fix)

The extract-vs-transcribe-vs-ingest eligibility logic is currently scattered across ~8 ad-hoc
sites, each re-deriving "can this content type become markdown?" from raw MIME strings or
provider enums, with no shared decision table. They drift: `canIngest` checks bytes, the Extract
button checks `isPDF || isHTMLSource`, the Transcribe button checks `provider.supportsTranscription`,
and the list's Extract menu checks `MimeType.isPDF` only (it doesn't even offer HTML extraction).
A single registry makes the table explicit and the migration mechanical.

---

## 2. Mapped decision sites (the registry's clients)

| # | Site | File:line | Current logic | What it decides |
|---|------|-----------|---------------|-----------------|
| 1 | **`canIngest`** (the bug) | `Sources/WikiFSCore/Store/WikiStoreModel.swift:2907-2909` | `hasProcessedMarkdown \|\| byteSize > 0` | Whether a source may be ingested at all |
| 2 | **`BackgroundIngestCoordinator.scanWiki`** (the bug) | `Sources/WikiFS/BackgroundIngestCoordinator.swift:85-90` | calls `store.canIngest(source)` | Whether continuous ingest enqueues it |
| 3 | **`enqueueIngestion` chokepoint** | `Sources/WikiFS/Queue/QueueIngestionHelper.swift:62-89` | `isPDF` → enqueue extraction; then `canIngest` gate | PDF-extract-then-ingest + final content gate |
| 4 | **`SourceDetailView.isExtractable`** | `Sources/WikiFS/Sources/SourceDetailView.swift:386` | `isPDF \|\| isHTMLSource` | Show the Extract button |
| 5 | **`SourceDetailView.isTranscribable`** | `Sources/WikiFS/Sources/SourceDetailView.swift:201-230` | `provider.supportsTranscription` + runtime guards | Show the Transcribe button |
| 6 | **`SourceDetailView.needsExtraction`** | `Sources/WikiFS/Sources/SourceDetailView.swift:403` | `isExtractable && !hasMarkdown` | Prominent Extract call-to-action |
| 7 | **`SourceDetailView.needsTranscription`** | `Sources/WikiFS/Sources/SourceDetailView.swift:240` | `isTranscribable && !hasMarkdown` | Prominent Transcribe call-to-action |
| 8 | **`SourcesListView.canExtract`** | `Sources/WikiFS/Sources/SourcesListView.swift:490-493` | `MimeType.isPDF(...) && processedMarkdownHead == nil` | List context-menu Extract item (PDF only — drifts from #4!) |
| 9 | **`SourcesListView.canIngest`** | `Sources/WikiFS/Sources/SourcesListView.swift:500-502` | `store.canIngest(source)` | List context-menu Ingest item |
| 10 | **`SourceProvider.supportsTranscription`** | `Sources/WikiFSTypes/SourceProvider.swift:170-178` | static provider switch (`applePodcast`/`podcast`/`youtube`) | Provider-level transcript capability |
| 11 | **`SourceProvider.supportsRefresh`** | `Sources/WikiFSTypes/SourceProvider.swift:135-144` | static provider switch (`website`/`applePodcast`/`podcast`) | Provider-level re-fetch capability |
| 12 | **`AppQueueIngestionProvider` staging** | `Sources/WikiFS/Queue/AppQueueIngestionProvider.swift:160-168` | `if MimeType.isPDF` reuse extracted head | Read extracted markdown for PDFs at stage time |
| 13 | **`ExtractionCoordinator.current()`** | `Sources/WikiFSEngine/ExtractionCoordinator.swift:67-106` | resolves pdf2md/ACP/Anthropic/Gemini/Docling backend | Which PDF extractor to use |

> **Notably NOT a content-type decision:** `ExtractionCoordinator` (#13) only resolves *which* PDF
> backend — it is backend-agnostic and assumes the caller already knows the source is extractable.
> It stays as-is.

---

## 3. Registry design

### 3.1 Location

**`Sources/WikiFSTypes/ContentTypeRegistry.swift`** — the shared leaf target.

### 3.2 — 3.3 `ContentKind` enum + `resolve` factory

A normalized closed enum of 12 kinds. Provider takes precedence for byteless embeds;
MIME is authoritative for byte-bearing sources.

### 3.4 Capability table

See §5 below (the per-kind extraction/auto-ingest/extraction-path values).

---

## 4. Source content-type availability

`SourceSummary.mimeType` + `SourceSummary.ext` are populated at ingest. The provider
lives on the origin and is fetched via `WikiStoreModel.sourceOrigin(for:) -> SourceOrigin?`,
whose computed `.provider: SourceProvider?` (SourceMaterializer.swift:179) gives the typed enum.

For the bug fix specifically, MIME alone is sufficient to exclude PNG/XML; the coordinator
additionally resolves the provider so byteless `.youtube`/`.podcast` sources with transcripts
still pass.

---

## 5. Migration & capability table

### Capability table (per `ContentKind`)

| ContentKind | MIME / provider source | Extract? | Auto-ingest? | ExtractionPath | Justification |
|---|---|---|---|---|---|
| `pdf` | `application/pdf` | ✅ | ✅ | `.pdfBackend` | pdf2md / ACP / Anthropic / Gemini / Docling |
| `html` | `text/html`, `application/xhtml+xml`, `.html`/`.htm`/`.xhtml` | ✅ | ✅ | `.htmlToMarkdown` | defuddle / tag-based |
| `markdown` | `text/markdown`, `text/x-markdown`, `text/mermaid` | ❌ | ✅ | — | already markdown; native |
| `text` | `text/plain`, `text/csv`, other `text/*` | ❌ | ✅ | — | native text, staged raw (no extraction needed) |
| `podcastTranscript` | provider `.applePodcast` / `.podcast` | ✅ | ✅ | `.podcastTranscript` | TTML / `<podcast:transcript>` pipeline |
| `youtubeTranscript` | provider `.youtube` | ✅ | ✅ | `.youtubeTranscript` | caption-track scrape |
| `image` | `image/png`, `image/jpeg`, etc. | ❌ | ❌ | — | no extractor; bytes present but no markdown path |
| `videoEmbedNoTranscript` | provider `.vimeo` | ❌ | ❌ | — | no caption pipeline today (future: #564) |
| `audioEmbedNoTranscript` | provider `.spotify`, `.soundcloud` | ❌ | ❌ | — | no transcript API |
| `remoteMediaNoMarkdown` | provider `.remoteMedia` (real `audio/mpeg` etc.) | ❌ | ❌ | — | raw stream, no transcript, no markdown |
| `binary` | `application/xml`, `application/json`, `application/zip`, `application/epub+zip`, `octet-stream`, **`text/xml` (operator-decided, §11-C3)**, … | ❌ | ❌ | — | no extractor; the PNG/XML bug class |
| `unknown` | mime nil + provider nil | ❌ | ❌ | — | can't classify — fail safe (no ingest) |

### 5.1 `BackgroundIngestCoordinator.scanWiki` — THE BUG FIX (site #2)

Insert the registry gate (`shouldAutoIngest`) BEFORE the existing byte gate (`canIngest`).
Pass `source.ext` consistently (§11-C4/C9). Use `ContentKind.resolve(mimeType:provider:ext:)`
— NOT `fromMIME` alone, so byteless YouTube/podcast with transcripts still pass.

### 5.2 `WikiStoreModel.shouldAutoIngest(_:)` — new wrapper

Distinct from `canIngest` (which is "is there content to stage?"). `shouldAutoIngest` asks
"is this content TYPE one that has any markdown path?". Used by the coordinator + (in PR2) the
chokepoint. Takes `SourceSummary`, uses `fromMIME` only (no provider) — acceptable since
the caller already filters via the registry directly. **PR2 note:** when the chokepoint is
moved to use `shouldAutoIngest`, do NOT use `fromMIME` alone — use `resolve(mimeType:provider:ext:)`
so YouTube/podcast byteless sources with transcripts aren't dropped (§11-C1).

### 5.3 Extension fallback (§11-C4)

Before returning `.unknown`, consult the lname extension: `.md`/`.markdown` → `.markdown`,
`.html`/`.htm`/`.xhtml` → `.html`, `.pdf` → `.pdf`. This handles legacy/nil-mime markdown sources.

---

## §11. Plan-Review Corrections (AUTHORITATIVE — supersedes conflicting text above)

### C1 [critical] — DEFER the chokepoint change (§5.2) to PR2

`shouldAutoIngest` as defined in §5.2 uses `ContentKind.fromMIME(source.mimeType)` — **no
provider lookup**. For a YouTube source, `fromMIME("video/youtube")` classifies as `.binary`
→ `shouldAutoIngest == false` → the chokepoint guard drops the source, **breaking YouTube/podcast
transcript ingest**.

**For PR1: do NOT touch the chokepoint (`QueueIngestionHelper.swift:86`).** The coordinator fix
(§5.1) already filters PNG/XML at `scanWiki` *before* they reach `enqueueIngestion`.

### C2 [high] — `scanWiki` is private; coordinator tests need a testable seam

Extract the per-source filtering logic into an `internal` function that `scanWiki` calls and
tests can invoke directly via `@testable import`.

### C3 [high] — Resolve the two operator decisions (DECIDED)

1. **`text/xml` AND `application/xml` → `.binary`** (BEFORE the `isText` / `hasPrefix("text/")`
   check). Neither has a markdown extraction path. Add a test asserting both classify as `.binary`
   → `shouldAutoIngest == false`.
2. **Origin-read cost in the 60s scan loop — ACCEPTED.** The `backoffCount` pinning prevents
   re-resolution on subsequent cycles for non-ingestible sources.

### C4 [medium] — Reconcile `shouldAutoIngest` signature: always pass `ext`

Always use `ContentKind.resolve(mimeType: source.mimeType, provider: origin?.provider,
ext: source.ext)` in BOTH the coordinator (§5.1) and any `shouldAutoIngest` wrapper.

### C5 [medium] — Fix the `enqueuesYouTubeEmbed` test description

Seed a transcript via `appendProcessedMarkdown` before the scan — a byteless YouTube WITHOUT
a transcript is correctly skipped by the byteless guard (`canIngest == false`).

### C6 [medium] — Add `text/xml` + `application/xml` → `.binary` exclusion test

Per C3.

### C7 [medium] — Add a chokepoint regression test (for PR2, not PR1)

Deferred.

### C8 [low] — Remove `hasMarkdownPath` from PR1

Vestigial — no caller. Add when a caller actually needs the semantic distinction.

### C9 [low] — Pass `source.ext` in the coordinator resolve call (§5.1)

### Summary of PR1 scope (corrected):
- Content-type registry: `ContentKind` enum + `ContentCapabilities` + `ContentTypeRegistry` in `WikiFSTypes`.
- `fromMIME` + `resolve(mimeType:provider:ext:)` with XML exclusion (C3/C4/C9).
- Fix `BackgroundIngestCoordinator.scanWiki` (§5.1): use the registry to filter, extract
  testable seam (C2), pass ext (C4/C9).
- **Do NOT** touch the chokepoint (C1 — deferred to PR2).
- Tests: exhaustive registry table + coordinator filtering (with testable seam) + XML exclusion (C6).
- No DB migration.

---

## Implementation notes (this PR)

A separate PR2 will migrate the UI decision sites (#4-#8, #12); this PR keeps `canIngest`
unchanged (manual ingest still works) and does not touch the chokepoint (#3, per §11-C1).

The testable seam introduced for `scanWiki`:

```swift
@MainActor
final class BackgroundIngestCoordinator {
    enum IngestionDecision: Equatable, Sendable {
        case enqueue
        case skipNonIngestible(kind: ContentKind)   // PNG/XML/etc — no markdown path
        case skipByteless                          // byteless with no transcript yet
    }

    /// Per-source decision assuming the caller has already handled the
    /// already-ingested pre-filter and backoff. The registry gate runs first
    /// (PNG/XNL/etc.), then the byteless guard (YouTube without transcript).
    internal static func ingestionDecision(
        for source: SourceSummary,
        store: WikiStoreModel
    ) -> IngestionDecision

    /// Convenience batch filter that returns the IDs to enqueue after applying
    /// the registry + byteless gates. Used by `scanWiki` (with backoff handled
    /// around it) and by tests.
    internal static func filterIngestibleSources(
        _ sources: [SourceSummary],
        store: WikiStoreModel
    ) -> [PageID]
}
```

Tests live in `Tests/WikiFSAppTests/BackgroundIngestCoordinatorTests.swift` (the coordinator is
in the `WikiFS` executable target; `@testable import WikiFS` is required).

---

# PR2 — Migrate the UI decision sites + the chokepoint to the registry

> **Scope (PR2):** Consolidate the remaining ad-hoc "can this become markdown?"
> decisions onto the PR1 registry. No new behavior is expected except the
> latent HTML-extraction drift fix in `SourcesListView.canExtract` — the
> list menu now offers HTML extraction (matching the detail-view Extract
> button). The coordinator + registry from PR1 are unchanged.
>
> **Branch:** `content-type-registry-pr2`

## What PR2 touches

The four UI decision sites (§2 #4-#9 + #12) + the deferred chokepoint (#3,
§11-C1). The provider enum (#10) is delegated. Sites #11 (`supportsRefresh`)
and #13 (`ExtractionCoordinator`) stay as-is per §5.7.

### PR2.1 — Registry conveniences (`WikiFSTypes`)

Add two computed booleans on `ContentCapabilities` so call sites express
intent (Extract-button vs Transcribe-button) rather than enumerating paths:

```swift
public extension ContentCapabilities {
    /// `true` when this kind has a non-transcript file-extraction backend
    /// (PDF / HTML). Drives the Extract button (`SourceDetailView
    /// .isExtractable`, `SourcesListView.canExtract`) and the staging reuse
    /// branch (`AppQueueIngestionProvider`). Distinct from
    /// `canExtractToMarkdown` — that one ALSO matches transcript kinds.
    var hasFileExtractionBackend: Bool {
        extractionPath == .pdfBackend || extractionPath == .htmlToMarkdown
    }

    /// `true` when this kind has a transcript extraction path (podcast /
    /// YouTube). Drives the Transcribe button (`SourceDetailView
    /// .isTranscribable`) and `SourceProvider.supportsTranscription`.
    var hasTranscriptBackend: Bool {
        extractionPath == .podcastTranscript || extractionPath == .youtubeTranscript
    }
}
```

**Why these matter (the §5.4 nuance the plan original missed):** the plan's
§5.4 example used `canExtractToMarkdown` for `isExtractable`. That property
is `true` for `.podcastTranscript` / `.youtubeTranscript` too, so a podcast
or YouTube source with no transcript would have BOTH `needsExtraction`
AND `needsTranscription` true — the UI would render two borderedProminent
buttons (Extract + Transcribe). That's a regression on the existing
one-affordance-per-source UX. Using `hasFileExtractionBackend` keeps the
Extract button gated to PDF/HTML only, leaving the Transcribe button to
gate on `hasTranscriptBackend`. The two are mutually exclusive by
construction (a kind's `extractionPath` is one of the four cases or nil).

### PR2.2 — `SourceProvider.supportsTranscription` (#10)

Delegate to the registry — the enum property stays the static baseline the
runtime guard layers on, but the table stops being duplicated:

```swift
public var supportsTranscription: Bool {
    ContentKind.resolve(mimeType: nil, provider: self)
        .capabilities.hasTranscriptBackend
}
```

Behavior identical (the registry's provider switch returns `.podcastTranscript`
for `.applePodcast` / `.podcast` and `.youtubeTranscript` for `.youtube`,
every other provider falls through to MIME / extension resolution which
since the mime is nil returns `.unknown` → `extractionPath == nil`).

### PR2.3 — `SourceDetailView` (#4-#7)

```swift
private var contentKind: ContentKind {
    ContentKind.resolve(mimeType: file.mimeType,
                        provider: origin?.provider,
                        ext: file.ext)
}
private var isExtractable: Bool {
    contentKind.capabilities.hasFileExtractionBackend  // was isPDF || isHTMLSource
}
private var needsExtraction: Bool { isExtractable && !hasMarkdown }   // shape unchanged

private var isTranscribable: Bool {
    guard contentKind.capabilities.hasTranscriptBackend else { return false }
    // existing runtime guards (.applePodcast signing-helper / #if flag,
    // .podcast / .youtube always available) layered on top.
    switch origin?.provider {
    case .applePodcast: return store.isSourceRefreshable(for: file.id)
    case .podcast:      return true
    case .youtube:      return true
    default:            return false
    }
}
```

`isHTMLSource`/`isPDF` stay — they're used by other code paths (the HTML tab
rendering at `:360`, the `htmlSourceString` decoder, the PDF tab gating at
`:352`). The registry gate supersedes them only for the Extract / Transcribe
button decision, not for the tab-dispatch question "which raw-bytes viewer
should I show?".

### PR2.4 — `SourcesListView.canExtract` + `canIngest` (#8, #9)

```swift
private func canExtract(_ source: SourceSummary) -> Bool {
    ContentKind.resolve(mimeType: source.mimeType, provider: nil, ext: source.ext)
        .capabilities.hasFileExtractionBackend      // was MimeType.isPDF only
        && store?.processedMarkdownHead(for: source) == nil
}

private func canIngest(_ source: SourceSummary) -> Bool {
    store?.canIngest(source) == true           // byte gate (unchanged)
        && store?.shouldAutoIngest(source) == true  // content-type gate (NEW)
}
```

**The latent HTML-extract drift fix (§5.5):** the list menu now offers
"Extract Markdown" for both PDF AND HTML sources (previously PDF only).
This was a discovered bug — the detail view offered HTML extraction but the
list context menu silently omitted it.

`canIngest` here switches from the byte-only predicate to the
chokepoint-mirrored pair (byte gate + content-type gate) so the right-click
Ingest item is hidden for non-ingestible byte-bearing sources (PNG/XML) —
consistent with what the PR2 chokepoint does. Comments inside the helper
point at the chokepoint as the authoritative rule and warn against drifting.

### PR2.5 — `QueueIngestionHelper` chokepoint (#3, §5.2 / §11-C1)

```swift
// PDF-without-extracted-head branch: stays as MimeType.isPDF (the queue
// engine is PDF-specific; HTML extraction routes through runHtmlExtraction
// inline, not the extraction queue).
if MimeType.isPDF(source.mimeType),
   store.processedMarkdownHead(for: source) == nil { ... }

// Chokepoint: byte gate (existing) + content-type gate (NEW, provider-aware).
guard store.canIngest(source) else { ... continue }
guard store.shouldAutoIngest(source) else {
    DebugLog.ingest("enqueueIngestion: dropped \(sourceID.rawValue) — content type has no markdown path")
    continue
}
ingestionSourceIDs.append(sourceID)
```

**Provider-aware (§11-C1):** `WikiStoreModel.shouldAutoIngest(_:)` already
resolves via `ContentKind.resolve(mimeType:provider:ext:)` (PR1 made it
provider-aware — see `WikiStoreModel.swift:2965-2972`). A YouTube source
with `mime = video/youtube` and `provider = .youtube` resolves to
`.youtubeTranscript` → `shouldAutoIngest == true`, NOT `.binary`. So a
byteless YouTube WITH a transcript (`canIngest == true` because
`hasProcessedMarkdown == true`) passes both gates. The fromMIME-only
regression the §11-C1 review caught is locked by
`IngestGateTests.shouldAutoIngestKeepsBytelessYouTube` (PR1).

### PR2.6 — `AppQueueIngestionProvider` staging (#12, §5.6)

```swift
let kind = ContentKind.resolve(mimeType: source.mimeType,
                                provider: nil,         // byte-bearing MIME is authoritative
                                ext: source.ext)
if kind.capabilities.hasFileExtractionBackend,              // was MimeType.isPDF only
   let head = store.processedMarkdownHead(for: source) {
    sourceBytes = head.content.data(using: .utf8) ?? bytes
    sourceExt = "md"
    DebugLog.extraction("AppQueueIngestionProvider: reusing markdown for \(source.filename)")
}
```

**Behavior widening (intentional):** HTML sources now reuse their extracted
markdown the same way PDFs do. A byteless YouTube-with-transcript doesn't
hit this branch (it has bytes from `store.sourceBytes` already, since
`canIngest` is true via `hasProcessedMarkdown` — wait, no, the staging
loops over `sourceIDs` and reads `store.sourceBytes(id:)`, which for a
byteless source... (verify behavior — see Tests section). Either way, the
`hasFileExtractionBackend` filter excludes the transcript kinds, so the
branch runs only for PDF/HTML — same as PDF-only before, plus HTML now.

## PR2 tests

### Existing tests (PR1) that act as guard rails

- `ContentTypeRegistryTests` (40 tests) — the closed table.
- `IngestGateTests.shouldAutoIngestKeepsBytelessYouTube` (PR1) — locks the
  provider-aware wrapper that the PR2 chokepoint relies on.
- `IngestGateTests.chokepointDropsBytelessYouTubeFromIngestionQueue` — pins
  the byteless-no-transcript drop (still applies post-PR2; the new
  `shouldAutoIngest` gate is also `false`-equivalent there because
  `canIngest == false` first).

### PR2 additions

1. **Registry conveniences** (`Tests/WikiFSTests/ContentTypeRegistryTests.swift`):
   `hasFileExtractionBackend` true for pdf/html only; `hasTranscriptBackend`
   true for podcastTranscript/youtubeTranscript only; mutually exclusive.

2. **`SourceProvider.supportsTranscription` delegation** (new test file or
   extension of an existing provider-test file): assert the property
   matches the registry's `hasTranscriptBackend` for every provider case
   (an exhaustive switch — pins the delegation against drift).

3. **`SourceDetailView` Extract/Transcribe gating** (new test file
   `Tests/WikiFSAppTests/SourceDetailViewContentKindTests.swift` or
   similar — the view can't be hosted directly, so test the `contentKind`
   resolution + the gating predicates via `@testable import WikiFS`):
   - PDF → `isExtractable == true`, `isTranscribable == false`.
   - HTML → `isExtractable == true`, `isTranscribable == false` (the
     drift fix).
   - Podcast (provider `.applePodcast`) → `isTranscribable == ?` (runtime
     guard; assert the registry-side `hasTranscriptBackend == true` and
     that `hasFileExtractionBackend == false`).
   - YouTube (provider `.youtube`) → same.
   - PNG → both `false`.
   - Markdown → both `false` (already the content).
   - Exclusivity invariant: no kind has both true.

   > **Implementation note:** the predicates are `private` in the view. Two
   > options: (a) extract the decision into an `internal static` helper on
   > the view (or a free function) that the tests invoke directly (mirrors
   > the PR1 `ingestionDecision` seam in `BackgroundIngestCoordinator`); (b)
   > replicate the same `resolve(...)` calls in the test (less faithful but
   > still pins the registry integration). Prefer (a) — the seam pays off
   > if the gating logic moves again.

4. **`SourcesListView.canExtract` + `canIngest`** (new test file
   `Tests/WikiFSAppTests/SourcesListViewContentKindTests.swift`): the list
   view's helpers are `private` — same seam dilemma. Mirror the (a)
   approach: extract `SourcesListContentGates` as `internal` helpers so the
   tests exercise the real predicate.
   - `canExtract` returns true for PDF AND HTML (the latent bug fix).
   - `canIngest` returns false for a byte-bearing PNG (was true pre-PR2).

5. **Chokepoint regression (§11-C7):** in `IngestGateTests` — add
   `chokepointKeepsBytelessYouTubeWithTranscript`. A YouTube source with a
   seeded transcript must end up in the ingestion queue (not dropped by the
   new `shouldAutoIngest` gate). This is the C7 test the §11 plan asks for.

6. **`AppQueueIngestionProvider` staging**: if there's an existing staging
   test, extend it to assert HTML sources reuse their extracted head
   (mirroring PDFs); if not, add a narrow test that drives
   `OperationRequest.StagedSource` for an HTML source with extracted head
   and asserts `ext == "md"` + bytes == head content. If the staging
   surface is too coupled to test, fall back to a unit test on the
   content-type decision (`kind.capabilities.hasFileExtractionBackend ==
   true` for HTML) + reference the staging code by file:line.

## PR2 file touch-list

| File | Change |
|------|--------|
| `Sources/WikiFSTypes/ContentTypeRegistry.swift` | add `hasFileExtractionBackend` / `hasTranscriptBackend` (`extension ContentCapabilities`) |
| `Sources/WikiFSTypes/SourceProvider.swift` | `supportsTranscription` delegates to registry |
| `Sources/WikiFS/Sources/SourceDetailView.swift` | `isExtractable` / `isTranscribable` / `needsExtraction` / `needsTranscription` via `contentKind` + registry |
| `Sources/WikiFS/Sources/SourcesListView.swift` | `canExtract` / `canIngest` via registry (HTML drift fix) |
| `Sources/WikiFS/Queue/QueueIngestionHelper.swift` | chokepoint: add `store.shouldAutoIngest(source)` guard (provider-aware via PR1 wrapper) |
| `Sources/WikiFS/Queue/AppQueueIngestionProvider.swift` | staging: `hasFileExtractionBackend` reuse (generalize `isPDF` to PDF+HTML) |
| `Tests/WikiFSTests/ContentTypeRegistryTests.swift` | convenience-property tests |
| `Tests/WikiFSAppTests/SourceDetailViewContentKindTests.swift` (NEW) | gating predicate tests |
| `Tests/WikiFSAppTests/SourcesListViewContentKindTests.swift` (NEW) | gating predicate tests |
| `Tests/WikiFSAppTests/IngestGateTests.swift` | extend with `chokepointKeepsBytelessYouTubeWithTranscript` (C7) |
| `Tests/WikiFSAppTests/SourceProviderSupportsTranscriptionTests.swift` (NEW) | delegation regression (provider × registry) |

No DB migration. No new dependencies.
