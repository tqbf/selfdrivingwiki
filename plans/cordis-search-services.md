# Cordis Search Services

**Status:** Implemented

## Purpose

The app owns one private search root context. Each live wiki uses one child context under that root.

The CLI uses a separate request root and one child for each distinct in-flight search. Identical CLI requests share one task.

SQLite remains authoritative. The Tantivy index remains a derived artifact that the runtime can delete and rebuild.

## Public facade

`SearchServices` is a `Sendable` protocol in `WikiFSSearch`. It supports free-text search and fuzzy title autocomplete.

Consumers receive `SearchServices` only. The facade returns `TantivyShadowSearchResult` values in best-first order.

`MutableSearchServices` provides a stable facade during asynchronous startup. Installation tokens prevent late publication after shutdown.

The facade reports typed unavailable and disposed errors. Application and CLI boundaries map these errors to a missing BM25 leg.

## Service graph

`SearchRuntimeAssembly` registers these fixed labels:

| Label | Value |
| --- | --- |
| `search.identity` | The immutable wiki ID and index directory |
| `search.content-source` | The typed Tantivy snapshot gateway |
| `search.change-stream-factory` | The single-consumer event stream factory |
| `search.indexer` | The per-wiki `TantivyIndexer` actor |
| `search.runtime` | The lifecycle and synchronization actor |
| `search.services` | The public `SearchServices` facade |

Each component declares all dependencies. Each activation resolves its dependencies with `ActivationContext.require`.

Cordis controls activation order. Component registration order does not control activation order.

## Startup and synchronization

`WikiSession` subscribes to its `WikiEventBus` before asynchronous child assembly starts. The gateway buffers events until the runtime takes the stream.

The runtime checks the rebuild marker and the index count. It rebuilds from committed SQLite state when required.

The runtime then applies all buffered events in order. It starts one owned live event task before it admits queries.

The runtime uses each event sequence as an integrity check within one bus lifetime. A gap or regression forces a full rebuild.

Page, source, and chat create or update events cause an upsert. Matching delete events remove one document.

A coarse event causes a full rebuild. Bookmark, system prompt, wiki index, and log events do not change Tantivy.

## Process ownership

`SearchRuntimeRegistry` owns the private app root context. It creates one child for each admitted wiki.

The registry serializes replacement for one wiki ID. A different wiki can start while the first wiki stops.

`SearchCompositionOwner` owns one startup task and one stable facade. It cancels and awaits startup during shutdown.

`SessionManager` owns session release tasks. App termination awaits all releases before it disposes the search root.

The CLI creates one private request root and one child. It disposes the child before the request root on every exit path.

## Lifecycle

Runtime disposal stops query admission first. It cancels and awaits the event task, then terminates the stream subscription.

Stream termination unsubscribes from the bus exactly once. Repeated disposal is safe.

A disposed runtime rejects later search and autocomplete operations. Search assembly failure does not stop session creation or unrelated features.

## Scope limits

These values stay outside Cordis:

- `WikiStore` and `WikiEventBus`;
- SQLite and GRDB connections, statements, transactions, and read pools;
- `WikiStoreModel`, `WikiSession`, and `SessionManager`;
- SwiftUI views and UI state;
- active queries and result catalogs;
- queue, File Provider, XPC, and transport owners.

The graph receives only typed `Sendable` gateways. The public facade never exposes a context, service key, store, bus, or database handle.

## Compatibility

The migration preserves the index path `<container>/search-index/<wikiID>/`.

It preserves BM25 ranking, fuzzy prefix autocomplete, kind filters, limits, empty-input behavior, and best-first result order.

It preserves rebuild-marker recovery and cross-process coarse-event recovery. Linux keeps the unavailable facade and no Tantivy child activation.
