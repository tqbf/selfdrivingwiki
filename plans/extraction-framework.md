# Plan: General Extraction Framework — No Auto-Extraction (#799)

## Vision

Every content type that needs extraction (HTML, PDF, Podcast) follows the same
lifecycle: **raw bytes/content stored at ingest, NO automatic extraction, user
explicitly chooses a backend and triggers extraction**, re-extract with a
different backend at any time.

PDF already works this way. HTML and Podcast currently auto-extract at ingest
with no user choice. This plan brings them to parity — staged across 4 PRs.

## Phasing (per plan-reviewer recommendation)

This is too large for one PR. The staged approach ensures no intermediate state
leaves HTML sources with no readable content:

| PR | Scope | Risk | Ships independently? |
|----|-------|------|---------------------|
| **PR1** | Config + backend enums + Settings UI | Low — additive, no behavior change | Yes |
| **PR2** | Generalize Extract/Re-extract UI for HTML | Medium — new extraction trigger, inline (not queue) | Yes (after PR1) |
| **PR3** | Remove HTML auto-extraction at ingest | Medium — behavioral change, must land after PR2 | No — after PR2 |
| **PR4** | Podcast framework | High — different protocol, network fetch, `#if PODCAST_TRANSCRIPTS` | Independent |

---

## PR1: Config + Backend Enums + Settings UI

**Goal:** Add the typed backend enums and Settings pickers. No behavior change —
extraction still auto-runs at ingest with the current method. This is pure
scaffolding that PR2/PR3 build on.

### New types

`Sources/WikiFSMarkdown/HtmlExtractionBackend.swift`:
```swift
public enum HtmlExtractionBackend: String, CaseIterable, Codable, Sendable {
    case defuddle
    case tagBased
    var displayName: String { ... }
}
```

`Sources/WikiFSCore/Integrations/PodcastTranscriptionBackend.swift`:
```swift
public enum PodcastTranscriptionBackend: String, CaseIterable, Codable, Sendable {
    case appleTranscript
    var displayName: String { ... }
}
```

### Extend ExtractionConfig

`Sources/WikiFSCore/Integrations/ExtractionConfig.swift` — add two optional fields.

**Critical:** ExtractionConfig has hand-written Codable (`CodingKeys` at `:93`,
`init(from:)` at `:100`, memberwise `init(...)` at `:47`). Must edit ALL THREE:
```swift
public var htmlBackend: HtmlExtractionBackend?     // nil = no default yet
public var podcastBackend: PodcastTranscriptionBackend?

// CodingKeys: add case htmlBackend, case podcastBackend
// init(from:): try decodeIfPresent for both
// init(...): add both parameters with nil defaults
```

Note the asymmetry: the existing PDF `backend` is non-optional (defaults to
`.localPdf2md`). HTML/Podcast are optional (nil = prompt user to choose). This
is intentional — PDF has a sensible always-available fallback; HTML/Podcast may
not (defuddle binary missing, podcast helper absent).

### Settings UI

`Sources/WikiFS/Sources/ExtractionSettingsView.swift` — add HTML + Podcast
picker sections below the existing PDF picker. Each is a `Picker` bound to the
config draft, auto-saves on change.

### Acceptance criteria (PR1)

- **AC.1**: `ExtractionConfig` round-trips all three backend fields (PDF, HTML, Podcast).
- **AC.2**: Legacy config files without the new fields decode to nil (prompt to choose).
- **AC.3**: `ExtractionSettingsView` renders three backend pickers.
- **AC.4**: No behavior change — existing auto-extraction still runs at ingest.

### Files touched (PR1)
- **New:** `Sources/WikiFSMarkdown/HtmlExtractionBackend.swift`, `Sources/WikiFSCore/Integrations/PodcastTranscriptionBackend.swift`
- **Edit:** `Sources/WikiFSCore/Integrations/ExtractionConfig.swift` (CodingKeys + init(from:) + memberwise init), `Sources/WikiFS/Sources/ExtractionSettingsView.swift`
- **Tests:** `Tests/WikiFSTests/ExtractionConfigTests.swift` (extend), `Tests/WikiFSTests/HtmlExtractionBackendTests.swift` (new)

---

## PR2: HTML Extraction Trigger (Generalize Extract/Re-extract UI)

**Goal:** Add the "Extract" button and "Re-extract with" menu for HTML sources,
using the **existing inline extraction path** (not the queue engine). This must
ship BEFORE removing auto-extraction (PR3), so users always have a way to
extract.

### Wrap HTMLToMarkdown in an HtmlMarkdownExtractor conformer

`Sources/WikiFSMarkdown/HTMLToMarkdown.swift` — add:
```swift
public struct TagBasedHtmlExtractor: HtmlMarkdownExtractor {
    public func extract(html: String) async -> HtmlExtractionResult? {
        HtmlExtractionResult(markdown: HTMLToMarkdown.convert(html), ...)
    }
}
```

