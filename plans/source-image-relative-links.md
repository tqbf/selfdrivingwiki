# Resolve relative image srcs in source-markdown files (follow-on to #216)

**Status:** Ready to execute.

**Bug report:** In the live mount, `sources/by-name/Potluck- Dynamic documents as
personal software--01KX139J.md` has broken images: the markdown contains plain
CommonMark `![](potluck/micro-syntax-1.png)`, but no `potluck/` folder exists
anywhere in the projection. The actual file lives flat at
`sources/by-name/micro-syntax-1--01KX139J.png`.

**Root cause.** `WebsiteSnapshotExtractor` downloads a page's images during
website-snapshot ingestion and rewrites `<img src>` to a relative path like
`potluck/micro-syntax-1.png`, as if a `potluck/` subfolder existed next to the
markdown. But `SQLiteWikiStore.addSnapshotImage` stores each image as its own
independent, flat `sources` row (`WikiStoreModel.storeSnapshot`), and the
FileProvider projection places **all** sources flat under `sources/by-name/` —
there is no nested folder. The relative path in the markdown never resolves.

**This is unrelated to `[[wikilinks]]`** — `RelativeLinkRewriter` only matches
`[[...]]`/`![[...]]` syntax and never touches plain `![alt](src)` images. This
bug predates PR #352 / issue #216 entirely.

**The in-app renderer already solves this correctly** — study it before
touching FileProvider code:
- `SQLiteWikiStore.siblingImageResolvers()` (`Sources/WikiFSCore/SQLiteWikiStore.swift:3365`)
  returns `[PageID: [String: PageID]]`: for each source, its active version's
  `[original_path → sibling image sourceID]` map, built by joining
  `source_versions` on the shared `activity_id` (the page and its images are
  committed together — see `WikiStoreModel.storeSnapshot`).
- `WikiRenderContext` captures this once as `siblingMaps` (`WikiRenderContext.swift:85`).
- `WikiReaderView.swift:842-894` resolves each rendered source's OWN sibling
  map (`context.siblingMaps[sourceID]`), and `MarkdownHTMLRenderer.swift:147-155`
  (`resolvedImageSrc`) does the exact-string match: absolute (`http`/`https`),
  `data:`, `wiki-blob:`, `wiki:` srcs pass through untouched; any other src is
  looked up **exactly** in the map; unmatched relative srcs are left verbatim
  (no guessing).

**Do not reuse `MarkdownHTMLRenderer`** — it depends on `swift-markdown`
(`import Markdown`), which is linked ONLY to the `WikiFS` app target, not
`WikiFSCore`/`WikiFSFileProvider` (check `Package.swift` — the `Markdown`
product dependency is scoped to the app executable). Write a small,
regex-based rewriter in `WikiFSCore` instead, mirroring how
`RelativeLinkRewriter` handles `[[wikilinks]]` without a full Markdown parser.

**Scope: verbatim `sources/by-name` text files ONLY, not the `.md` sibling.**
This matters and is easy to get wrong — verify before coding:

```sh
cat "/Users/wsargent/Library/CloudStorage/SelfDrivingWiki-MalleableSoftware/sources/by-name/"*Potluck*
```
There is only ONE file for this source (no separate `.md` sibling). Per
`Projection.sourceNodes(byName:)`'s existing sibling-eligibility rule
(`!mime.hasPrefix("text/")`), a markdown-native source (its own `mimeType`
already `text/markdown` or similar, as produced by `WebsiteSnapshotExtractor`'s
`.htmlConverted` output) does NOT get a `.md` sibling — **the verbatim
`sources/by-name`/`sources/by-id` file IS the rendered content**. That file is
served by `sourceNode`/`sourceContent` (the `fileULID` branches in
`sourcesProjection`), a COMPLETELY DIFFERENT code path from
`sourceMarkdownNode`/`processedMarkdownHead` (the `.md` sibling, which PR #352
already rewrites for `[[wikilinks]]`). `siblingImageResolvers()` is non-empty
ONLY for sources ingested via `WikiStoreModel.storeSnapshot` (grep confirms
`addSnapshotImage` has exactly one call site), which are always this
markdown-native verbatim case — so this plan touches ONLY the verbatim
`by-name` path. Do not touch the `.md`-sibling path; it's out of scope
(currently unpopulated, would be speculative).

