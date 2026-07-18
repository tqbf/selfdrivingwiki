# Tantivy Search Sidecar — Design Research (#526)

> **Status:** Design research — not implementation. This document evaluates
> replacing the current FTS5 + sqlite-vec + RRF hybrid search with a
> Tantivy-backed search sidecar via [botisan-ai/tantivy.swift](https://github.com/botisan-ai/tantivy.swift).
>
> **Issue:** [#526](https://github.com/tqbf/selfdrivingwiki/issues/526)
>
> **Branch:** `design/tantivy-search-sidecar`

## TL;DR

**Recommendation: Adopt Tantivy as a phased replacement for FTS5 + sqlite-vec,
but only after a build spike validates the XCFramework resolves in SwiftPM
without breaking CI.** The tantivy.swift package addresses every pain point
(unicode tokenizer, faceted search, field boosts, passage snippets) and its
actor-based API fits the event bus sync model. However, three risks must be
spiked before committing:

1. **Build feasibility** — the binary XCFramework must resolve under bare
   `swift build` (no Xcode) and not conflict with the existing `CSqliteVec` C
   target or `-warnings-as-errors`.
2. **Snippet API gap** — the tantivy.swift README does not document
   snippet/highlight generation (Tantivy supports it natively, but the wrapper
   may not expose it). If absent, passage-level results require a raw FFI shim
   or a different approach.
3. **Architecture coverage** — the XCFramework ships `aarch64-apple-darwin`
   (Apple Silicon). Intel Macs are likely unsupported, which is acceptable for
   this project (MLX already requires Apple Silicon) but should be confirmed.

The phased plan: **Phase 0 (build spike)** → **Phase 1 (parallel shadow index)**
→ **Phase 2 (cutover)** → **Phase 3 (retire FTS5 + sqlite-vec)**.

---

## 1. Build Integration Findings

### 1.1 Package structure

The tantivy.swift `Package.swift` (fetched from the `main` branch) uses:

```swift
// swift-tools-version: 6.0
let releaseTag = "0.3.4"
let releaseChecksum = "256fb43709a74b8c0629fd2977c56a2f35a405e57a663aa19bf37f5ffabdea63"
binaryTarget = .binaryTarget(
    name: "TantivyRS",
    url: "https://github.com/botisan-ai/tantivy.swift/releases/download/\(releaseTag)/libtantivy-rs.xcframework.zip",
    checksum: releaseChecksum
)
```

> **Note:** The issue references `from: "0.1.3"` but the current release is
> `0.3.4`. The dependency declaration should use `from: "0.3.4"`.

The package has four targets:

| Target | Type | Role |
|---|---|---|
| `TantivyRS` | Binary (XCFramework) | Pre-compiled Rust static library |
| `TantivyFFI` | Swift target | UniFFI-generated FFI bindings (wraps TantivyRS) |
| `TantivySwift` | Swift target | Public API + `@TantivyDocument` macro (wraps TantivyFFI) |
| `TantivySwiftMacros` | Macro target | SwiftSyntax-based macro implementation |

The package adds a dependency on `swift-lang/swift-syntax` `from: "600.0.0"`
for the macro. This is a build-time dep — it compiles the macro plugin but
doesn't ship in the binary.

### 1.2 Platform & architecture

| Platform | Supported? | Evidence |
|---|---|---|
| macOS (Apple Silicon) | ✅ Yes | `Package.swift`: `.macOS(.v10_15)`. Build script: `aarch64-apple-darwin` |
| macOS (Intel) | ⚠️ Likely no | Build script says "only aarch64 (M-chip macs) and iOS/mac devices are being targeted." `x86_64-apple-darwin` is listed in `rustup target add` instructions but the build script comment says only aarch64 is targeted |
| iOS device | ✅ Yes | `aarch64-apple-ios` |
| iOS simulator (Apple Silicon) | ✅ Yes | `aarch64-apple-ios-sim` |

**For this project:** The app targets macOS 15+ and already requires Apple
Silicon (MLX/Metal embeddings). Intel Macs are not supported. The architecture
constraint is **acceptable** but should be documented in `ISSUES.md`.

### 1.3 SwiftPM resolution under bare `swift build`

**Unverified — requires a build spike (Phase 0).**

SPM binary targets with XCFrameworks download as `.zip` and extract into a
`.build/artifacts/` directory. This works without Xcode *as long as* the
XCFramework contains a `macos-arm64` slice. The `Package.swift` declares
`.macOS(.v10_15)`, which implies macOS slices exist in the framework.

**Known risk:** If the XCFramework is missing the macOS slice (iOS-only), `swift
build` will fail with "noMatchingSlice" or similar at link time. The build
script name (`build-ios.sh`) and its comment ("Builds for iOS targets (device +
simulator + macOS)") suggest macOS is included, but this must be confirmed by
downloading and inspecting the XCFramework.

### 1.4 Interaction with `-warnings-as-errors`

**No conflict expected.** The project's `-warnings-as-errors` flag is applied
via `swiftSettings` on *our* targets only:

```swift
let strictSwiftSettings: [SwiftSetting] = podcastSwiftSettings + [.unsafeFlags(["-warnings-as-errors"])]
```

SPM compiles dependencies in their own module context — a dependency's warnings
do not propagate as errors into the dependent target. The UniFFI-generated
Swift code in `TantivyFFI` and the `@TantivyDocument` macro output in
`TantivySwift` are compiled under the tantivy.swift package's own settings (no
`-warnings-as-errors`).

**One caveat:** If the tantivy.swift package generates warnings under Swift 6.0
strict concurrency (our tools version), `swift build` will *print* them but not
*fail*. If a future SPM version escalates dependency warnings, we'd need to
suppress them — but that's not the case with `swift-tools-version: 6.0` today.

### 1.5 Binary size impact

**Unmeasured — requires the build spike.**

Estimates based on Tantivy's Rust core:

| Component | Estimated size (stripped, aarch64-apple-darwin) |
|---|---|
| libtantivy-rs static library | ~5–15 MB |
| UniFFI FFI bindings (compiled Swift) | ~0.5 MB |
| TantivySwift API layer (compiled Swift) | ~0.5 MB |
| swift-syntax (build-time only, not linked) | 0 (compile-time macro) |

The XCFramework zip likely contains the static `.a` or `.dylib` for 3–4
slices (iOS device, iOS sim, macOS) — the download itself is ~20–40 MB
compressed. The *linked* binary adds ~6–16 MB to the `.app` bundle.

For comparison, the current `sqlite-vec.c` amalgamation compiles to ~1 MB
inside the app binary. Tantivy is heavier, but it replaces FTS5 triggers +
sqlite-vec + the embedding infrastructure, which together consume more space
in the SQLite DB (FTS5 indexes can be 50%+ of base content size).

### 1.6 Build spike plan (Phase 0)

Before any design commitment, verify:

1. `swift build` resolves the binary target and links against
   `aarch64-apple-darwin`.
2. `swift build` succeeds with our existing `CSqliteVec` C target in the same
   package graph (no symbol conflicts).
3. `swift test` passes — TantivySwift's tests compile and run (they're
   included in the package dep).
