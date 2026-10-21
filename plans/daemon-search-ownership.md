# Daemon-owned search

## Ownership

The daemon owns one persistent Tantivy runtime per wiki. The app uses embedded XPC. Standalone `wikictl` uses a search-only Unix socket in the App Group container. Both transports call the same runtime. Neither client opens a Tantivy writer or creates a temporary index.

Embedded XPC lookup is relative to the calling app bundle. It does not let the standalone CLI reach the host app's service. The CLI must not use `NSXPCConnection(serviceName:)` for this connection.

The runtime uses the existing `search-index/<wikiID>` location. SQLite remains the source of truth. The daemon builds a missing index before it admits a query.

Search and autocomplete use the same owner. Concurrent requests share startup and cannot create competing writers. Closing or deleting a wiki must release its runtime before database or index cleanup.

## Freshness

App and CLI writes can occur in other processes, so an in-process event bus cannot establish freshness.

Before a query, the owner checks the store change token. It must synchronize changed content before it returns results. Synchronization must not overlap another synchronization or expose a partially rebuilt index. A failed synchronization fails the query.

## Transport and failures

The XPC contract uses versioned request and reply values. Requests carry the wiki identity, operation, query, document kinds, and result limit. Replies distinguish ranked hits from an infrastructure failure.

The client bounds each request with a timeout. Connection failure, unsupported protocol versions, malformed replies, startup failure, and query failure remain errors. The CLI exits nonzero and writes a diagnostic to stderr. A successful empty result remains a normal no-match response.

There is no local-index fallback. A fallback would create another writer or hide a failed search service.

## Index recovery

A writer-lock failure does not prove corruption. Index opening errors propagate without deleting files. Rebuilds use an acquired writer. No recovery path removes a shared index because a reader or writer could not open it.

## Verification

Required cases include concurrent cold requests, page/source/chat filtering, autocomplete, writes from another SQLite connection, failure propagation, and owner shutdown. Transport tests cover timeouts and malformed replies. Sandbox tests verify that search does not require index write permission.