**The size/content byte-identity invariant applies here too, and is currently
NOT held for `sourceNode`** — this is new ground, read carefully.
`sourceNode` (`Projection.swift:1165`) reports `size: file.byteSize`, the
**stored** DB column, not a computed content length — unlike `pageFileNode`/
`sourceMarkdownNode`/`chatFileNode`, which all already accept an optional
`contentData: Data?` to keep size in sync with rewritten bytes. This plan adds
that same optional parameter to `sourceNode`, used ONLY when we rewrite
image srcs (which changes byte length); binary/non-text/no-sibling sources are
completely unaffected and keep using `file.byteSize` as today.

All source changes are in **`Sources/WikiFSCore/`** (new file
`SourceImageRewriter.swift`) and **`Sources/WikiFSFileProvider/Projection.swift`**.
Tests in **`Tests/WikiFSTests/`**.

---

## Task 1 — `SourceImageRewriter` (new file, `Sources/WikiFSCore/SourceImageRewriter.swift`)

Pure, regex-based, no swift-markdown dependency. Mirrors `RelativeLinkRewriter`'s
style: a `Resolver`/`baseDir` pair, code-span protection via the SAME shared
`WikiLinkSpan.protectedCodeRanges`/`isProtected` helpers (already in
`WikiFSCore`, general-purpose — not wikilink-specific), and the SAME
`Target`/`relativePath` reuse from `RelativeLinkRewriter` (same module, so
`RelativeLinkRewriter.relativePath` and `RelativeLinkRewriter.Target` are both
directly callable — `relativePath` is `internal`, fine within `WikiFSCore`;
`Target` is already `public`).