4. A minimal `@TantivyDocument` struct can be indexed and searched in a
   scratch test target.
5. Binary size delta measured on the built executable.

---

## 2. Document Schema Design

### 2.1 One unified index vs. separate indexes per kind

**Recommendation: One unified index with a `kind` facet field.**

Rationale:
- **Faceted search** is Tantivy's built-in feature — filtering by `kind`
  (page/source/chat) is a single facet term query, not a multi-index union.
- The current architecture splits search across 3 separate FTS tables + 3
  separate embedding tables + 3 separate search methods (`searchSimilar`,
  `searchSimilarSources`, `searchSimilarChats`). A single Tantivy index
  collapses these into one `search(query:limit:)` call with an optional facet.
- The omnibox (address bar) could search across all kinds in one query —
  currently impossible without calling all three search methods.
- Tantivy's field-level indexing means different kinds can have different
  field shapes (a chat has `messageCount`, a source has `mimeType`) while
  sharing the core `title` + `body` + `kind` fields.

### 2.2 Document struct

```swift
@TantivyDocument
struct WikiSearchDocument: Sendable {
    @IDField var id: String           // ULID (page/source/chat id)
    @TextField var title: String      // page.title | source.displayName ?? filename | chat.title
    @TextField var body: String       // body_markdown | processedMarkdown HEAD | concatenated chat messages
    @FacetField var kind: String      // "/page" | "/source" | "/chat"
    @FacetField var tags: [String]    // source tags (future); empty for pages/chats
    @DateField var createdAt: Date
    @DateField var updatedAt: Date
    @U64Field var version: UInt64     // source version number; 0 for pages/chats
    // @BytesField var embedding: Data   // SEE §2.4 — deferred
}
```

Facet values use Tantivy's hierarchical path convention:
`"/page"`, `"/source"`, `"/source/primary"`, `"/source/media"`, `"/chat"`,
`"/chat/ask"`, `"/chat/edit"`.

### 2.3 Content model mapping

The store's content model differs per kind:

| Kind | Title source | Body source | Version awareness |
|---|---|---|---|
| **Page** | `pages.title` | `pages.body_markdown` (inline) | Index `pages` directly; version history is not searched |
| **Source** | `sources.display_name ?? sources.filename` | HEAD of `source_markdown_versions` (content-addressed chain) | Index only the **active** version — `setActiveMarkdown` / version append triggers re-index |
| **Chat** | `chats.title` | `GROUP_CONCAT(chat_messages.text)` for user/assistant messages | Append-only — incremental index update adds new messages without re-indexing old |

**Version handling:** The index reflects the **active version** only. When
`appendProcessedMarkdown` writes a new `source_markdown_versions` row, the
event bus fires → the sidecar re-indexes the source document with the new
HEAD body. When `setActiveMarkdown` changes the active extraction, the same
re-index path fires. Non-active versions are never in the index.

### 2.4 Embeddings in Tantivy?

**Recommendation: Keep embeddings in SQLite (for now). Do not store vectors in
the Tantivy index.**

Rationale:
1. **Tantivy is not a vector database.** It has no native ANN (approximate
   nearest neighbor) search. Storing embeddings as `@BytesField` would enable
   retrieval but not similarity search — you'd still need to compute cosine
   distance in Swift after fetching all vectors, which is O(n) and worse than
   sqlite-vec's `vec_distance_cosine` (which at least uses the vec0 virtual
   table's internal indexing).
2. **The semantic layer is a separate concern.** Tantivy replaces the FTS5/BM25
   layer. The cosine similarity layer (embeddings + vec0) is orthogonal — it
   finds documents by *meaning*, not by keyword. Keeping them separate means
   each can be swapped independently.
