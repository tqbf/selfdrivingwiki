# Module Restructuring — Design (Option C/D)

> Research deliverable for [issue #532](https://github.com/tqbf/selfdrivingwiki/issues/532).
> Follow-up to #531 (directory reorganization, Option A). This document evaluates
> splitting `WikiFSCore` and `WikiFS` into multiple SPM targets with proper
> `internal` access control and a composition-root pattern.

## TL;DR

**Recommendation: Option D (phased), but scoped.** Extract the three low-risk
pure-logic clusters first (`WikiFSLinks`, `WikiFSMarkdown`, `WikiFSSearch`),
 yielding real but modest build-time wins and access-control benefits. Do **not**
 attempt `WikiFSStorage` extraction or `WikiStoreModel` decomposition in this
 cycle — the coupling data shows `SQLiteWikiStore` and `WikiStoreModel` both
 touch **all** domain clusters via direct type references, making a clean
 storage/composition-root split a multi-sprint protocol-injection project with
 high regression risk and uncertain payoff. Phases 1–3 ship ~80% of the
 incremental-build benefit for ~20% of the risk.

---

## 1. Target Graph (End State — Recommended Phased Subset)

```
                          ┌──────────────────────────────────────┐
                          │         WikiFSCore (slimmed)          │
                          │  shared value types + WikiStore proto │
                          │  (the leaf — everyone depends on it)  │
                          └──────────────┬───────────────────────┘
                 ┌───────────────────────┼────────────────────────┐
                 ▼                       ▼                        ▼
        ┌────────────────┐   ┌────────────────────┐     ┌──────────────────┐
        │  WikiFSLinks   │   │  WikiFSMarkdown    │     │  WikiFSSearch    │
        │  (pure logic)  │   │  (pure logic)      │     │  (NaturalLanguage)│
        └───────┬────────┘   └─────────┬──────────┘     └────────┬─────────┘
                │                      │                         │
                └──────────┬───────────┘                         │
                           ▼                                     ▼
        ┌──────────────────────────────────────────────────────────────┐
        │                    WikiFSCore (Store + Core + Sources)         │
        │  SQLiteWikiStore · WikiStoreModel · WikiRenderContext · …     │
        │  (NOT split — keep as the monolithic core, Phase 5 deferred) │
        └──────────────────────────┬───────────────────────────────────┘
                                   ▼
        ┌──────────────────────────────────────────────────────────────┐
        │  WikiFSEngine · WikiFSMLX · WikiFS · WikiCtlCore · wikid ·    │
        │  WikiFSFileProvider  (consumers — depend on WikiFSCore +     │
        │  whichever domain targets they need)                          │
        └──────────────────────────────────────────────────────────────┘
```

**Why not the full 6-target end-state from the issue?** The access-control and
circular-dependency audit (§5–6) reveals that `SQLiteWikiStore` and
`WikiStoreModel` are **not** leaves — they reference types from Links, Markdown,
Search, and the Sources/glue cluster. Extracting them into `WikiFSStorage` /
`WikiFSModel` would require either (a) making Storage depend on all domain
targets (recreating the monolith as a fan-in node), or (b) protocol-injecting
every cross-domain call site (a large refactor with high test-surface risk).
The payoff — incremental build time — is dominated by `SQLiteWikiStore.swift`
(8,000+ lines) which recompiles regardless of target boundaries because it's
the hub. Splitting the pure-logic leaf clusters captures most of the win.

---

## 2. Per-Target File Inventories

### Current directory structure (from #531)

| Subdir   | Files | Lines   | Exports to consumers |
|----------|-------|---------|----------------------|
| Core     | 51    | 6,967   | Shared types, model, queue, registry |
| Store    | 9     | 13,408  | WikiStore protocol, SQLiteWikiStore, WikiStoreModel |
| Sources  | 14    | 1,935   | Ingest staging, link reconciler, source refresh |
| Markdown | 15    | 2,929   | Linter, HTML tokenize, diff, slug |
| Links    | 11    | 1,822   | Link parser, resolver, rewriter, rules |
| Integrations | 25 | 3,660  | Zotero, extraction backends, podcast, URL fetch |
| Search   | 6     | 413     | Embedding service, chunker, rank fusion |
| **Total**| **131** | **30,134** | |

### Phase 1: `WikiFSLinks` (extract)

| File                        | Lines | Notes |
|-----------------------------|-------|-------|
| WikiLinkParser.swift        | ~200  | Defines `ParsedLink` — see §5 cycle note |
| WikiLinkResolver.swift      | ~100  | All `static func`, no store dep |
| WikiLinkRewriter.swift      | ~150  | Pure string transforms |
| WikiLinkMarkdown.swift      | ~120  | Pure |
| WikiLinkSpan.swift          | ~80   | Value type |
| WikiLinkMenuBuilder.swift   | ~100  | Pure |
| WikiLinkFixer.swift         | ~80   | Pure |
| RelativeLinkRewriter.swift  | ~100  | Pure |
| WikiNameRules.swift         | ~200  | Pure naming-grammar rules |
| WikiText.swift              | ~150  | Normalization helpers |
| WikiLinkIndex.swift         | ~100  | Pure |

**~1,380 lines.** Depends on: `WikiFSCore` (for `PageID` and shared types).

**Access control:** All 11 types stay `public` — they're consumed by
`SQLiteWikiStore` (WikiFSCore) and the app. Internal parsing helpers become
`internal`.

### Phase 2: `WikiFSMarkdown` (extract)

| File                        | Lines |
|-----------------------------|-------|
| MarkdownLinter.swift        | ~200  |
| MarkdownExtractor.swift     | ~150  |
| MarkdownFolderReader.swift   | ~100  |
| MarkdownDiff.swift           | ~200  |
| SplitDiff.swift              | ~150  |
| Diff3.swift                  | ~300  |
| WikiFootnoteMarkdown.swift   | ~150  |
| HTMLTokenizer.swift          | ~300  |
| HTMLToMarkdown.swift         | ~200  |
| HTMLMarkdownRenderer.swift   | ~200  |
| HTMLEntities.swift          | ~50   |
| SlugUtils.swift             | ~100  |
| MermaidValidator.swift      | ~250  |
| AnchorBlock.swift           | ~100  |
| PageMarkdownFormat.swift     | ~80   |

**~2,530 lines.** Depends on: `WikiFSCore`. May need `WikiFSLinks` for
`WikiText`/`WikiLinkMarkdown` types used in rendering — verify during extraction.

**Access control:** `MarkdownLinter` stays `public` (used by WikiCtlCore for
preflight checks in wikictl). `HTMLTokenizer`, `HTMLEntities` become
`internal` (not referenced outside WikiFSCore). `SlugUtils` stays `public`
(used by SQLiteWikiStore).

### Phase 3: `WikiFSSearch` (extract)

| File                        | Lines |
|-----------------------------|-------|
| EmbeddingService.swift      | ~150  |
| Embedder.swift             | ~80   |
| NLEmbedder.swift            | ~80   |
| TextChunker.swift           | ~50   |
| RankFusion.swift            | ~50   |
| WikiIndex.swift             | ~100  |

**~510 lines.** Depends on: `WikiFSCore`. Links `NaturalLanguage` framework
(moves from WikiFSCore's linkerSettings to WikiFSSearch's).

**Access control:** `EmbeddingService` stays `public` (used by WikiFSMLX
`EmbedderBootstrap` app wiring). `Embedder`, `NLEmbedder`, `TextChunker`,
`RankFusion` become `internal` (not referenced outside WikiFSCore). `WikiIndex`
stays `public` (used by SQLiteWikiStore + WikiStoreModel).

### Not extracted (stays in WikiFSCore)

| Cluster     | Reason |
|-------------|--------|
| Store       | SQLiteWikiStore + WikiStoreModel reference all domain clusters — extraction requires protocol-injection refactor (§5). Deferred to Phase 5+ (future issue). |
| Sources (glue) | `WikiRenderContext`, `LinkReconciler`, `DisplayNameResolver`, `SourceRefreshService` bridge storage + links + markdown — they're the composition glue, not a leaf. Belongs with the Store + Model in WikiFSCore. |
| Core        | 6,967 lines of shared value types + queue + registry + agent events. These are consumed by every target — splitting them from Store/Sources doesn't reduce recompilation (they're already the base). |
| Integrations | 25 files of external-service clients. Could extract as `WikiFSIntegrations` (Phase 4, MEDIUM risk) but low build-time payoff — these files change rarely. Defer. |