```swift
import Foundation

/// Rewrites plain CommonMark image srcs (`![alt](src)`) in source-markdown
/// content that were downloaded during website-snapshot ingestion
/// (`WebsiteSnapshotExtractor`) and stored as flat sibling `sources` rows
/// (`SQLiteWikiStore.addSnapshotImage`). The extractor rewrites `<img src>` to
/// a relative path like `potluck/diagram.png` as if a nested folder existed
/// next to the markdown, but the FileProvider projection places every source
/// flat under `sources/by-name/` — so that relative path never resolves on
/// disk (or in the in-app WKWebView reader, without this same lookup).
///
/// Mirrors `MarkdownHTMLRenderer.resolvedImageSrc` (`Sources/WikiFS/MarkdownHTMLRenderer.swift`),
/// the in-app renderer's EXACT-STRING resolution of the same `original_path`
/// data (`SQLiteWikiStore.siblingImageResolvers()`) — but implemented as a
/// regex pass here (no `swift-markdown`/`import Markdown`, which is an
/// app-target-only dependency not linked into `WikiFSCore`/`WikiFSFileProvider` —
/// see `Package.swift`). Filtering rule is IDENTICAL: absolute (`http`/`https`),
/// `data:`, `wiki-blob:`, `wiki:` srcs pass through untouched; any other src is
/// looked up EXACTLY (no fuzzy/basename matching) in the resolver; an
/// unresolved relative src is left verbatim — same "don't guess" discipline
/// the in-app renderer uses.
///
/// This is a filesystem-projection concern only — SQLite retains the raw
/// extracted markdown verbatim; nothing here writes back.
public enum SourceImageRewriter {

    /// Namespace resolution for one document being rewritten.
    public struct Resolver {
        /// Root-relative directory of the document being rewritten — e.g.
        /// `["sources", "by-name"]`.
        public let baseDir: [String]
        /// EXACT `original_path` (as it appears in the markdown `![](src)`) →
        /// the resolved target, or `nil` if unresolved.
        public let resolve: (String) -> RelativeLinkRewriter.Target?

        public init(baseDir: [String], resolve: @escaping (String) -> RelativeLinkRewriter.Target?) {
            self.baseDir = baseDir
            self.resolve = resolve
        }
    }

    /// `![alt](src)` — alt has no unescaped `]`; src runs to the first
    /// unescaped `)` or whitespace (an optional `"title"` after whitespace is
    /// tolerated but not captured/preserved — none of today's snapshot images
    /// carry one, and dropping it if present is a acceptable, documented
    /// simplification). Capture groups: 1 = alt, 2 = src.
    private static let regex = try! NSRegularExpression(
        pattern: #"!\[([^\]]*)\]\(([^)\s]+)(?:\s+"[^"]*")?\)"#)

    public static func rewrite(_ body: String, resolver: Resolver) -> String {
        let ns = body as NSString
        let codeRanges = WikiLinkSpan.protectedCodeRanges(in: body)
        let matches = regex.matches(in: body, range: NSRange(location: 0, length: ns.length))

        var out = ""
        var cursor = 0
        for match in matches {
            let full = match.range
            if WikiLinkSpan.isProtected(full, by: codeRanges) { continue }

            let src = ns.substring(with: match.range(at: 2))
            guard let target = resolvedTarget(for: src, resolver: resolver) else { continue }

            if full.location > cursor {
                out += ns.substring(with: NSRange(location: cursor, length: full.location - cursor))
            }
            let alt = ns.substring(with: match.range(at: 1))
            let path = RelativeLinkRewriter.relativePath(from: resolver.baseDir, to: target.path)
            out += "![\(alt)](\(path))"
            cursor = full.location + full.length
        }
        if cursor < ns.length {
            out += ns.substring(with: NSRange(location: cursor, length: ns.length - cursor))
        }
        return out
    }

    /// `nil` for absolute/data/wiki-scheme srcs (leave verbatim, pass copies
    /// through untouched by the caller's cursor logic) OR an unresolved
    /// relative src (also leave verbatim). Mirrors
    /// `MarkdownHTMLRenderer.resolvedImageSrc`'s filter list exactly.
    private static func resolvedTarget(for src: String, resolver: Resolver) -> RelativeLinkRewriter.Target? {
        guard !src.isEmpty else { return nil }
        let lower = src.lowercased()
        if lower.hasPrefix("http") || lower.hasPrefix("data:")
            || lower.hasPrefix("wiki-blob:") || lower.hasPrefix("wiki:") {
            return nil
        }
        return resolver.resolve(src)
    }
}
```

**Verify:** `swift build` (this file alone compiles; `RelativeLinkRewriter.Target`
is `public`, `relativePath` is `internal`-but-same-module — confirm no access
error).

---

## Task 2 — thread a per-source image resolver into `Projection`

### 2a. Extend `LinkMaps` construction to also capture sibling-image data

In `makeLinkMaps()` (`Projection.swift`), after building the existing six
maps, also fetch and store the sibling-image resolver dict:

```swift
struct LinkMaps {
    // ... existing six fields unchanged ...
    let siblingImages: [PageID: [String: PageID]]   // sourceID -> [originalPath -> sibling sourceID]

    // existing resolver(baseDir:) unchanged

    /// The image-src resolver for ONE source's own markdown, or an
    /// always-nil resolver if it has no image siblings (the common case —
    /// most sources never call this at all, gated by the caller).
    func imageResolver(forSource sourceID: PageID, baseDir: [String]) -> SourceImageRewriter.Resolver {
        let siblingMap = siblingImages[sourceID] ?? [:]
        return SourceImageRewriter.Resolver(baseDir: baseDir, resolve: { originalPath in
            guard let siblingID = siblingMap[originalPath] else { return nil }
            return sourceByID[siblingID.rawValue.uppercased()]
        })
    }
}
```

