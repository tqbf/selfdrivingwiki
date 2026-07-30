---
timestamp: 2026-07-30T18:47:59Z
title: Chat presentation Phase 2 durable transcript identities
branch: chat-presentation-diagnostics-phase2
status: complete
---

# Chat presentation Phase 2 durable transcript identities

## Progress

Added durable IDs for system notices and turn failures.

Added GRDB migration v47. It rewrites legacy transcript JSON in one transaction.

Added a strict leaf decoder. Store and wire adapters repair legacy payloads with typed context.

Added active content-block metadata to projection snapshots and compact updates.

The client keeps active metadata only when a matching typed message exists.

## Verification

Passed `make build`.

Passed `swift test --filter 'ChatPhase2PersistenceTests|ChatSyncWireTests|ChatClientSyncReducerTests'`.

Passed `make test`.

The hosted AppKit gate did not run. This slice changes persistence, sync, and daemon code only.