3. **The RRF fusion layer stays.** `RankFusion.rrf` is pure Swift and works
   on ranked lists, not on the underlying engine. If the BM25 list comes from
   Tantivy and the cosine list comes from sqlite-vec, the fusion works
   identically — just swap the FTS result source.

**Future option:** If Tantivy adds native vector search (the upstream
`quickwit-oss/tantivy` has experimental support), the embeddings could migrate
into the Tantivy index and eliminate sqlite-vec entirely. But that's a future
optimization, not a Phase 1 requirement.

### 2.5 Chunking strategy

The current `TextChunker` (recursive character splitter, 4000 char chunks with
400 char overlap) lives in `WikiFSSearch`. It's used for two purposes:
1. **Embedding inputs** — chunk → embed → store in `page_chunks`/`source_chunks`/`chat_chunks`
2. **Passage-level cosine** — the vec0 query finds the best-matching *chunk* per document

**With Tantivy, chunking for BM25 is unnecessary** — Tantivy indexes the full
document body and its snippet generator returns the best-matching *passage*
automatically. However, chunking for *embeddings* stays (embeddings still need
short inputs).

So `TextChunker` stays in `WikiFSSearch`, used only by the embedding path. The
FTS path no longer chunks — it indexes the full document body.

---

## 3. Sync Architecture

### 3.1 Event bus subscription

The `WikiEventBus` fires `ResourceChangeEvent` after every `mutate()` — the
natural sync trigger. A new subscriber (the "Tantivy indexer") subscribes to
the bus:

```swift
// Conceptual — not implementation
class TantivyIndexer {
    private let index: TantivySwiftIndex  // actor
    private var token: EventBusSubscriptionToken?

    func subscribe(to bus: WikiEventBus) {
        token = bus.subscribe { [weak self] event in
            guard let self else { return }
            // Runs on MainActor (bus dispatches via Task { @MainActor in ... })
            // But index operations are async (actor) — fire-and-forget Task
            Task { await self.handle(event) }
        }
    }

    private func handle(_ event: ResourceChangeEvent) async {
        guard let kind = event.kind else { return }  // skip coarse events
        switch (kind, event.change) {
        case (.page, .created), (.page, .updated):
            await self.indexPage(id: event.id)
        case (.page, .deleted):
            await self.deleteDoc(id: event.id)
        case (.source, .created), (.source, .updated):
            await self.indexSource(id: event.id)
        case (.source, .deleted):
            await self.deleteDoc(id: event.id)
        case (.chat, .created), (.chat, .updated):
            await self.indexChat(id: event.id)
        case (.chat, .deleted):
            await self.deleteDoc(id: event.id)
        default:
            break  // bookmark, systemPrompt, wikiIndex, log — not searched
        }
    }
}
```

**Key invariant:** The indexer reads from the SQLite store (committed state —
the event fires post-commit) and writes to the Tantivy index (actor-isolated).
This respects the SQLite concurrency discipline: no inference or network inside
a transaction, no statement handle crossing a boundary. The Tantivy write is on
a separate thread (actor), so the main-thread SQLite lock is held only for the
read, not the index write.

### 3.2 Incremental updates

Tantivy supports single-document add/update/delete:
- `index(doc:)` — add or update a document (upsert by ID field)
- `deleteDoc(idField:idValue:)` — delete by ID
- `index(docs:)` — batch (used for initial build)

**Write throughput:** Tantivy uses Lucene-style segment merges. Each document
add creates a new segment; segments are periodically merged. Single-document
commits are slower than batch commits (each creates a segment that must later
merge). For this app's write volume (interactive edits, not bulk ingest), the
throughput is more than sufficient — an interactive wiki has single-document
writes, not high-throughput streaming.

**Optimization:** Batch the event bus events. If a burst of writes happens
(e.g., an agent run appends many chat messages), coalesce the index updates
into a batch `index(docs:)` call after a short debounce (e.g., 500 ms). The
`ChangeCoalescer` pattern (already used by the File Provider subscriber) can
be reused.

### 3.3 Initial index build

When the Tantivy index doesn't exist (first launch after adoption, or a
corrupted index rebuild), it must be built from the existing SQLite DB:

```
1. Open/create the Tantivy index at <appGroupContainer>/<wikiID>.tantivy/
2. [Index] clear()
3. For each page in listAllPagesOrderedByID():
     Index WikiSearchDocument(id: page.id, title: page.title, body: page.body_markdown, kind: "/page", ...)
4. For each source in listAllSourcesOrderedByID():
     Let body = processedMarkdownHead(for: source.id) ?? ""
     Index WikiSearchDocument(id: source.id, title: effectiveName, body: body, kind: "/source", ...)
5. For each chat in listAllChatsOrderedByID():
     Let body = GROUP_CONCAT of chat_messages.text (user/assistant only)
     Index WikiSearchDocument(id: chat.id, title: chat.title, body: body, kind: "/chat", ...)
6. [Index] commit — flush all documents to the segment store
```

This mirrors the existing `rebuildFTS()` flow but writes to Tantivy instead of
the FTS5 tables. The build is O(n) in document count — for a wiki with ~500
documents, it should complete in seconds (Tantivy's multi-threaded indexer is
fast for batch inserts).

**Progress reporting:** Wire into the existing `SearchUpgradeState` sheet
pattern (same UI that shows embedding progress). A `.tantivy` phase shows
"Building search index…".