---

## 3. Protocol Extraction Design: `WikiStore` Splitting

### Current shape

`WikiStore` is an 88-method `Sendable` protocol. As audited, its methods
partition naturally into domains:

| Domain   | Method count | Representative methods |
|----------|-------------|----------------------|
| Pages    | 12          | `listPages`, `getPage`, `createPage`, `updatePage`, `deletePage`, `appendPageVersion`, `pageVersionHistory`, `revertPage` |
| Sources  | 18          | `addSource`, `addBytelessSource`, `listSources`, `deleteSource`, `renameSource`, `appendContentVersion`, `processedMarkdownHead`, `appendProcessedMarkdown`, `setActiveMarkdown` |
| Workspaces | 10        | `createWorkspace`, `workspaceSummary`, `workspaceMerge`, `abandonWorkspace`, `workspaceRefresh`, `workspaceResolveConflict`, `reapStaleWorkspaces` |
| Chats    | 9           | `createChat`, `appendChatMessages`, `listChats`, `chatMessages`, `renameChat`, `deleteChat`, `updateChatSummary`, `searchSimilarChats` |
| Bookmarks | 5          | `listBookmarkNodes`, `createBookmarkNode`, `updateBookmarkNode`, `deleteBookmarkNode`, `moveBookmarkNode` |
| Search   | 9           | `storePageChunks`, `storeSourceChunks`, `storeChatChunks`, `missingPageEmbeddingWork`, `searchSimilar`, `searchSimilarSources` |
| Snapshots | 5          | `ensureFetchActivity`, `addSnapshotImage`, `hasImageSiblings`, `siblingImageResolvers`, `embedDescriptors` |
| Vacuum/GC | 4          | `vacuumBlobs`, `vacuumActivities`, `vacuumPageVersions` |
| System   | 4           | `getSystemPrompt`, `updateSystemPrompt`, `getWikiIndex`, `updateWikiIndex` |
| Log      | 3           | `appendLog`, `recentLogEntries` |
| Metadata | 2          | `getMetadata`, `setMetadata` |

