---
timestamp: 2026-10-24T054900Z
title: Restore semantic search in the wiki daemon
branch: bugfix/issue-1474-activate-wikid-semantic-search
status: in-progress
---

# Restore semantic search in the wiki daemon

## Progress

The daemon installed an unavailable embedding provider. The store then skipped cosine search because it had no query embedder. The embedding loader also rejected the daemon's `.xpc` bundle.

The daemon now installs the MiniLM factory and loads the embedder before it opens a wiki store. The build copies the model and Metal library into the daemon bundle. The store records why it skips cosine search when a query vector is unavailable.

Removed the unused Natural Language embedder and its startup fallback. MiniLM is now the only runtime embedder. A host without the model keeps its stored vectors. The database keeps the old `nlembedding-512` value so it can detect and replace old 512-dimensional vectors when MiniLM starts.

## Verification

`make build` passed. The signed `wikid.xpc` contains the MiniLM model, Metal library, and loader symlink. The 16 focused bundle, plugin, and semantic search tests passed. After the fallback removal, `make build` passed and 13 focused bundle, plugin, chunking, and migration tests passed.

The final `make test` run passed. Earlier full test runs stopped in SwiftPM's test helper after the core test process exited.