### 3.4 Crash recovery

If the Tantivy index is corrupted or missing:

1. **Detection:** On wiki open, check if the Tantivy index directory exists
   and `index.count()` matches the SQLite document count. If the count is 0
   but SQLite has content, or if opening the index throws, trigger a rebuild.
2. **Rebuild:** Run the initial build flow (§3.3). This is the same "self-heal"
   pattern used by `ensureSearchIndexesPopulated()` for FTS5 today.
3. **Atomicity:** The Tantivy index is a directory on disk. A rebuild can
   write to a temporary directory (`<wikiID>.tantivy.new/`) and atomically
   rename it over the old one — a crash mid-rebuild leaves the old index
   intact (or no index, which triggers a rebuild on next open).

**SQLite is always the source of truth.** The Tantivy index is a derived
artifact — if it's lost, it's rebuilt from the DB. This is the same
contract as the FTS5 indexes today.

### 3.5 Cross-process writes (wikictl, daemon)

`wikictl` opens its own `SQLiteWikiStore` with a `nil` event bus (no
`ResourceChangeEvent` is emitted). The Darwin notification fires → the app's
`WikiChangeBridge` emits a coarse `.external` event.

The Tantivy indexer subscribes to the bus and receives the coarse event. But
coarse events have `kind = nil` — the indexer can't know *what* changed.

**Options:**
- **A. Full rebuild on coarse event.** Simple but slow for every `wikictl`
  write. Only acceptable if the wiki is small.
- **B. Diff-and-reindex.** Compare the Tantivy index's document IDs against
  the SQLite store's IDs, then re-index only the deltas. More complex but
  faster. This is a viable follow-up optimization.
- **C. Wikictl writes to Tantivy directly.** `wikictl` could open the Tantivy
  index alongside the SQLite DB and update it on every write — but this
  means every client of the store also manages the sidecar, which violates
  the "sidecar is transparent" goal.

**Recommendation: Option A for Phase 1 (simple, correct); Option B as a
follow-up optimization.** Coarse events are infrequent (only `wikictl` /
external writes trigger them, not interactive app edits). A full rebuild on
every external write is acceptable for the common case (a few `wikictl`
commands per session). For active agent runs that write frequently, the
coalesce + debounce pattern limits rebuilds.

---

## 4. Search API Replacement Design

### 4.1 Current protocol methods

The `WikiStore` protocol currently exposes three search methods:

```swift
func searchSimilar(query: String, limit: Int) throws -> [WikiPageSummary]
func searchSimilarSources(query: String, limit: Int) throws -> [SourceSummary]
func searchSimilarChats(query: String, limit: Int) throws -> [ChatSummary]
```

Each calls `hybridSearch(kind:query:limit:...)` — a generic that runs FTS5
+ vec0 + RRF. The result types are distinct per kind (`WikiPageSummary`,
`SourceSummary`, `ChatSummary`).

### 4.2 Proposed replacement

**Option A: Keep the three-method shape, swap the implementation.**

The three protocol methods stay. Internally, each delegates to a
`TantivySearchService` that queries the unified index with a kind facet
filter:

```swift
// Conceptual
func searchSimilar(query: String, limit: Int) throws -> [WikiPageSummary] {
    let results = try tantivy.search(
        query: query, kindFacet: "/page", limit: limit)
    return results.map { WikiPageSummary(from: $0) }
}
```

**Pros:** No protocol breakage. `WikiStoreModel`, all views, all CLI commands
are unchanged. The Tantivy integration is behind the store implementation.

**Cons:** The three methods can't return passage-level results (they return
`WikiPageSummary` — whole-document summaries). Passage-level results require
a new return type.

**Option B: New unified search method + keep old methods as thin wrappers.**

```swift
struct SearchResult: Sendable {
    let id: PageID
    let kind: SearchResultKind   // .page, .source, .chat
    let title: String
    let snippet: String?         // passage-level highlight (if available)
    let score: Float
}

func search(query: String, kinds: [SearchResultKind], limit: Int) throws -> [SearchResult]
```

The old `searchSimilar` / `searchSimilarSources` / `searchSimilarChats`
become convenience wrappers:

```swift
func searchSimilar(query: String, limit: Int) throws -> [WikiPageSummary] {
    try search(query: query, kinds: [.page], limit: limit)
        .map { WikiPageSummary(from: $0) }
}
```

**Pros:** Enables the omnibox to search all kinds in one query. Enables
passage-level snippets. The old methods' callers are unchanged.

**Cons:** New protocol method to implement + test. The `SearchResult` type
needs to carry kind-specific metadata (source has `mimeType`, chat has
`messageCount`).

**Recommendation: Option B.** It enables the cross-kind search that the
omnibox needs and the passage-level results that the issue calls for, while
keeping the old methods' callers working. The `SearchResult` struct is small
and the protocol addition is additive (not breaking).

### 4.3 Passage-level results (snippets)

The tantivy.swift README does **not** document snippet/highlight generation.
Tantivy itself provides `SnippetGenerator` (creates highlighted snippets from
query matches), but the Swift wrapper may not expose it.

**If snippets are available:** The `SearchResult.snippet` field carries the
highlighted passage. The omnibox shows it as a subtitle under each result.
The agent gets the snippet in the `wikictl search` TSV output.