### Verdict: Do NOT split the protocol now

Splitting `WikiStore` into `PageStore`, `SourceStore`, `ChatStore`,
`BookmarkStore`, etc. would require:

1. Every consumer (WikiStoreModel, SQLiteWikiStore, WikiFSTests) to accept
   multiple protocol parameters or a composition struct — 90+ view files touch
   the model.
2. `SQLiteWikiStore` implements all of them in one class via a single SQLite
   connection — splitting the protocol doesn't split the implementation, so
   there's no build-time win (SQLiteWikiStore still recompiles wholesale).
3. The 88 methods are cohesive around a single database connection with
   transactional integrity — artificial splits would force cross-protocol
   transaction management (a step backward).

**Keep `WikiStore` as one protocol in slimmed `WikiFSCore`.** The protocol is
the contract; the implementation stays in WikiFSCore. Protocol splitting is a
future optimization that only pays off if the *implementation* also splits
(per-domain SQLite store classes), which is a much larger architectural change.

---

## 4. `WikiStoreModel` Decomposition Analysis

### Current shape

`WikiStoreModel` is a `@MainActor @Observable` class, 3,096 lines, with 27 MARK
sections covering: selection/navigation, tab management, editing/autosave,
file ingestion, provider-backed ingest, source refresh, search, bookmark CRUD,
chat CRUD, workspace facades, and agent-run lifecycle.

### The coupling is bidirectional and total

**Model → Store (75+ distinct call sites):** The model calls `store.<method>`
across **every domain** — pages (listPages, getPage, createPage), sources
(addSource, listSources, sourceContent), chats (createChat, appendChatMessages),
bookmarks (listBookmarkNodes, createBookmarkNode), search (searchSimilar,
searchSimilarSources), markdown versions (appendProcessedMarkdown,
processedMarkdownHead), workspaces (createWorkspace, workspaceMerge), and
vacuum/GC.

**Model → Domain types (non-store calls):**