In `makeLinkMaps()`'s body, add:
```swift
let siblingImages = (try? store?.siblingImageResolvers()) ?? [:]
```
and pass it into the `LinkMaps(...)` construction. (`SQLiteWikiStore.siblingImageResolvers()`
is `public func ... throws -> [PageID: [String: PageID]]` — already exists,
`Sources/WikiFSCore/SQLiteWikiStore.swift:3365`. `store` here is the same
`openReadStore()` result already used to build the other five maps — reuse it,
do not open a second connection.)

**Why `sourceByID` (not a new map) resolves the sibling's target correctly:**
sibling images have no processed-markdown head (nothing calls
`appendProcessedMarkdown` for them), so `makeLinkMaps()`'s existing
`hasSibling` check for that row is false, and `sourceByID[siblingID]` already
resolves to the sibling's OWN verbatim by-name `Target` (e.g.
`micro-syntax-1--01KX139J.png`) — exactly the file that exists on disk. No new
lookup table needed.

**Verify:** compiles (used starting Task 3).

---

## Task 3 — apply the rewrite to verbatim `sources/by-name` text files, with the size/content invariant

This touches THREE call sites, all in the `.fileULID` / verbatim-node family —
NOT the `sourceMarkdownByNamePrefix` family (that's the `.md` sibling, out of
scope per the header notes).

### 3a. `Self.sourceNode` — accept optional `contentData`

```swift
    static func sourceNode(for id: NSFileProviderItemIdentifier,
                                 file: SourceSummary,
                                 contentData: Data? = nil) -> ProjectedNode {
        let raw = id.rawValue
        let isByName = raw.hasPrefix(Identity.sourceByNamePrefix)
        let humanName = file.displayName ?? file.filename
        let name = isByName
            ? FilenameEscaping.byNameSourceFilename(
                filename: humanName, ext: file.ext, sourceID: file.id.rawValue)
            : FilenameEscaping.byIDSourceFilename(sourceID: file.id.rawValue, ext: file.ext)
        let parent = isByName ? Identity.sourcesByName : Identity.sourcesByID
        let metaKey = isByName
            ? "\(humanName)|\(file.updatedAt.timeIntervalSince1970)|\(file.version)"
            : "\(file.filename)|\(file.updatedAt.timeIntervalSince1970)|\(file.version)"
        return .file(
            id: id, parent: parent, name: name, size: contentData?.count ?? file.byteSize,
            version: Data(String(file.version).utf8),
            metadataVersion: Data(metaKey.utf8),
            created: file.createdAt, modified: file.updatedAt,
            ingestedExt: file.ext,
            mimeType: file.mimeType
        )
    }
```

### 3b. A shared helper: compute rewritten verbatim content (or nil if unaffected)

Add near `rewriteLinks`/`byTitleContent` in `Projection`:

```swift
    /// Rewrite relative image srcs in a markdown-native verbatim source's own
    /// content, IF it has image siblings (`makeLinkMaps().siblingImages`).
    /// Returns `nil` when there's nothing to rewrite (binary sources, sources
    /// with no image siblings, or non-`by-name` requests) — the caller then
    /// falls back to raw stored bytes with NO computation, matching today's
    /// behavior exactly for every unaffected source (the overwhelming
    /// majority). Byte-identity: both the size path and content path MUST
    /// call this with the same inputs and use the SAME returned Data.
    private func rewrittenVerbatimSourceContent(
        id: PageID, mimeType: String?, maps: LinkMaps
    ) -> Data? {
        guard let mime = mimeType, mime.hasPrefix("text/"),
              let siblingMap = maps.siblingImages[id], !siblingMap.isEmpty,
              let store = openReadStore(),
              let raw = try? store.sourceContent(id: id),
              let text = String(data: raw, encoding: .utf8) else { return nil }
        let resolver = maps.imageResolver(forSource: id, baseDir: Self.sourcesByNameDir)
        let rewritten = SourceImageRewriter.rewrite(text, resolver: resolver)
        return Data(rewritten.utf8)
    }
```