**If snippets are NOT available (likely):** Two fallback options:
1. **Client-side highlighting.** After Tantivy returns the matching document,
   run a regex or string-search highlight on the body to find the first
   occurrence of query terms. Crude but functional.
2. **Raw FFI shim.** Call Tantivy's `SnippetGenerator` through the UniFFI
   bindings directly (bypass the Swift wrapper's higher-level API). This
   requires understanding the generated FFI types — feasible but fragile
   across version updates.

**Recommendation:** Use client-side highlighting for Phase 1. If the wrapper
adds snippet support in a future release (or we contribute it upstream), swap
to native snippets.

### 4.4 Semantic search integration

The hybrid (BM25 + cosine + RRF) architecture stays, but the BM25 source
changes:

| Layer | Current | After Tantivy |
|---|---|---|
| BM25 / lexical | FTS5 (`pages_fts`, `sources_fts`, `chats_fts`) | Tantivy index (actor `search(query:)`) |
| Semantic / cosine | sqlite-vec `vec0` + `vec_distance_cosine` | **Unchanged** — embeddings stay in SQLite |
| Fusion | `RankFusion.rrf` (pure Swift) | **Unchanged** — fuses Tantivy results + cosine results |

The `hybridSearch` generic stays the same shape — it takes an FTS closure
and a semantic closure and fuses them. The FTS closure now queries Tantivy
instead of SQLite's FTS5:

```swift
// Conceptual — the FTS closure changes from SQLite FTS5 to Tantivy
fts: { pool in
    // Before: try searchPagesFTS(query: query, limit: pool)
    // After:  try tantivy.search(query: query, kindFacet: "/page", limit: pool)
}
```

**Does Tantivy's BM25 replace the need for semantic search?** No. Tantivy's
BM25 is a *lexical* search — it finds documents by keyword matching (better
than FTS5 due to unicode tokenization, phrase queries, field boosts, etc.).
But it doesn't find documents by *meaning*. A query "machine learning
frameworks" won't match a page titled "MLX embeddings" unless "machine" or
"learning" or "frameworks" appears in the body. Semantic cosine finds it
because the embedding vectors are close.

Keep the hybrid: Tantivy BM25 for lexical + sqlite-vec cosine for semantic +
RRF fusion. Tantivy improves the lexical half; the semantic half is unchanged.

### 4.5 Omnibox integration

The omnibox (`AddressBarView`) currently calls `store.searchSimilar` (pages
only) with a 300ms debounce. With the unified search method (§4.2, Option B),
the omnibox can search across all kinds:

```swift
// Conceptual
let results = try store.search(query: query, kinds: [.page, .source, .chat], limit: 20)
```

The dropdown shows mixed results (pages, sources, chats) with kind icons and
optional snippets. This is strictly better than the current pages-only
omnibox.

**Debounce:** Tantivy's search latency is sub-millisecond for small indexes
(Lucene-class engines are designed for this). The 300ms debounce can stay or
even be reduced.

### 4.6 wikictl search commands

The CLI commands (`wikictl search`, `wikictl source search`, `wikictl chat
search`) would need to query the Tantivy index. But `wikictl` opens its own
`SQLiteWikiStore` and doesn't have access to the Tantivy index (which is
managed by the app via the event bus).

**Options:**
- **A. wikictl opens the Tantivy index directly.** The index lives in the App
  Group container, so `wikictl` can open it. But `wikictl` would need to link
  the `TantivySwift` package — adding a large dependency to a small CLI.
- **B. wikictl uses FTS5-only (the old path).** Since the FTS5 tables stay
  as a fallback (§5), `wikictl` keeps using the existing `searchPagesFTS` /
  `searchSourcesFTS` / `searchChatsFTS` methods. The results are slightly
  worse (no unicode tokenization, no facets, no snippets) but functional.