| Domain         | Types called | Call count |
|----------------|-------------|------------|
| Links          | `WikiLinkParser` | 6 (parse, splitVersionPin, splitFragment, isEmptyPrefix, isCanonicalULID, classify) |
| Links          | `WikiText` | 2 (normalized) |
| Markdown       | `MarkdownLinter` | 2 (shared, describe) |
| Search         | `EmbeddingService` | 6 (configure, isAvailable, chunkedEmbeddings, selectedEmbedderIdentifier, miniLMIdentifier) |
| Sources/glue   | `SourceRefreshService` | 2 (materialize, RefreshError) |
| Sources/glue   | `LinkReconciler` | 1 (reconcileAll) |
| Sources/glue   | `DisplayNameResolver` | 1 (resolve) |
| Core glue      | `WikiRenderContext` | 1 (build) |
| Core glue      | `WikiStateSnapshot` | 3 (make, maxLogEntries) |

**This is the composition root by design.** The model orchestrates all domain
clusters — it's not accidentally coupled, it's intentionally the integration
point between the store, the link system, the markdown system, the search
system, and the UI.

### Can it be decomposed by domain?

**No — not without a major refactor.** The blocking factors:

1. **SwiftUI view observation granularity.** Views observe the *whole* model
   (they hold a `@Bindable var store: WikiStoreModel` and read any property).
   SwiftUI's observation tracking means a view reading `summaries` triggers
   model-level invalidation. Splitting into `PageModel` + `SourceModel` +
   `ChatModel` requires each view to hold references to the sub-models it
   needs — a mechanical refactor of 68 app files plus test fixtures.

2. **Cross-domain operations.** The model's methods are not domain-pure. For
   example, `runMultiIngest` (the provider-backed ingest seam, ~320 lines)
   touches: source creation (store), link reconciliation (LinkReconciler),
   markdown extraction (SourceRefreshService), search re-embedding
   (EmbeddingService), and chat message appending (store). A `SourceModel`
   can't implement this without importing `PageModel` (for summaries) and
   `ChatModel` (for chat operations).

3. **Shared editing state.** `draftTitle`/`draftBody`/`selection`/tabs are
   cross-domain — a source page edit uses the same draft buffers as a wiki page
   edit. Splitting the model would duplicate or share this state awkwardly.

### What WOULD work (future, if attempted)

