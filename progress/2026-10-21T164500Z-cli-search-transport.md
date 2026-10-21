---
timestamp: 2026-10-21T164500Z
title: Correct standalone CLI search transport
branch: bugfix/concurrent-cli-search
status: complete
---

# Correct standalone CLI search transport

## Progress

- Read the latest retry in chat `01M5EBKEHSASW2G0RKTW5EY9T1`.
- Confirmed the installed CLI is build `1232-9f7e94b1`.
- Reproduced search failure with XPC error 4099, lookup error 3, while the app-owned daemon runs.
- The first daemon migration incorrectly used embedded XPC lookup from the standalone CLI.
- `plans/xpc-service-migration.md` documented the restriction; the tests injected transport fakes and never exercised the real CLI boundary.
- Added a search-only Unix socket into the existing daemon: `SearchSocketWire` (framing, path-length guard, error taxonomy), `DaemonSearchSocketServer` (flock guard, same-user gate, per-phase deadlines), `DaemonSearchSocketClient` (fresh connection per request, fail-fast mapping).
- The app keeps XPC; the CLI uses the socket; both call the same daemon-owned search runtime. No local fallback.
- Fixed compile issues en route: a toolchain crash on a `DispatchSourceProtocol` ternary, checked-continuation overload ambiguity (switched to the unsafe variant; the box guarantees resume-at-most-once), missing awaits, and async-unsafe locking (split a synchronous phase-transition helper).
- Assembled `plans/cli-domain-commands.md`: the plan for routing every `wikictl` command through the daemon on this transport.

## Verification

- `make build` passed and assembled the signed app; `make install` installed it.
- `make test` passed (10 suite runs, zero failures), including 62 focused tests: socket round trips, concurrent clients, error paths, guard flock, permissions, daemon ownership, freshness, lifecycle, transport timeouts, safe index opens.
- Live, against the real wiki: bundled `wikictl` (installed app running) `page/source/chat search --query Ironworkers` returned 10/10/1 hits with exit 0 — the exact queries that reported false zero results.
- Live, app quit: the same command exited 1 in under a second with an explicit `daemonNotRunning` diagnostic naming the socket path.