### 3c. `sourcesProjection.nodeForLeaf` — the `fileULID` branch

Current:
```swift
            if let ulid = Identity.fileULID(from: id) {
                guard let store = projection.openReadStore(),
                      let file = try? store.getSource(id: PageID(rawValue: ulid)) else { return nil }
                return Self.sourceNode(for: id, file: file)
            }
```
Change to:
```swift
            if let ulid = Identity.fileULID(from: id) {
                guard let store = projection.openReadStore(),
                      let file = try? store.getSource(id: PageID(rawValue: ulid)) else { return nil }
                if id.rawValue.hasPrefix(Identity.sourceByNamePrefix) {
                    let contentData = projection.rewrittenVerbatimSourceContent(
                        id: PageID(rawValue: ulid), mimeType: file.mimeType,
                        maps: projection.makeLinkMaps())
                    return Self.sourceNode(for: id, file: file, contentData: contentData)
                }
                return Self.sourceNode(for: id, file: file)
            }
```

### 3d. `sourcesProjection.contentForLeaf` — the `fileULID` branch

Current:
```swift
            if let ulid = Identity.fileULID(from: id) {
                guard let store = projection.openReadStore(),
                      let data = try? store.sourceContent(id: PageID(rawValue: ulid)) else { return nil }
                return data
            }
```
Change to:
```swift
            if let ulid = Identity.fileULID(from: id) {
                guard let store = projection.openReadStore(),
                      let file = try? store.getSource(id: PageID(rawValue: ulid)),
                      let data = try? store.sourceContent(id: PageID(rawValue: ulid)) else { return nil }
                if id.rawValue.hasPrefix(Identity.sourceByNamePrefix),
                   let rewritten = projection.rewrittenVerbatimSourceContent(
                       id: PageID(rawValue: ulid), mimeType: file.mimeType,
                       maps: projection.makeLinkMaps()) {
                    return rewritten
                }
                return data
            }
```
(Note the extra `store.getSource` fetch for the mime type — matches the
existing pattern elsewhere in this file of fetching row metadata + content
separately; not a regression in connection count since `openReadStore()`
returns the same cached `ReadScope` connection within one call.)

### 3e. `sourceNodes(byName:)` — the enumeration path's `verbatimNode`

Current (inside the `byName` branch, before the sibling-eligibility guard):
```swift
            let verbatimNode = Self.sourceNode(for: id, file: summary)
```
Change to (only build `maps`/attempt rewrite for `byName`, mirroring the
existing `titleMap`/`maps` pattern already used for the `.md`-sibling
`contentData` a few lines below in this same function):
```swift
            let verbatimContentData = byName
                ? projection.rewrittenVerbatimSourceContent(
                    id: PageID(rawValue: row.id), mimeType: row.mime, maps: maps)
                : nil
            let verbatimNode = Self.sourceNode(for: id, file: summary, contentData: verbatimContentData)
```
`maps` is already built once per call earlier in this function (the existing
`let maps = byName ? makeLinkMaps() : nil` line) — reuse it, do not call
`makeLinkMaps()` again per row. Note: `maps` is `LinkMaps?` there; adjust
`rewrittenVerbatimSourceContent`'s call to unwrap it, or restructure so the
`byName ? ... : nil` ternary short-circuits before touching `maps!`.

**Verify:** `swift build` clean.

---

## Task 4 — do NOT serve rewritten content bytes without a matching size, and vice versa

Read back Tasks 3c/3d/3e once written and confirm by inspection: every place
that builds a `ProjectedNode` with `size: contentData?.count ?? file.byteSize`
for a `sourceByNamePrefix` id has a `contentForLeaf`/enumeration counterpart
that serves EXACTLY that same `contentData` (not a fresh, potentially
different, rewrite). This is the same invariant class as PR #352 — the
`rewrittenVerbatimSourceContent` helper is deliberately the single
computation point (called from both node and content paths) to guarantee this
by construction, same as `rewriteLinks`/`byTitleContent` do for pages.