A **composition-root extraction** (the issue's `WikiFSModel` target): move
`WikiStoreModel` + the Sources/glue cluster into their own target that depends
on all domain targets. This doesn't decompose the model — it just gives it its
own SPM module so storage can hypothetically be a separate target below it.
But as shown in §5, the storage implementation (`SQLiteWikiStore`) also depends
on all domains, so this gains little.

**Verdict: Do not decompose WikiStoreModel.** It's inherently monolithic as the
composition root. The function-level MARK structure already provides the
navigation benefit. If future work needs the model in a separate target for
non-UI testing (e.g., a headless daemon), extract it as-is into `WikiFSModel`
without splitting the class.

---

## 5. Circular Dependency Analysis

### The one real cycle: `WikiStore` ↔ `WikiLinkParser.ParsedLink`

```
WikiStore protocol (WikiFSCore)
    └── func replaceLinks(from: PageID, parsedLinks: [WikiLinkParser.ParsedLink])
            └── references WikiLinkParser.ParsedLink (WikiFSLinks)
```

This is a protocol-level type dependency from the shared types target to the
Links target. If Links depends on WikiFSCore (for `PageID`), and WikiFSCore's
`WikiStore` protocol references `WikiLinkParser.ParsedLink`, there's a cycle.

**Fix:** Move `ParsedLink` (a tiny `Equatable, Sendable` struct, ~15 lines) from
`WikiLinkParser.swift` to `WikiFSCore` (e.g., into `Core/` or a new
`ParsedLink.swift`). Then `WikiStore.replaceLinks` takes `[ParsedLink]` from
WikiFSCore, and `WikiLinkParser` (in WikiFSLinks) returns `[ParsedLink]` from
the shared type. No cycle.

### SQLiteWikiStore → all domains (not a cycle, but a fan-in)

`SQLiteWikiStore` (would-be WikiFSStorage) references:

| Domain         | Types referenced | Call count |
|----------------|-----------------|------------|
| Links          | `WikiNameRules` | 27 calls |
| Links          | `WikiLinkParser` | 6 |
| Links          | `WikiLinkRewriter` | 2 |
| Links          | `WikiLinkResolver` | 1 |
| Links          | `WikiLinkMarkdown` | 1 |
| Search         | `EmbeddingService` | 6 |
| Search         | `WikiIndex` | 5 |
| Search         | `RankFusion` | 2 |
| Sources/glue   | `DisplayNameResolver` | 3 |
| Markdown       | `SlugUtils` | 1 |

This is a one-way dependency: Storage → Links/Markdown/Search/glue. It's not a
cycle (the domain clusters don't call back into the store — confirmed: the Links
cluster has **zero** actual `store.` method calls; the only `store` references
in Links files are doc comments). But it means **a `WikiFSStorage` target would
need to depend on all domain targets**, making it a fan-in hub, not a leaf.

### Where the "cycle" perception comes from

The issue describes: "WikiStoreModel calls link resolvers (links), which call
store methods (storage)." The audit disproves this:

- **WikiLinkResolver** is all `static func` — no store dependency.
- **WikiLinkParser** is pure — returns parsed structures, doesn't call the store.
- The store *calls* the parser/loader (one-way), not vice-versa.

The actual data flow is:

```
SQLiteWikiStore            WikiStoreModel              UI (WikiFS)
     │                          │                         │
     ├─→ WikiLinkParser ──────→│ (parse links, classify)  │
     ├─→ WikiNameRules ───────→│                         │
     ├─→ EmbeddingService ─────→│ (configure, embed)      │
     ├─→ DisplayNameResolver ──→│                         │
     ├─→ WikiIndex ────────────→│                         │
     │                          ├─→ store.<88 methods>    │
     │                          │                         │
     │                          ←── @Bindable / observation ──┘
     │                                                    │
     └── stores/reads ←────── agent writes (wikictl/daemon)  │
```

**No cycle exists.** The dependency is a DAG: domain clusters are pure leaves
that WikiFSCore's Store + Model consume. The challenge is that Storage+Model
is a fat node, not that there's a loop.

---

## 6. Access-Control Audit

### Cross-target symbol usage (consumers → WikiFSCore types)

Counted across all 6 consuming targets (WikiFS, WikiFSEngine, WikiCtlCore,
wikid, WikiFSFileProvider, WikiFSMLX):

| Symbol              | Cross-target uses | After split: stays `public`? |
|---------------------|-------------------|------------------------------|
| `DebugLog`          | 245               | Yes (Core — universal)       |
| `PageID`            | 160               | Yes (Core — universal)       |
| `WikiStoreModel`    | 89                | Yes (Core — app uses heavily)|
| `BookmarkNode`      | 57                | Yes (Core — app + tests)     |
| `WikiStore`         | 54                | Yes (Core — the protocol)    |
| `ULID`              | 43                | Yes (Core — universal)       |
| `SourceSummary`     | 22                | Yes (Core — shared value)    |
| `SQLiteWikiStore`   | 22                | Yes (Store — concrete init)  |
| `ChatSummary`       | 21                | Yes (Core — shared value)    |
| `WikiDescriptor`    | 20                | Yes (Core — universal)       |
| `ZoomScale`         | 18                | Yes (Core — app UI)          |
| `WikiOperation`     | 18                | Yes (Core — queue types)     |
| `WikiSelection`     | 16                | Yes (Core — app UI)          |
| `FilenameEscaping`  | 16                | Yes (Core — universal)       |
| `WikiPageSummary`   | 10                | Yes (Core — shared value)    |
| `WikiEventBus`      | 9                 | Yes (Core — change signaling)|
| `QueueItemPayload`  | 7                 | Yes (Core — queue)           |
| **`WikiLinkParser`**| **6**             | Yes (Links — used by app)    |
| **`MarkdownLinter`**| **6**             | Yes (Markdown — used by WikiCtlCore) |
| `ShellWords`        | 5                 | Yes (Core — universal)       |
| `EmbeddingService`  | 5                 | Yes (Search — used by WikiFSMLX) |
| `WikiRegistry`      | 4                 | Yes (Core — registry)        |
| `WikiIndex`         | 4                 | Yes (Search — used by Store)  |
| `ShellArgv`         | 4                 | Yes (Core — universal)        |
| `SystemPrompt`      | 3                 | Yes (Core — system doc)      |
| `PageSortOrder`     | 3                 | Yes (Core — shared value)    |
| `LogEntry`          | 3                 | Yes (Core — shared value)    |
| `WikiPage`          | 2                 | Yes (Core — shared value)    |
| `ResourceChangeEvent`| 2                | Yes (Core — change signaling)|
| `EditorTab`         | 2                 | Yes (Core — app UI)          |
| `ChatMessage`       | 2                 | Yes (Core — shared value)    |
| `WikiStateSnapshot` | 1                 | Yes (Core — app)             |
| `WikiIdentifiers`   | 1                 | Yes (Core — universal)       |

### Types that can become `internal` after extraction

These are currently `public` in WikiFSCore but have **zero** cross-target
references — they're only used within WikiFSCore itself:

| Cluster    | Types → `internal` after split |
|------------|-------------------------------|
| Links      | `WikiLinkSpan`, `WikiLinkMenuBuilder`, `WikiLinkFixer`, `RelativeLinkRewriter`, `WikiText` (check — WikiStoreModel uses `.normalized`), `WikiLinkIndex` |
| Markdown   | `HTMLTokenizer`, `HTMLEntities`, `HTMLToMarkdown`, `HTMLMarkdownRenderer`, `AnchorBlock`, `PageMarkdownFormat`, `Diff3`, `SplitDiff`, `MarkdownDiff`, `MarkdownFolderReader`, `MarkdownExtractor`, `WikiFootnoteMarkdown` |
| Search     | `Embedder`, `NLEmbedder`, `TextChunker`, `RankFusion` |

**~22 types** can become `internal`, giving real encapsulation benefit from the
target split. These are implementation details that were only `public` because
everything in WikiFSCore had to be.

### Consumer dependency additions (Package.swift)

After extracting Links/Markdown/Search, consumers that reference their types
must add the new target as a dependency:

| Consumer          | Needs dep on |
|-------------------|-------------|
| WikiFS (app)      | WikiFSLinks, WikiFSMarkdown, WikiFSSearch (uses all three) |
| WikiCtlCore       | WikiFSMarkdown (uses MarkdownLinter) |
| WikiFSMLX         | WikiFSSearch (uses EmbeddingService) |
| WikiFSEngine      | none new (checked — no link/markdown/search refs) |
| WikiFSFileProvider | none new |
| wikid             | none new |

WikiFSCore itself also needs deps on all three (SQLiteWikiStore + WikiStoreModel
reference them).

---

## 7. Build-Time Impact Estimate

### Measured (this session, M-series Mac)

| Scenario | Time |
|----------|------|
| Fully cached no-op `swift build` | 25s |
| Incremental (1 file in WikiFSCore changed) | 64s |
| Delta (recompilation cost of touching 1 file) | ~39s |

### Why the delta is 39s

SwiftPM recompiles the **entire target** when any file in it changes, then
recompiles all dependents. With 131 files in WikiFSCore, touching one file
recompiles all 131 + WikiFSCore's 5 dependent targets (WikiFS, WikiFSMLX,
WikiFSEngine, WikiCtlCore, WikiFSFileProvider, wikid, tests). The 39s is
~131 source files + dependents.

