---
timestamp: 2026-10-03T181739Z
title: Daemon registry refresh
branch: feature/wiki-strategies-cumulative-ingestion
status: implemented
---

# Daemon registry refresh

## Progress

### Cause

Debug logs showed that the Ingest button reached the enqueue path, but the daemon rejected the wiki.
The app created the wiki after the daemon started. The daemon still used its startup registry.
The custom strategy was not the cause. Strategy capture occurs after enqueue.

### Changes

Registry-dependent daemon operations now read the disk registry before they act.
They adopt new and changed descriptors. They reject deleted wikis and release their cached services and chat hosts.
Service admission and chat-host installation check the registry again after asynchronous preparation.
Preparation epochs reject installations that overlap teardown.
Deletion cleanup does not wait on the chat creation gate, which prevents a self-deadlock.
Cleanup removes database artifacts that a startup race could recreate.

A strict registry read distinguishes corrupt data from an empty registry.
A missing registry file counts as unreadable once the daemon knows wikis or holds services.
Already-serving wikis remain available through an unreadable registry. New admissions fail with a distinct error.
An existing empty registry file still represents deletion of all wikis.

Queue error logs now retain the wire error code and message.
The daemon also records the underlying error before it sends a failure response.

No global cross-process file lock protects registry reads and database opens.
Deletion after a successful boundary check takes effect at the next registry-dependent operation.
The tests cover deletion during preparation and before chat-host installation.

## Verification

All fixtures use disposable project directories. Investigation read the reported source and wiki without changing their data.
No paid ingestion ran against the user's source.

- Workload-host tests passed: 28 tests in two suites. Log: `tmp/test-boundary.log`.
- Tests cover creation after startup, rename, deletion, deletion after list refresh, cached chat access, and startup races.
- Registry-client tests passed: 26 tests in two suites. Log: `tmp/test-boundary2.log`.
- `make build` produced a signed app. Log: `tmp/make-build.log`.
- The collateral run reported eight issues in five existing `DaemonChatHostTests` tests.
  The same failures occurred on clean HEAD during the earlier comparison. This run is not a full-suite pass.
- The feature's template-menu workflow, live human rubric, and independent review remain unresolved.

The app still reports enqueue failures through debug logs rather than a user-visible alert.
