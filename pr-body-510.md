Fixes #510.

## Summary

Add a typed `MimeType` namespace (`ContentSniff.swift`) with canonical constants and case-insensitive predicates, then replace **all** inline raw-string MIME comparisons, prefix checks, `application/octet-stream` fallbacks, and MIME-switch labels across the codebase with typed lookups.

This prevents a typo like `"application/pdf "` (trailing space) or `"Application/PDF"` (wrong casing) from silently mis-guarding — every call site now routes through a single source of truth.

## What changed

### New `MimeType` namespace (`Sources/WikiFSCore/ContentSniff.swift`)

An enum alongside the existing `ContentSniff` sniffer, exposing:

- **Constants:** `pdf`, `octetStream`, `markdown`, `markdownX`, `html`, `xhtml`, `imageJPEG`, `videoYouTube`
- **Sets/prefix:** `textPrefix`, `markdownVariants` (Set)
- **Predicates:** `isPDF(_:)`, `isText(_:)`, `isMarkdown(_:)` — all case-insensitive per RFC 2045, `nil`-safe

### Consumer sweep (20 files)

| Pattern | Before | After | Sites |
|---|---|---|---|
| `"application/pdf"` equality | `mime == "application/pdf"` | `MimeType.isPDF(mime)` | 13 |
| `hasPrefix("text/")` | `mime.hasPrefix("text/")` | `MimeType.isText(mime)` | 8 |
| `"application/octet-stream"` fallback | `?? "application/octet-stream"` / `return ...` | `?? MimeType.octetStream` / `return MimeType.octetStream` | 4 |
| Markdown variant check | `mime == "text/markdown" \|\| mime == "text/x-markdown"` | `MimeType.isMarkdown(mime)` | 2 |
| `text/markdown` value/default-param | `mimeType: "text/markdown"` | `mimeType: MimeType.markdown` | 6 |
| `video/youtube` switch label | `case "video/youtube"` | `case MimeType.videoYouTube` | 1 |
| `image/jpeg` switch label | `case "image/jpeg"` | `case MimeType.imageJPEG` | 1 |
| `"application/pdf"` API payload value | `"media_type": "application/pdf"` | `"media_type": MimeType.pdf` | 2 |
| `text/html` / `application/xhtml+xml` switch labels | `case "text/html", "application/xhtml+xml"` | `case MimeType.html, MimeType.xhtml` | 2 |

Files touched:
- `ContentSniff.swift` (new namespace + magic-byte returns unchanged — canonical source)
- `FormatMaterializer.swift` (7 replacements: predicates, switch labels, shouldSniff)
- `Projection.swift` (4: 3x isText + markdown value)
- `SourcesListView.swift`, `SourceDetailView.swift`, `BlobSchemeHandler.swift`
- `WikiStoreModel.swift`, `EditorTab.swift`, `DisplayNameResolver.swift`, `WikiLinkMarkdown.swift`, `ZoteroClient.swift`, `ExternalEmbed.swift`, `GeminiExtractionClient.swift`, `AnthropicExtractionClient.swift`, `WebsiteSnapshotExtractor.swift`, `SourceMarkdownVersion.swift`, `SourceMaterializer.swift`, `SQLiteWikiStore.swift`, `AppQueueIngestionProvider.swift`, `QueueIngestionHelper.swift`

## Design notes

- **Case-insensitive matching:** all predicates lowercase before comparing, per RFC 2045. Stored types are already lowercase (`ContentSniff` and `FormatMaterializer.normalizedMIME` both lowercase), but accepting any casing makes the predicates correct for raw `Content-Type` headers that bypass normalization.
- **nil-safe:** `isPDF(nil)` / `isText(nil)` / `isMarkdown(nil)` return `false`, eliminating several `guard let mime = ...` bindings that existed only to call `hasPrefix`.
- **Magic-byte returns in `ContentSniff` left as literals** — the sniffer is the canonical source producing these strings; `MimeType.pdf` resolves to the same literal. Keeping the producer returns as bare strings is correct (they define the value), while all consumers now reference the constant.
- **No behavior change** — every replacement is semantically equivalent to the original, just routed through the typed namespace.

## Verification

```
swift build  # Build complete
swift test --skip '<fast tier>'  # 2456 tests passed in 211 suites
```