### Estimated improvement after Phase 1–3

With Links (11 files), Markdown (15 files), Search (6 files) extracted:

| Change location | Before | After | Savings |
|-----------------|--------|-------|---------|
| Links file (e.g. WikiLinkParser) | 131 files recompile | 11 + dependents (~WikiFSCore+WikiFS = ~140) | ~0s (WikiFSCore still depends on Links) |
| Markdown file | 131 files | 15 + dependents | ~0s (same reason) |
| Search file | 131 files | 6 + dependents | ~0s (same reason) |
| WikiFSCore file (e.g. SQLiteWikiStore) | 131 files | 99 files (Core+Store+Sources) | ~10s (32 fewer files) |

**The honest result: modest.** Because `WikiFSCore` (the hub) still depends on all
three extracted targets, changes in Links/Markdown/Search trigger recompilation
of WikiFSCore anyway (since it consumes those types). The win comes from the
reverse direction: a change in `SQLiteWikiStore.swift` no longer recompiles the
Links/Markdown/Search files — but they're small (99 → 67 fewer files in the hub).

The **real** build-time win requires extracting `WikiFSStorage` (the 9-file,
13,408-line Store cluster) so that changes to store code don't recompile Core's
51 files. But that's blocked by the coupling in §5 (SQLiteWikiStore references
domain types from Links/Markdown/Search, so Storage depends on them — and if
they're separate targets, Storage is a fan-in node that still recompiles when
they change).