---

## Task 5 — tests

Add to `Tests/WikiFSTests/` — a new file `SourceImageRewriterTests.swift` for
the pure unit tests, plus cases in `ProjectionTreeTests.swift` for the
end-to-end integration.

### 5a. `SourceImageRewriterTests.swift` (pure, no store)

- Relative src matching the resolver → rewritten to the resolved relative path.
- `http(s)://`, `data:`, `wiki:`, `wiki-blob:` srcs left verbatim (resolver
  never consulted — assert via a resolver that would fatal/flag if called, or
  simply assert the output is byte-identical to input for these cases).
- Unresolved relative src (not in the resolver's map) left verbatim.
- Image inside a code span / fenced block left verbatim.
- Multiple images in one document each resolve independently.
- `alt` text is preserved verbatim in the output.
- A resolver whose target lives in the SAME baseDir yields a bare sibling
  filename (no `../`) — reuses `RelativeLinkRewriter.relativePath`, so a
  single sanity-check test here is enough (that function already has its own
  unit tests).

### 5b. `ProjectionTreeTests.swift` integration case

Seed a source via `store.addSource(filename:..., data:..., mimeType: "text/markdown")`
whose body is `Data("![alt](assets/pic.png)".utf8)`, seed a SECOND source via
`store.addSnapshotImage(filename: "pic.png", data: <bytes>, mimeType: "image/png",
originalPath: "assets/pic.png", sourceURL: URL(string: "https://example.com/pic.png")!,
activityID: <the SAME activityID>, role: .media)`. Getting a real, valid
`activityID` requires `store.ensureFetchActivity(provenance:)` — check its
signature and `SourceProvenance`'s fields first (search
`Sources/WikiFSCore/SQLiteWikiStore.swift` for `ensureFetchActivity` and
`Sources/WikiFSCore/*.swift` for `struct SourceProvenance`) and construct a
minimal fake provenance; mirror any existing test in
`Tests/WikiFSTests/SQLiteWikiStoreTests.swift` that already calls
`addSnapshotImage` or `ensureFetchActivity` for the exact call shape, if one
exists (grep first — don't guess the argument list).

Then assert, via `Projection.Identity.sourceByName(sourceID)`:
- `node.size == contents(for: id)!.count` (byte-identity).
- The served content contains `![alt](pic--<shortID>.png)` or whatever the
  actual resolved by-name filename is — assert with the real
  `FilenameEscaping.byNameSourceFilename(...)` computed value, not a literal
  guess.
- A control case: a text source with NO image siblings serves byte-identical,
  unmodified content and `size == file.byteSize` (regression guard — the vast
  majority of sources must be completely unaffected by this change).

**Verify:** `swift test --filter "SourceImageRewriterTests|ProjectionTreeTests"`
all green.

---

## Out of scope / notes
- The `.md`-processed-sibling path (`sourceMarkdownByNamePrefix`) is
  deliberately untouched — `siblingImageResolvers()` has no entries for that
  case today (only `WikiStoreModel.storeSnapshot`'s verbatim markdown-native
  page calls `addSnapshotImage`). If a future extraction pipeline starts
  producing sibling images for a processed `.md` head, wiring
  `rewrittenVerbatimSourceContent`'s pattern into `sourceMarkdownNode`/
  `processedMarkdownHead` would be a natural, small follow-up — do not do it
  speculatively here.
- `sources/by-id` is untouched (matches the by-title/by-name-only precedent
  from #216).
- Pages and chats are untouched — `siblingImageResolvers()` is keyed by
  SOURCE id only; nothing in the pages/chats schema produces this kind of
  `original_path` sibling relationship.
- After landing, verify live with `make reload` (added in the prior commit),
  the same deployment step used to verify #216 — a code-only rendering change
  is invisible to already-materialized files until the domain resets.
