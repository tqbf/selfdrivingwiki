---
timestamp: 2026-08-19T19:45:00Z
title: Cordis search services
branch: feature/cordis-search-runtime
status: implementation
---

# Cordis Search Services Progress

**Date:** 2026-08-19

## Progress

The migration added `SearchServices`, `MutableSearchServices`, and typed search lifecycle errors to `WikiFSSearch`.

`SearchRuntimeAssembly` now composes six fixed services in a private Cordis child context. Registration order does not control activation order.

`SearchRuntime` owns initial rebuilds, buffered event catch-up, live event processing, query admission, and disposal.

`SearchRuntimeRegistry` owns one private app root. It serializes replacement for one wiki and permits independent work for different wikis.

`SearchCompositionOwner` owns asynchronous child startup. `SessionManager` owns release tasks and awaits them during app termination.

`WikiSession` and `WikiStoreModel` now receive only the stable search facade. They no longer construct or expose a Tantivy service.

`CLITantivyLegResolver` now uses the shared assembly. Each distinct in-flight request owns one private root and child.

The old `TantivyShadowSync` detached-task lifecycle was removed. Search lifecycle files contain no detached tasks.

## Preserved behavior

SQLite remains authoritative. The index path and Tantivy schema did not change.

Search keeps BM25 ranking, fuzzy prefix matching, kind filters, limits, and best-first result order.

Unavailable search remains fail-soft. Semantic search and unrelated session features remain available.

## Verification

The engine, app, and CLI targets compile with SwiftPM.

Focused runtime assembly, policy, BM25, session, and existing portable regression tests pass.

The remaining delivery gates are the opt-in app search tests, full build and test runs, reviews, and pull request creation.