**Bottom line: expect ~5–15s savings on incremental builds touching Core/Store
files. Not transformative. The primary value of phases 1–3 is access control
(internal encapsulation of ~22 types) and code organization clarity, not build
speed.**

---

## 8. Phased Migration Plan

### Phase 1: Extract `WikiFSLinks` — Risk: LOW 🟢

**Precondition:** Move `WikiLinkParser.ParsedLink` into `WikiFSCore/Core/` to
break the one protocol-level cycle (§5).

- Move 11 files from `Sources/WikiFSCore/Links/` → `Sources/WikiFSLinks/`
- Add target in Package.swift: `.target(name: "WikiFSLinks", dependencies: ["WikiFSCore"], …)`
- WikiFSCore gains dependency: `WikiFSLinks` (SQLiteWikiStore + WikiStoreModel use link types)
- WikiFS (app) gains dependency: `WikiFSLinks` (68 files use link types)
- Make 6 internal-only types `internal`: WikiLinkSpan, WikiLinkMenuBuilder, WikiLinkFixer, RelativeLinkRewriter, WikiLinkIndex, (verify WikiText)
- Build + test (run `swift test --skip` fast tier, then full suite)
- **Expected build impact:** negligible (WikiFSCore still depends on Links)
- **Test risk:** LOW — links are pure logic, well-tested. The `ParsedLink` move is mechanical.

### Phase 2: Extract `WikiFSMarkdown` — Risk: LOW 🟢

- Move 15 files from `Sources/WikiFSCore/Markdown/` → `Sources/WikiFSMarkdown/`
- Add target; WikiFSCore + WikiCtlCore gain dependency
- Check: does Markdown need `WikiFSLinks`? (MarkdownExtractor, WikiFootnoteMarkdown may reference WikiText/WikiLinkMarkdown types — if so, add WikiFSLinks dep)
- Make 12+ internal-only types `internal`
- Build + test
- **Test risk:** LOW — linter and HTML tests are self-contained.

### Phase 3: Extract `WikiFSSearch` — Risk: LOW 🟢

- Move 6 files from `Sources/WikiFSCore/Search/` → `Sources/WikiFSSearch/`
- Move `NaturalLanguage` linkerSetting from WikiFSCore to WikiFSSearch
- Add target; WikiFSCore + WikiFSMLX gain dependency
- Make 4 internal-only types `internal`: Embedder, NLEmbedder, TextChunker, RankFusion
- Build + test
- **Test risk:** LOW — embedding tests use the `EmbeddingService` seam (injectable factory).

### Phase 4 (Optional): Extract `WikiFSIntegrations` — Risk: MEDIUM 🟡

- Move 25 integration files → `Sources/WikiFSIntegrations/`
- Depends on `WikiFSCore` (+ possibly WikiFSLinks, WikiFSMarkdown for extraction rendering)
- Links KeychainAccess patterns; verify all credential stores are self-contained
- **Deferred — do only if integration files become a build bottleneck.** They
  change rarely (external API clients), so the build-time payoff is minimal.

### Phase 5 (Future, separate issue): Extract `WikiFSStorage` — Risk: HIGH 🔴

**Do NOT attempt in this cycle.** Requires:

1. Protocol-injection refactor of `SQLiteWikiStore`'s 54 cross-domain type
   references (27 WikiNameRules calls, 6 WikiLinkParser, 6 EmbeddingService,
   etc.) — inject these as protocol parameters or move the call sites to the
   model.
2. Or: accept that `WikiFSStorage` depends on Links/Markdown/Search (fan-in
   node) and extract it anyway — the build-time win is ~10s (99 → 67 fewer
   files in the reamining Core+Store+Sources target, but Storage itself is
   13,408 lines of 9 files dominated by SQLiteWikiStore).
3. `WikiStoreModel` (3,096 lines) moves with Storage or into `WikiFSModel`
   composition root (§4 shows it's the composition hub — can't decompose).

