# Plan: SourceProvider Enum — Typed Source Origin Taxonomy

## Summary

Replace the raw convention strings ("website", "zotero", "local-file",
"markdown-folder", "apple-podcast", "youtube", etc.) used as `agentName` values
for source provenance with a typed `SourceProvider` enum. Centralize display
labels, SF Symbols, refreshability, and help text as enum-carried properties.
Collapse label disagreements across switch sites.

**No DB migration** — `agents.name` values are byte-identical; the enum's
`rawValue` matches today's strings exactly.

## Problem

The source-provider string convention is enforced by string discipline in 5
materializers + 2 byteless-media sites, and parsed by 4 hardcoded switch
statements + 2 equality checks across 3 files. Nothing prevents drift. Two
switch sites **disagree** on labels ("Folder" vs "Markdown folder", "Youtube" vs
"YouTube", "Soundcloud" vs "SoundCloud"). This is the same pattern PageAuthor
fixed for page-version authors (PR #798).

## Design

### New: `Sources/WikiFSTypes/SourceProvider.swift`

```swift
/// Typed taxonomy for source origin — the `agents.name` value stamped by each
/// materializer and projected from the PROV graph. Single source of truth for
/// the convention strings. rawValue matches today's literals for DB back-compat.
public enum SourceProvider: String, CaseIterable, Equatable, Hashable, Sendable {
    case localFile       = "local-file"
    case website         = "website"
    case zotero          = "zotero"
    case markdownFolder  = "markdown-folder"
    case applePodcast    = "apple-podcast"
    case youtube         = "youtube"
    case vimeo           = "vimeo"
    case spotify         = "spotify"
    case soundcloud      = "soundcloud"
    case remoteMedia     = "remote-media"
    case legacyImport    = "legacy-import"

    /// Parse a stored `agents.name` value. Unknown/test values → nil.
    public init?(rawValue: String?) {
        guard let rawValue, !rawValue.isEmpty else { return nil }
        self.init(rawValue: rawValue)
    }

    /// Display label for the origin chip. Canonical — replaces disagreements.
    public var displayLabel: String { ... }     // "File", "Website", "Folder", etc.

    /// SF Symbol for the origin chip.
    public var systemImage: String { ... }       // "doc", "globe", "folder", etc.

    /// Help-text verb for the origin chip's tooltip/click action.
    public var helpVerb: String { ... }          // "Reveal original file", "Open original", etc.

    /// Baseline refresh capability (website + applePodcast support re-fetch in
    /// principle). This is NOT the full refreshability predicate — runtime checks
    /// (hasImageSiblings for websites, bundled helper for podcasts) gate on top.
    public var supportsRefresh: Bool { ... }      // true for website, applePodcast
}
```

**Label disagreements resolved** (enum carries ONE canonical value):

| Provider | displayLabel | systemImage | Resolution |
|----------|-------------|-------------|------------|
| `markdownFolder` | "Folder" | `folder` | Use "Folder" (matches DetailView UI; "Markdown folder" too verbose for chip) |
| `youtube` | "YouTube" | `play.rectangle` | Proper brand casing |
| `soundcloud` | "SoundCloud" | `waveform` | Proper brand casing |

### Route construction sites (write path)

| Site | File | Change |
|------|------|--------|
| `LocalFileMaterializer.agentName` | `SourceMaterializer.swift:194` | `SourceProvider.localFile.rawValue` |
| `WebsiteMaterializer.agentName` | `SourceMaterializer.swift:246` | `SourceProvider.website.rawValue` |
| `ApplePodcastMaterializer.agentName` | `SourceMaterializer.swift:402` | `SourceProvider.applePodcast.rawValue` |
| `ZoteroMaterializer.agentName` | `SourceMaterializer.swift:449` | `SourceProvider.zotero.rawValue` |
| `MarkdownFolderMaterializer.agentName` | `SourceMaterializer.swift:506` | `SourceProvider.markdownFolder.rawValue` |
| `bytelessMediaOutcome` | `WikiStoreModel.swift:2229` | `match.provider.rawValue` |
| YouTube-with-transcript | `WikiStoreModel.swift:2296` | `match.provider.rawValue` |
| `MediaEmbedMatch` literals | `MediaEmbedURL.swift:83,104,127,148,170` | `SourceProvider.youtube.rawValue` etc. |

The materializer protocol `var agentName: String` (`SourceMaterializer.swift:120`)
stays `String` (the rawValue) — or optionally becomes `var provider: SourceProvider`.
Recommend keeping `String` to minimize the diff; the materializer just returns
the enum's rawValue.

### Route parse/display sites (read path)

| Site | File | Change |
|------|------|--------|
| `SourceOrigin.displayLabel` switch | `SourceMaterializer.swift:175` | `provider.displayLabel` — delete the switch |
| `SourceRefreshService` switch | `SourceRefreshService.swift:84` | `switch provider` — exhaustive, no default |
| `WikiStoreModel.isSourceRefreshable` switch | `WikiStoreModel.swift:2834` | `provider.isRefreshable` + podcast helper check |
| `SourceDetailView.providerOriginTag` switch | `SourceDetailView.swift:821` | `switch provider` — exhaustive, use `provider.displayLabel` / `.systemImage` / `.helpVerb` |
| `SourceDetailView.mediaProviderInfo` switch | `SourceDetailView.swift:917` | Merge into providerOriginTag via `provider.displayLabel` / `.systemImage` / `.helpVerb` |
| `SourceDetailView.embedEmptyLabel` switch | `SourceDetailView.swift:1043` | `switch provider` |
| `MediaTitleFetcher` oEmbed switch | `MediaTitleFetcher.swift:100` | `switch provider` — exhaustive per-provider URL templates |
| `SourceDetailView:565` equality check | `SourceDetailView.swift:565` | `provider != .legacyImport` |
| `SourceDetailView:1052` equality check | `SourceDetailView.swift:1052` | `provider == .youtube` |
| `ExternalEmbed:150,189` | `ExternalEmbed.swift` | `provider == .applePodcast` |

### Type changes

**`SourceProvenance.agentName`** (`SourceMaterializer.swift:31`):
- Keep as `String` (it's the write-side descriptor that flows to `ensureAgent(name:)`).
  The materializers set it to `SourceProvider.X.rawValue`. This minimizes the diff
  and keeps the GRDBWikiStore write seams untouched.

**`SourceOrigin.agentName`** (`SourceMaterializer.swift:137`):
- Add a computed property `var provider: SourceProvider?` that wraps
  `SourceProvider(rawValue: agentName)`. Keep `agentName: String` as-is (the DB
  read path populates it from `a.name`). The switch sites use `provider` instead
  of raw string matching. This handles unknown values gracefully (nil → default).

### DB write seams (no change needed)

The three `ensureAgent(name: prov.agentName, ...)` calls (`GRDBWikiStore.swift:3217,3338,3638`)
already receive the string. Since the materializers set `agentName =
SourceProvider.X.rawValue`, the stored value is identical. No change.

`legacyImportAgentID` (`:2607`) writes `"legacy-import"` as a literal — it stays
as-is (it's the DB fallback, not a materializer). `SourceProvider.legacyImport`
exists for the read/display side.

### Acceptance criteria

- **AC.1**: `SourceProvider(rawValue:)` round-trips every case.
- **AC.2**: Unknown string ("test", "unknown") → nil (graceful fallback).
- **AC.3**: `displayLabel` / `systemImage` / `helpVerb` return canonical values for every case.
- **AC.4**: `SourceOrigin.provider` resolves correctly for all known providers + nil for unknown.
- **AC.5**: All 4 switch sites + 2 equality checks use the enum, not raw strings.
- **AC.6**: Label disagreements resolved — "Folder" (not "Markdown folder"), "YouTube" (not "Youtube"), "SoundCloud" (not "Soundcloud").
- **AC.7**: `isRefreshable` collapses the refreshability logic from 2 switch sites into one enum property.
- **AC.8**: `swift build` + `swift test` pass (existing test assertions still work — rawValues are unchanged).

### Test strategy

| AC | Test | Location |
|----|------|----------|
| AC.1 | Round-trip every case | `Tests/WikiFSTests/SourceProviderTests.swift` (new) |
| AC.2 | Unknown/string/nil → nil | Same |
| AC.3 | displayLabel/systemImage/helpVerb for each case | Same |
| AC.4 | SourceOrigin.provider for known + unknown | Same |
| AC.5-7 | Existing tests pass (rawValues unchanged) | Existing suite |
| AC.8 | Full suite green | Existing suite |

### Files touched

**New:**
- `Sources/WikiFSTypes/SourceProvider.swift`
- `Tests/WikiFSTests/SourceProviderTests.swift`

**Edit (construction):**
- `Sources/WikiFSCore/Sources/SourceMaterializer.swift` — 5 materializer agentName constants
- `Sources/WikiFSCore/Store/WikiStoreModel.swift:2229,2296` — byteless-media provenance
- `Sources/WikiFSCore/Integrations/MediaEmbedURL.swift:83,104,127,148,170` — MediaEmbedMatch literals

**Edit (parse/display):**
- `Sources/WikiFSCore/Sources/SourceMaterializer.swift:175` — SourceOrigin.displayLabel + add `provider` computed property
- `Sources/WikiFSCore/Sources/SourceRefreshService.swift:84` — switch on provider
- `Sources/WikiFSCore/Store/WikiStoreModel.swift:2834` — isSourceRefreshable via provider
- `Sources/WikiFS/Sources/SourceDetailView.swift:821,917,1043,1052,565` — switch/equality on provider
- `Sources/WikiFSCore/Integrations/ExternalEmbed.swift:150,189` — provider comparison

## Out of scope

- Typing `SourceProvenance.agentKind` (separate concern — overlaps with AgentKind).
- Typing `SourceProvenance.activityKind` ("fetch" vs "import" — separate enum).
- DB CHECK constraints on `agents.name` (migration v42+).
- Changing the materializer protocol signature (`var agentName: String` stays).
- Unifying `SourceEmbedDescriptor.agentName` with `SourceProvider` (tightly coupled to media-player pipeline — separate decision).
