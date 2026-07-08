# Source format materializers — two-level dispatch

**Issue #263.** Separates *what a source produces* (format: HTML→Markdown, PDF
verbatim, text, binary) from *where the bytes came from* (origin: URL, local
file, Zotero, folder).

## Problem

The format-dispatch logic lived hidden inside `URLFetchService.plan(for:)` — a
URL-centric method whose input was `FetchResponse(data, contentType, finalURL)`
and whose output was `StorePlan(filename, data, kind)`. Filenames derived from
`finalURL`.

`ZoteroMaterializer` **bypassed** this dispatch entirely: it read raw bytes,
stored them with `mimeType: nil`, and used the original filename verbatim. A
Zotero HTML attachment was stored as raw HTML instead of converted Markdown — a
latent bug.

New origins (#261: git, Tavily, Slack) would face the same problem: either
duplicate the dispatch logic or awkwardly build a synthetic `FetchResponse` to
call the URL-shaped `plan(for:)`.

## Solution — two-level dispatch

### Level 1: `FormatMaterializer` (format layer)

A pure, URL-independent dispatcher
(`Sources/WikiFSCore/FormatMaterializer.swift`):

```swift
public enum FormatMaterializer {
    public static func dispatch(
        data: Data, contentType: String?,
        stem: String, extensionHint: String?
    ) -> FormatPlan
}
```

- **`stem`** — the pre-computed filename stem (extension already deleted by the
  caller). For URL origins: the last path component without its extension, or
  the host for root URLs (e.g. `"example.com"` — NOT with `.com` stripped). For
  Zotero/local-file: `deletingPathExtension` of the filename.
- **`extensionHint`** — the original file/URL extension (lowercased, without the
  dot), or `nil`. Used as the fallback for non-mapped text/binary MIMEs (e.g.
  `text/yaml` → `extensionHint: "yaml"` → filename `notes.yaml`).

The dispatch body is the old `plan(for:)` with URL references replaced by the
`stem` + `extensionHint` pair. The `(stem, extensionHint)` split avoids the
host/TLD confusion a single `nameHint` string would cause: `"example.com"` would
lose `.com` under naive `deletingPathExtension`.

**Types:**
- `SourceFormat` — the format-layer enum: `.htmlConverted`, `.pdf`, `.text`,
  `.binary`. A subset of `FetchOutcome.Kind` (which also has byteless kinds).
- `FormatPlan` — `(filename, data, format)`. Pure, no URL/store/network
  dependency.

### Level 2: `SourceMaterializer` conformers (origin layer)

Origin types acquire bytes + build `SourceProvenance`, then delegate to
`FormatMaterializer.dispatch`:

| Conformer | Origin | Format dispatch |
|---|---|---|
| `WebsiteMaterializer` | URL (fetch) | `nameHint(for:)` → dispatch |
| `LocalFileMaterializer` | Local file (drag-drop) | `nameHint(for:)` → dispatch |
| `ZoteroMaterializer` | Zotero attachment | filename → `(stem, ext)` → dispatch |
| `MarkdownFolderMaterializer` | Folder `.md` | bypass (already Markdown) |
| `ApplePodcastMaterializer` | Podcast transcript | bypass (byteless → derived alt) |

Byteless sources (podcasts, embeds) have **no bytes and no format dispatch** —
they're pure provenance pointers. Including them in the format layer would be a
category error.

## Decisions

### Single dispatcher vs. separate format types

The issue's proposal names individual format materializer types
(`PdfMaterializer`, `MarkdownMaterializer`). But the dispatch is a simple
content-type switch with one non-trivial arm (HTML→Markdown; the rest are
verbatim). A single `FormatMaterializer.dispatch` is cleaner and matches the
existing `plan(for:)` shape. If format-specific logic grows (e.g. richer PDF
processing), individual format strategies can be extracted behind the same
dispatch seam later — the one-type-now approach doesn't foreclose that.

### Zotero behavior change (intentional bugfix)

After the refactor, `ZoteroMaterializer` routes through
`FormatMaterializer.dispatch`:

- A Zotero **HTML** attachment converts to Markdown (like a website would).
  Today it's stored as raw HTML — a latent bug. **Fixed.**
- A Zotero **PDF** gets `.pdf` extension inference + content sniffing. Today it
  stores whatever extension the attachment had.
- Binary/text attachments: unchanged (verbatim, same as today).

The Zotero **display name** resolution (`DisplayNameResolver` uses
`zoteroItemTitle` first) is unaffected — it runs in
`WikiStoreModel.preResolveDisplayName`, separately from format dispatch.

### contentType policy

Format dispatch trusts the declared contentType for specific types
(`application/pdf`, `text/html`) and sniffs for ambiguous ones (`nil`,
`text/html`, `application/octet-stream`) — identical to website sources. Zotero
contentType metadata is typically accurate.

## How a new origin would use the seam (#261)

```swift
public struct GitFileMaterializer: SourceMaterializer {
    public let agentName = "git"
    // ... acquire bytes from a git blob ...
    public func materialize() async throws -> MaterializedSource {
        let stem = ... // filename without extension
        let extHint = ... // extension, lowercased
        let plan = FormatMaterializer.dispatch(
            data: bytes, contentType: contentType,
            stem: stem, extensionHint: extHint)
        return MaterializedSource(
            filename: plan.filename, data: plan.data,
            provenance: SourceProvenance(agentName: agentName, ...))
    }
}
```

No `FetchResponse`, no `URLFetchService.plan(for:)`, no URL coupling.

## Bridge to `FetchOutcome.Kind`

`URLFetchService.plan(for:)` remains the URL→format bridge: it extracts
`(stem, extHint)` via `nameHint(for:)`, calls `FormatMaterializer.dispatch`, and
maps `SourceFormat` → `FetchOutcome.Kind` via `mapFormat(_:)`. Thin forwarders on
`URLFetchService` delegate to `FormatMaterializer` for every moved helper, so
existing consumers and tests compile unchanged.

## Test coverage

- `FormatMaterializerTests` (20 tests) — pure dispatch: HTML→Markdown, PDF/text/
  binary verbatim, content-sniffing, extension fallbacks, root-URL host case, and
  the AC.7 source-grep check (no `FetchResponse`/`StorePlan`/`: URL` dependency).
- `URLFetchServiceTests` — existing tests pass unchanged (forwarders preserve
  behavior).
- `SourceMaterializerTests` — Zotero PDF test strengthened (asserts filename +
  bytes); new Zotero HTML→Markdown test (AC.3).
- `WikiStoreModelZoteroIngestTests` — `attachment(key:filename:)` helper gains a
  `contentType:` parameter; `notes.md` fixture gets `text/markdown`.