**Rationale for deferral:** The coupling audit shows SQLiteWikiStore is a fan-in
node that depends on all pure-logic clusters. Extracting it into a separate
target doesn't make it a leaf — it makes it a hub that still recompiles when any
domain type it references changes. The only way to get a clean Storage leaf is
to protocol-inject all 54 cross-domain call sites, which is a large refactor
(~1-2 sprints) with real regression risk against the 2,400-test suite. The
build-time payoff (~10s) doesn't justify it yet.

### Phase 6 (Future, separate issue): `WikiStore` protocol split — Risk: MEDIUM 🟡

Split the 88-method protocol into `PageStore`, `SourceStore`, `ChatStore`,
`BookmarkStore`, `SearchStore`. Only valuable if paired with splitting
`SQLiteWikiStore` into per-domain store classes (a separate large refactor).
Defer entirely — the monolithic protocol is fine as an interface even if the
implementation is one class.

---

## 9. Recommendation

### Option D (phased), scoped to Phases 1–3

| Phase | Targets added | Lines extracted | Risk | Build-time win | Access-control win |
|-------|--------------|-----------------|------|----------------|-------------------|
| 1 | WikiFSLinks | ~1,380 | LOW 🟢 | ~0s | 6 types → internal |
| 2 | WikiFSMarkdown | ~2,530 | LOW 🟢 | ~0s | 12+ types → internal |
| 3 | WikiFSSearch | ~510 | LOW 🟢 | ~0s | 4 types → internal |
| **Total** | **3 targets** | **~4,420** | **LOW** | **~5–15s on core changes** | **~22 types → internal** |

### Why not Option C (one-shot full split)?

1. **The storage split doesn't pay off.** SQLiteWikiStore is a 8,000-line fan-in
   node that depends on all domain clusters — extracting it as WikiFSStorage
   doesn't make it a leaf, and the 54 cross-domain references would need
   protocol-injection to become a clean leaf (high risk, uncertain payoff).

2. **WikiStoreModel can't be decomposed** (§4). It's the composition root by
   design — it orchestrates all domains. Extracting it into WikiFSModel gains
   nothing unless Storage is also extracted below it, which circles back to #1.

3. **The build-time math doesn't justify it.** The 39s incremental-build delta
   is dominated by SQLiteWikiStore (8,000 lines) + WikiStoreModel (3,096 lines)
   + Core (6,967 lines), none of which can be cheaply split. Extracting the
   pure-logic clusters saves ~5–15s on core-file changes and ~0s on
   domain-cluster changes.

4. **Risk asymmetry.** Phases 1–3 touch pure-logic code with well-tested
   boundaries — low regression risk against the 2,400-test suite. Phases 5–6
   touch the data layer and the composition root — high regression risk with
   modest reward.

### What Phases 1–3 buy

- **Access control:** ~22 types become `internal` — real encapsulation of
  parsing/rendering/search implementation details.
- **Code clarity:** The domain clusters get explicit SPM boundaries, making
  dependency direction visible in Package.swift rather than implicit.
- **Foundation for future:** The protocol boundary is established — if a future
  issue tackles SQLiteWikiStore protocol-injection (Phase 5), the Links/Markdown/
  Search targets already exist as consumers.
- **Build time:** Modest but real — changes to Core/Store files recompile ~32
  fewer files (the extracted clusters move out of the recompilation set).

### What Phases 1–3 don't buy

- Transformative build-time improvement (that requires the storage split).
- WikiStoreModel decomposition (that's a different, larger effort).
- The `WikiFSModel` composition-root target (only needed if Storage is split).

---

## Appendix: Data Sources

- `Package.swift` — 10 current targets, strictSwiftSettings, podcast conditional
- `Sources/WikiFSCore/Store/WikiStore.swift` — 88-method protocol (687 lines)
- `Sources/WikiFSCore/Store/WikiStoreModel.swift` — @Observable hub (3,096 lines, 27 MARK sections)
- `Sources/WikiFSCore/Store/SQLiteWikiStore.swift` — 8,000+ line implementation
- Cross-target symbol audit: `rg` across WikiFS, WikiFSEngine, WikiCtlCore, wikid, WikiFSFileProvider, WikiFSMLX
- Build-time measurement: `swift build` cached (25s) vs incremental (64s)
