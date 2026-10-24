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

## Verification

`make build` passed. The signed `wikid.xpc` contains the MiniLM model, Metal library, and loader symlink. The 16 focused bundle, plugin, and semantic search tests passed.

The full `make test` run and a bare `swift test` run both stopped making progress in SwiftPM's test helper. Each helper remained alive after its core test process exited, with no assertion failure in the log. The full suite remains unverified locally.
