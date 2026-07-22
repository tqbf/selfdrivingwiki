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