### Generalize SourceDetailView predicates

Currently PDF-only. Concrete changes:
- `needsExtraction` (`:300`): change from `isPDF && !hasMarkdown` to
  `isExtractable && !hasMarkdown` where `isExtractable` = content type has
  extraction backends (HTML + PDF).
- Extract button (`:662`): show when `needsExtraction` (now covers HTML).
- `extractionProvenanceChip` (`:659`): generalize gate from `if isPDF, hasMarkdown`
  to `if isExtractable, hasMarkdown`.
- Re-extract menu (`:1387`): currently iterates `ExtractionBackend.allCases`
  (PDF-only). Make it content-type-aware: HTML sources list
  `HtmlExtractionBackend.allCases`, PDF sources list `ExtractionBackend.allCases`.

### HTML extraction trigger (inline, NOT through queue)

The queue engine is deeply PDF-coupled (`ExtractionResolution.pdfData`,
`convert(pdfData:)`, `seedPdfMarkdown`) — generalizing it is a separate
sub-project (deferred). Instead, HTML extraction uses the existing inline path:

- Add `WikiStoreModel.extractHtml(sourceID:backend:)` — reads the source's HTML
  bytes from the store, runs the chosen extractor (defuddle or
  `TagBasedHtmlExtractor`), writes the result via `appendProcessedMarkdown`
  (same write path as the current `enrichWithDefuddle`).
- Re-extract appends a coexisting alternative (does not clobber), same as PDF's
  `runReExtraction`.
- The backend is resolved from `ExtractionConfig.htmlBackend` (set in PR1), or
  the user picks from the menu.

**Config wiring:** `WikiStoreModel` is deliberately NOT config-aware (config is
read by `ExtractionCoordinator` in WikiFSEngine). Inject the chosen HTML backend
into `WikiStoreModel` as a new `@ObservationIgnored var htmlBackend` (mirroring
the existing `htmlMarkdownExtractor` injection at `:318`), resolved at app wiring
time from `ExtractionConfig`.

### Acceptance criteria (PR2)

- **AC.5**: "Extract" button appears on an HTML source with no markdown. Clicking
  it with defuddle creates a markdown version (technique "defuddle").
- **AC.6**: "Extract" with tag-based creates a markdown version (technique
  "html-to-markdown").
- **AC.7**: "Re-extract with" on an HTML source creates a coexisting alternative.
  The provenance chip shows both versions.
- **AC.8**: Existing auto-extraction at ingest still runs (PR3 hasn't landed yet).

### Files touched (PR2)
- **Edit:** `Sources/WikiFSMarkdown/HTMLToMarkdown.swift` (conformer), `Sources/WikiFS/Sources/SourceDetailView.swift` (predicates + menus), `Sources/WikiFSCore/Store/WikiStoreModel.swift` (extractHtml method + htmlBackend injection), `Sources/WikiFSEngine/WikiSession.swift` or `SessionManager.swift` (wire htmlBackend from config)
- **Tests:** WikiStoreModel integration tests for extractHtml + re-extract

---

## PR3: Remove HTML Auto-Extraction at Ingest

**Goal:** Stop auto-extracting markdown at ingest time. HTML sources store raw
bytes only; the user triggers extraction via the button added in PR2.

### Remove enrichWithDefuddle calls

**THREE callers** (confirmed by plan-reviewer):
1. `addFiles` (`WikiStoreModel.swift:2040`)
2. `addURLViaWebsite` — no-images branch (`WikiStoreModel.swift:2450`)
3. `ingestFromZotero` (`WikiStoreModel.swift:2633`)

All three: remove the `enrichWithDefuddle` call. Store raw HTML bytes only.

### Website snapshots with images — SEPARATE path (plan-reviewer finding)

**Critical:** `addURLViaWebsite` has a **fourth** auto-extract path at `:2461`
(`storeSnapshot`) that the first plan draft missed. When a website has images,
`WebsiteSnapshotExtractor` computes markdown with image-src rewriting and stores
it as a `.extraction`-origin version via `appendExtractedMarkdown` at `:2525`.

**Decision needed:** does "no auto-extraction" apply to image-bearing snapshots?
- **If yes**: the reader shows raw HTML with broken image refs until the user
  extracts. Image-src rewriting is inseparable from extraction — the user can't
  get working images without extraction. This is a significant UX regression.
- **If no**: image snapshots keep auto-extraction (it's inseparable from the
  image handling). AC must say "non-snapshot HTML" and the scope boundary must
  be explicit. **Recommended** — snapshot extraction is a different operation
  (image handling, not article extraction).

### FormatMaterializer.dispatch change

`FormatMaterializer.dispatch` (`:123`) currently ALWAYS computes tag-based
markdown for HTML. After PR3, skip the `HTMLToMarkdown.convert` call at ingest
time — store the raw HTML format without the `extractedMarkdown` sidecar. The
format detection (`.html`) still runs so the source is tagged correctly.

### Downstream impacts (plan-reviewer finding — must document)

Removing auto-extraction means HTML sources arrive with NO processed markdown:
1. **Search** (Tantivy): indexes title-only, body unsearchable until extracted. Not broken, degraded.
2. **File Provider .md sibling**: no `.md` projected — source appears as raw `.html` in Finder. Visible behavior change.
3. **Reader view**: falls back to raw HTML rendering (HTML tab). No markdown until extracted.
4. **Agent ingestion**: agent gets raw HTML bytes (not extracted markdown). May degrade agent quality.

Each is acceptable given the user's explicit "no automatic extraction" directive,
but must be documented as known trade-offs.

### Acceptance criteria (PR3)

- **AC.9**: Ingesting a URL (no images) stores raw HTML with NO markdown sidecar.
- **AC.10**: Ingesting an HTML file from a folder stores raw HTML with NO markdown sidecar.
- **AC.11**: Ingesting a Zotero HTML attachment stores raw HTML with NO markdown sidecar.
- **AC.12**: Website snapshots with images still auto-extract (scope boundary — extraction is inseparable from image handling). OR: snapshots also defer (if operator chooses the UX regression).
- **AC.13**: The "Extract" button (from PR2) works on these un-extracted sources.

### Files touched (PR3)
- **Edit:** `Sources/WikiFSCore/Store/WikiStoreModel.swift` (remove 3 enrichWithDefuddle calls), `Sources/WikiFSCore/Sources/FormatMaterializer.swift` (skip markdown computation at ingest)
- **Tests:** Integration tests asserting no markdown version after ingest

---

## PR4: Podcast Framework

**Goal:** Stop auto-transcribing at ingest. Store podcast as byteless embed.
User clicks "Transcribe" to trigger transcription.

### Architectural difference (plan-reviewer finding)

Podcast transcription is **fundamentally different** from PDF/HTML extraction:
- **Not bytes→markdown**: the transcript comes from Apple's network API (signed
  bearer token → AMP metadata → TTML download → parse). There are no stored bytes.