- **C. wikictl queries the Tantivy index via the daemon (wikid).** The XPC
  daemon owns the store lifecycle. If the daemon also owns the Tantivy
  index, `wikictl` can send search requests via XPC. This is the cleanest
  long-term path but depends on the multi-wiki-daemon (#358) daemon-first
  architecture being further along.

**Recommendation: Option B for Phase 1** (wikictl uses FTS5 fallback — it
still works). **Option C for Phase 3** (when the daemon is the search owner,
wikictl delegates via XPC). This avoids adding the Tantivy dependency to
wikictl prematurely.

---

## 5. Fallback Strategy

### 5.1 Keep FTS5 as a fallback?

**Yes — for Phase 1 and Phase 2 (shadow + cutover). Remove in Phase 3.**

**Phase 1 (shadow):** Tantivy runs in parallel with FTS5. Both indexes are
maintained. Search still uses FTS5; Tantivy results are logged for comparison
but not shown to the user. This validates index sync correctness without
risking search quality regressions.

**Phase 2 (cutover):** Search switches to Tantivy. FTS5 tables are still
maintained (triggers still fire — they're part of the schema) but not
queried. If Tantivy search returns empty or throws, the store falls back to
the existing `searchPagesFTS` path. This is the safety net.

**Phase 3 (retire):** Once Tantivy has been validated in production:
- Drop the FTS5 trigger tables (`pages_fts`, `sources_fts`, `chats_fts`)
- Drop the FTS5 sidecar tables (`source_search`, `chat_search`)
- Drop the `sqlite-vec` `vec0` virtual tables and the `CSqliteVec` C target
- Remove `EmbeddingService`, `NLEmbedder`, `TextChunker`, `RankFusion` from
  the store's search path (keep them if embeddings stay for cosine search)
- The schema migration is a single `DROP TABLE` batch in the version ladder

### 5.2 What if the Tantivy index is missing or corrupted?

**Fallback to FTS5 (Phase 2) or rebuild (Phase 3).**

During Phase 2, if the Tantivy index fails to open or returns an error:
```swift
do {
    return try tantivy.search(query: query, kindFacet: "/page", limit: limit)
} catch {
    DebugLog.store("Tantivy search failed — falling back to FTS5: \(error)")
    return try searchPagesFTS(query: query, limit: limit)  // the old path
}
```

During Phase 3, the fallback is a rebuild (§3.4) — no FTS5 to fall back to.
The store returns an empty list + logs the failure. A rebuild is scheduled
asynchronously.

### 5.3 Embedding fallback (unchanged)

The embedding fallback behavior is unchanged. When the embedding model is
unavailable (non-app context, model load failure), the semantic cosine pass
is skipped and search falls back to BM25-only (now from Tantivy instead of
FTS5). The `isVecAvailable()` + `EmbeddingService.embeddingBlob(for:)` guard
stays.

---

## 6. Export / Portability

### 6.1 Export

`wikictl wiki export` exports the SQLite DB. The Tantivy index is **not**
exported — it's a derived artifact rebuilt from the DB on import. This is the
same contract as the FTS5 indexes today (the FTS5 tables are part of the
SQLite DB, but they can be rebuilt from the base tables).

**After Phase 3 (FTS5 retired):** The SQLite DB no longer contains FTS5 tables.
Export is smaller. The Tantivy index is rebuilt on import — the first search
after import triggers a rebuild (or it happens eagerly on wiki open via
`ensureSearchIndexesPopulated`).

### 6.2 Index location

**Recommendation: App Group container, alongside the `.sqlite` files.**

```
~/Library/Group Containers/<appGroupID>/
├── <ulid>.sqlite          # the wiki DB
├── <ulid>.sqlite-wal      # WAL sidecar
├── <ulid>.sqlite-shm      # shared memory
├── <ulid>.tantivy/        # Tantivy index directory (NEW)
│   ├── meta.json
│   ├── store/             # segment files
│   └── ...
├── wikis.json             # registry: name → ULID
└── queue.sqlite           # queue DB (unrelated)
```

The index directory is per-wiki (keyed by ULID). On wiki switch, the active
index changes. On wiki delete, the index directory is deleted.

**TCC note:** The App Group container is protected (Full Disk Access required
for shell access). The Tantivy index is accessed by the app process (which has
entitlements), so this is not a problem. `wikictl` doesn't access the Tantivy
index (it uses FTS5 fallback — §4.6).

---

## 7. Performance Considerations

### 7.1 Query latency

| Metric | Current (FTS5 + vec0) | Tantivy (estimated) |
|---|---|---|
| BM25 query (100 pages) | ~1–5 ms (SQLite FTS5) | <1 ms (Lucene-class, in-memory segments) |
| Semantic cosine (100 pages) | ~5–20 ms (vec0 scan) | Unchanged |
| Hybrid (BM25 + cosine + RRF) | ~10–30 ms | ~5–25 ms (BM25 faster, cosine unchanged) |
| Omnibox debounce (300 ms) | Well within budget | Even more headroom |

Tantivy's segment-based inverted index is designed for sub-millisecond queries
on small-to-medium indexes (<1M documents). A wiki with a few hundred pages
is trivially fast.

### 7.2 Index size

| Component | Current | Tantivy |
|---|---|---|
| FTS5 index (`pages_fts` etc.) | ~50% of base content size | ~50–70% of base content (compressed, but Tantivy stores more metadata) |
| Embedding chunks (`page_chunks` etc.) | ~1 KB per chunk × ~4 chunks/page = ~4 KB/page | Unchanged |
| vec0 virtual tables | ~8 KB per 512-dim vector × N chunks | Unchanged (or removed if embeddings migrate) |

Tantivy's index is a directory (not a single blob). The compressed inverted
index is roughly comparable to FTS5's size. The win is in *query quality*
(unicode tokenization, field boosts, facets, snippets), not necessarily in
disk space.

### 7.3 Write throughput

| Operation | Current (FTS5 triggers) | Tantivy (actor async) |
|---|---|---|
| Single page save | ~5 ms (trigger fires synchronously) | ~1–5 ms (async actor write, no blocking) |
| Source markdown append | ~10 ms (trigger + sidecar upsert) | ~1–5 ms (async actor write) |
| Chat message append | ~10 ms (sidecar rebuild + trigger) | ~1–5 ms (async actor write) |
| Bulk rebuild (500 docs) | ~2–5 s (FTS5 `rebuild` command) | ~0.5–2 s (multi-threaded indexer) |

Tantivy's async writes don't block the main thread (actor-isolated). FTS5
triggers run synchronously on the store's lock — each trigger adds latency to
the store mutation. Tantivy's event-bus-driven async writes decouple index
updates from store mutations, improving write latency on the main thread.

**Trade-off:** Async writes mean the Tantivy index can momentarily lag behind
the SQLite DB (between the event bus emit and the actor write). This is
acceptable — search results may be ~100 ms stale after a write, but the same
is true of the current embedding pipeline (re-embed is best-effort and
async via `upgradeSearchIndex`).

### 7.4 Benchmark plan

Before Phase 2 cutover, measure on a real wiki (~100 pages, ~50 sources,
~20 chats):

1. **Query latency** — 50 representative queries, measure p50/p99 for:
   - FTS5 BM25-only
   - Tantivy BM25-only
   - Hybrid (FTS5 + cosine + RRF)
   - Hybrid (Tantivy + cosine + RRF)
2. **Index size** — disk usage of FTS5 tables vs Tantivy directory
3. **Write throughput** — time 100 sequential page saves with FTS5 triggers
   vs Tantivy actor writes
4. **Initial build time** — `rebuildFTS()` vs Tantivy full build from DB

---

## 8. Interaction with Module Restructuring and GRDB

### 8.1 WikiFSSearch module (#532, shipped)

The `WikiFSSearch` target (extracted in module restructuring Phase 3) already
isolates the embedding/search code:

```
WikiFSSearch/
├── Embedder.swift          # protocol
├── NLEmbedder.swift        # Apple NLEmbedding (512-dim)
├── EmbeddingService.swift  # factory + inference
├── TextChunker.swift       # recursive character splitter
├── RankFusion.swift        # RRF fusion
├── WikiIndex.swift         # the curated catalog document
└── _Exports.swift
```

**Tantivy integration fits here.** The `TantivySearchService` (the Swift actor
wrapping `TantivySwiftIndex`) belongs in `WikiFSSearch` — it's a search
component, not a store concern. The store calls through a protocol seam;
the implementation lives in the search module.

**Dependency change:** `WikiFSSearch` would gain a dependency on the
`TantivySwift` package. This is the right place — the search module is the
natural home for search engine integration.

```
WikiFSSearch
├── (existing files)
├── TantivySearchService.swift     # NEW — actor wrapping TantivySwiftIndex
├── TantivyIndexer.swift           # NEW — event bus subscriber → index updates
└── WikiSearchDocument.swift       # NEW — @TantivyDocument struct
```

**Access control:** `TantivySearchService` and `TantivyIndexer` stay `public`
(used by `WikiFSCore` / `WikiStoreModel`). The `WikiSearchDocument` struct is
`internal` to `WikiFSSearch` (the store and model interact via the search
service's result types, not the raw Tantivy document).

### 8.2 TextChunker stays

`TextChunker` stays in `WikiFSSearch` — it's still used by the embedding path
(chunking documents for `EmbeddingService.chunkedEmbeddings`). Tantivy doesn't
need chunking for BM25 (it indexes the full document), but the semantic layer
still does.

### 8.3 GRDB adoption (#530/#538)

The GRDB adoption design doc (§10) explicitly addresses Tantivy:

> If Tantivy replaces FTS5 + sqlite-vec + RRF, the SQLite store would drop its
> FTS5 trigger tables and embedding chunk tables entirely. GRDB's
> `DatabaseMigrator` makes the migration to drop these tables cleaner (named
> migration: "v38_remove_fts5_and_vec").

The two efforts are **complementary**:
- **GRDB** replaces the data layer plumbing (statements, pools, transactions,
  migrations) — it touches the *store implementation*.
- **Tantivy** replaces the search layer (FTS5/BM25 + vec0) — it touches the
  *search service*.

Neither blocks the other. The search service reads from the store via the
`WikiStore` protocol (88 methods), which is implementation-agnostic. Whether
the store is `SQLiteWikiStore` (hand-rolled) or `GRDBWikiStore` (GRDB-based),
the search service calls the same protocol methods (`getPage`, `listSources`,
`processedMarkdownHead`, etc.) to build and maintain its index.

**Sequencing:** If both efforts happen concurrently, Tantivy should go first.
Tantivy removes the FTS5/vec search code from the store, simplifying the
GRDB migration (fewer raw SQL search queries to port). GRDB's `prepareDatabase`
closure also replaces the manual `registerVec(on:)` call — if Tantivy removes
the vec layer, the GRDB migration doesn't need to preserve vec registration.

### 8.4 WikiFSEngine / wikid daemon

When the `wikid` XPC daemon (#358) owns the wiki store lifecycle, it would
also own the Tantivy index (the indexer subscribes to the store's event bus,
which is per-wiki). `wikictl` could send search requests via XPC (§4.6,
Option C), eliminating the FTS5 fallback for CLI search.

---

## 9. Recommended Approach + Risks

### 9.1 Phased plan

| Phase | Scope | Effort | Risk |
|---|---|---|---|
| **Phase 0: Build spike** | Add tantivy.swift dep, verify `swift build` + `swift test` pass, verify XCFramework resolves for `aarch64-apple-darwin`, measure binary size, write a scratch `@TantivyDocument` index/search test | 1–2 days | LOW — no production code changes; spike only |
| **Phase 1: Shadow index** | Implement `TantivySearchService` + `TantivyIndexer` + `WikiSearchDocument` in `WikiFSSearch`. Wire the event bus subscription. Build the index from SQLite on first open. Run Tantivy search in parallel with FTS5 — log results for comparison, don't show to user | 3–5 days | LOW — no user-facing behavior change; FTS5 is still the search path |
| **Phase 2: Cutover** | Switch `searchSimilar` / `searchSimilarSources` / `searchSimilarChats` to query Tantivy (with FTS5 fallback on error). Add unified `search(query:kinds:limit:)` method. Update omnibox to cross-kind search. Benchmark vs FTS5 | 2–3 days | MEDIUM — user-facing search results change; needs benchmark validation |
| **Phase 3: Retire FTS5 + sqlite-vec** | Drop FTS5 trigger tables + sidecar tables + vec0 tables + `CSqliteVec` C target from schema. Remove FTS5 search methods. Remove `RankFusion` from the BM25 path (keep if embeddings stay). One-time schema migration | 1–2 days | MEDIUM — schema change; fallback path removed; needs crash recovery validation |

**Total estimated effort: ~1.5–2 weeks** (Phase 0 through Phase 3).

### 9.2 Risks

| Risk | Severity | Mitigation |
|---|---|---|
| **XCFramework doesn't resolve in bare `swift build`** | HIGH — blocks the entire approach | Phase 0 build spike resolves this before any real work. If it fails, fall back to building Tantivy from source (Rust toolchain) or vendoring a custom XCFramework |
| **No snippet/highlight API in tantivy.swift** | MEDIUM — passage-level results are a stated goal | Client-side highlighting fallback (§4.3). Contribute snippet support upstream if needed |
| **No x86_64 support** | LOW — app already requires Apple Silicon (MLX) | Document in `ISSUES.md`. Not a blocker |
| **Index sync lag** | LOW — Tantivy writes are async; search results can be ~100 ms stale after a write | Acceptable for interactive use. The embedding pipeline has the same lag today |
| **Cross-process writes (wikictl) not reflected in Tantivy** | MEDIUM — wikictl writes trigger a coarse event, not a kind-specific one | Phase 1: full rebuild on coarse event (simple, correct). Phase 2+: diff-and-reindex optimization |
| **Binary size increase (~6–16 MB)** | LOW — the app is already large (MLX, WKWebView, File Provider) | Measure in Phase 0. Acceptable if <20 MB |
| **swift-syntax dependency build time** | LOW — macro plugins compile once | Measure in Phase 0. If significant, cache the build |
| **Tantivy index corruption** | MEDIUM — loss of search index | SQLite is always the source of truth; automatic rebuild on detection (§3.4) |
| **Event bus subscriber leak** | MEDIUM — the indexer token must be unsubscribed on store swap (same as FP subscriber) | Follow the existing `WikiEventBus` subscriber lifecycle pattern (unsubscribe on `deinit` / store swap) |
| **`StoreEmissionExhaustivenessTests` interaction** | LOW — the Tantivy indexer is a *subscriber*, not a mutator on the store | No new store mutators are added. The indexer calls existing read methods (`getPage`, `processedMarkdownHead`, etc.) and writes to the Tantivy index (not the store) |
| **UniFFI Swift code quality / Swift 6 concurrency** | MEDIUM — UniFFI-generated code may not be `Sendable`-clean | Phase 0 spike validates compilation under Swift 6.0 strict concurrency. If warnings appear, they don't escalate to errors (our `-warnings-as-errors` doesn't apply to deps). If hard errors, need a fork or wrapper |

### 9.3 Open questions

1. **Does the tantivy.swift XCFramework include a macOS slice?** Must be
   verified in Phase 0 (download the zip, inspect `Info.plist` for
   `SupportedArchitectures` containing `arm64` with `Platform = macos`).
2. **Does tantivy.swift expose `SnippetGenerator`?** Must be verified in
   Phase 0 (inspect the `TantivySwift` public API or the UniFFI-generated
   bindings for snippet/highlight methods).
3. **What's the actual binary size delta?** Measured in Phase 0.
4. **Does Tantivy's actor model interact safely with the app's Swift 6
   concurrency?** The actor is `Sendable`; the `TantivySwiftIndex` actor
   should be safe to call from `@MainActor` context. Verify in Phase 0.
5. **Should embeddings eventually migrate into Tantivy (if/when it supports
   native vector search)?** Future decision — track upstream
   `quickwit-oss/tantivy` vector support. For now, embeddings stay in SQLite.
6. **Should the unified `search(query:kinds:limit:)` method be on the
   `WikiStore` protocol or on a separate `WikiSearchService` protocol?**
   Protocol design decision — having it on `WikiStore` is simpler (the store
   delegates to the search service); a separate protocol is cleaner but
   requires a new conformance surface. Lean toward `WikiStore` for Phase 2.

### 9.4 Decision summary

| Decision | Recommendation | Rationale |
|---|---|---|
| Adopt Tantivy? | **Yes, phased** | Addresses all 6 pain points (unicode, facets, snippets, single index, passage results, field boosts) |
| One index or N? | **One unified index** | Faceted search, cross-kind omnibox search, simpler sync |
| Embeddings in Tantivy? | **No — keep in SQLite** | Tantivy has no ANN; sqlite-vec cosine is orthogonal |
| Keep FTS5 as fallback? | **Phase 1–2: yes; Phase 3: no** | Safety net during cutover; removed once validated |
| Keep RRF fusion? | **Yes** | Fuses Tantivy BM25 + sqlite-vec cosine; pure Swift, unchanged |
| Module home? | **WikiFSSearch** | Already isolates search code; natural dependency target |
| Block on GRDB? | **No — complementary** | Tantivy goes first (simplifies GRDB migration); neither blocks the other |
| wikictl search? | **Phase 1–2: FTS5 fallback; Phase 3: daemon XPC** | Avoids adding Tantivy dep to wikictl prematurely |
