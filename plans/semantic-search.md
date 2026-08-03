# Semantic Search

Semantic (meaning-based) search over wiki pages, running entirely inside SQLite
so ranked results stay out of the model's context window.

## Architecture

```
User types query in sidebar
  → WikiStoreModel.searchQuery (debounced 300ms)
  → SQLiteWikiStore.searchSimilar(query:limit:)
  → EmbeddingService.embeddingBlob(for: query)   // NLEmbedding, 512-dim Float32
  → SELECT … ORDER BY vec_distance_cosine(pe.embedding, ?) ASC LIMIT ?
  → ranked [WikiPageSummary] → SidebarView renders

Claude runs wikictl search --query "…"
  → PageCommand.run(.search)
  → WikiStore.searchSimilar(query:limit:)
  → TSV output: id\ttitle
```

## Components

| Component | File | Role |
|---|---|---|
| sqlite-vec dylib | `Resources/vec0.dylib` | Pre-built loadable extension (macOS arm64). Loaded at DB-open via `dlsym` because Apple's Swift SQLite3 module omits `sqlite3_load_extension`. |
| `EmbeddingService` | `Sources/WikiFSCore/EmbeddingService.swift` | Wraps Apple `NLEmbedding.sentenceEmbedding(for: .english)`. Converts `[Double]` → `[Float32]` → `Data` BLOB (2048 B). |
| `page_embeddings` table | v7 migration in `SQLiteWikiStore.swift` | `page_id TEXT PK REFERENCES pages(id) ON DELETE CASCADE, embedding BLOB NOT NULL`. |
| Store protocol methods | `WikiStore.swift` | `storePageEmbedding(id:blob:)`, `searchSimilar(query:limit:)`, `recomputeMissingEmbeddings()`. |
| vec extension loading | `SQLiteWikiStore.swift` | `ensureVecExtensionLoaded()` — finds dylib in bundle (production) or walks up from build dir (dev). `loadVecExtension(on:)` — per-connection load via `dlsym`. |
| Embedding at save | `PageUpsert.swift` | After `writePage()` + `replaceLinks()`, computes embedding via `EmbeddingService` and stores it. Non-fatal (`try?`). |
| Search state | `WikiStoreModel.swift` | `searchQuery` (didSet → scheduleSearch), `searchResults`, 300ms debounce. `recomputeMissingEmbeddings()` forwarding. |
| Search bar | `SidebarView.swift` | Magnifying glass + `TextField` in Pages section. Shows `searchResults` when query non-empty, `summaries` otherwise. "No matching pages" when empty. |
| Reindex button | `SidebarView.swift` toolbar | "Reindex Search" → `store.recomputeMissingEmbeddings()` for pre-v7 pages. |
| `wikictl search` | `ArgumentParser.swift`, `PageCommand.swift`, `main.swift` | CLI semantic search: `wikictl search --query "…" [--limit N]`. Outputs TSV. |
| System prompt | `SystemPrompt.swift` | Documents `wikictl search` in tooling reference; Query workflow uses it first. |
| Build | `build.sh` | Copies `vec0.dylib` → `Contents/Helpers/`, signs it (real + ad-hoc). |

## Fallback

When vec0.dylib is absent (test environment, not yet bundled) or NLEmbedding is
unavailable (macOS < 15), `searchSimilar()` falls back to `WHERE title LIKE ?`.
The feature is never a hard dependency — search always returns something.

## Test coverage

- `SQLiteWikiStoreTests`: v7 schema, storePageEmbedding insert/replace,
  recomputeMissingEmbeddings count
- Updated migration tests (version 6 → 7)
- Updated pragmasAndSchema (version 6 → 7, +page_embeddings table)