- **Queue engine incompatibility**: the queue reads `store.sourceBytes(id:)` and
  calls `convert(pdfData:)`. For a byteless podcast, `sourceBytes` returns empty.
  The podcast trigger must be a **separate code path**, not through the queue.
- **Behind `#if PODCAST_TRANSCRIPTS`**: the signing helper may not be present.
  The Transcribe button must be disabled when the helper is unavailable.

### Design

- **Ingest change**: `WikiStoreModel.addURL` podcast path (`:2127`) currently
  calls `ApplePodcastTranscriptService.transcript(for:)` → stores transcript.
  Change to: store as byteless embed source (like YouTube/video embeds), NO
  transcript. The podcast URL → `EmbedTarget` → embed source.
- **Transcribe trigger**: new `WikiStoreModel.transcribePodcast(sourceID:)` —
  reconstructs the episode URL from provenance (`externalIdentity`), re-injects
  `PodcastTranscriptFetching`, calls `transcript(for:)`, stores via
  `appendProcessedMarkdown`. NOT through the queue engine.
- **UI**: `SourceDetailView` shows a "Transcribe" button on podcast sources with
  no transcript. Disabled when `#if !PODCAST_TRANSCRIPTS` or helper unavailable.
  Backend picker shows `PodcastTranscriptionBackend.allCases` (currently just
  `appleTranscript`; extensible to Whisper etc. in future PRs).

### Acceptance criteria (PR4)

- **AC.14**: Ingesting a podcast URL stores the embed with NO transcript.
- **AC.15**: "Transcribe" button triggers `PodcastTranscriptFetching` and creates
  a transcript version.
- **AC.16**: "Transcribe" is disabled when the signing helper is unavailable.

### Files touched (PR4)
- **Edit:** `Sources/WikiFSCore/Store/WikiStoreModel.swift` (podcast ingest → embed-only, transcribePodcast method), `Sources/WikiFS/Sources/SourceDetailView.swift` (Transcribe button), `Sources/WikiFSEngine/SessionManager.swift` (podcast fetcher injection for re-transcription)

---

## Out of scope

- **Queue engine generalization** — the PDF-coupled queue (`ExtractionResolution.pdfData`,
  `convert(pdfData:)`, `seedPdfMarkdown`) stays PDF-only. HTML uses inline extraction,
  podcast uses a direct trigger. Unifying the queue is a future sub-project.
- **New podcast backends** (Whisper, Rev.ai) — PR4 adds the framework + Apple backend.
  New backends are follow-ups.
- **Unifying the three extraction protocols** (`MarkdownExtractor`, `HtmlMarkdownExtractor`,
  `PodcastTranscriptFetching`) — they have fundamentally different input types.
- **Migrating existing auto-extracted sources** — their markdown versions persist.
  Only new ingests change.

## Build & test

```bash
make prompts && swift build
swift test
```
