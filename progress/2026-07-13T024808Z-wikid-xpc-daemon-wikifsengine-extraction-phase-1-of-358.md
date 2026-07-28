---
timestamp: 2026-07-13T024808Z
title: "2026-07-12 — wikid XPC daemon + WikiFSEngine extraction (Phase 1 of #358)"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-07-12 — wikid XPC daemon + WikiFSEngine extraction (Phase 1 of #358)

## Progress


**All three phases of the multi-wiki daemon plan are implemented.** The design
doc lives at `plans/multi-wiki-daemon.md`; the architecture-roadmap §4 fork is
resolved (daemon-first path chosen).

**Phase 1A: WikiFSEngine extraction (PR #369, merged).** Extracted the agent
execution engine out of the app target into a new `WikiFSEngine` library. Both
the app and the future daemon link it. 14 files moved
(`Sources/WikiFS/` → `Sources/WikiFSEngine/`): `AgentLauncher`, `ACPBackend`,
`ClaudeCLIBackend`, `AgentOperationRunner`, `GenerationGate`,
`ExtractionCoordinator`, `AgentBackend`/`Factory`, `OperationRequest`,
`ACPPermissions`, `PermissionResolving`, `NotificationFanout`,
`TurnLivenessPolicy`, `ACPAuthResolver`. Protocol seams introduced
(`EngineProtocols.swift`): `ChangeSignaler` (abstracts `FileProviderSpike`),
`UnavailablePdf2MarkdownExtractor` (placeholder for the
`localExtractorFactory` injection). `AgentOperationRunner` signatures changed:
`manager: WikiManager` → `wikiID: String`, `fileProvider: FileProviderSpike` →
`changeSignaler: any ChangeSignaler`, `HelpersLocation.wikictlDirectory` →
`wikictlDirectory: String` (injected). `ExtractionCoordinator`+`AgentLauncher`
gained factory closures for `PdfExtractionService`/`LocalPdf2MarkdownExtractor`
(which stay in the app target — AppKit-coupled). `FileProviderSpike` conforms to
`ChangeSignaler`. All 8 app call sites updated. Fast tier: 2354 tests pass.

**Phase 1B: wikid XPC daemon (PR #370, merged).** New `wikid` executable target
linking `WikiFSCore`. `WikiDaemonProtocol` (`@objc`, JSON-in-`Data` transport)
in `WikiFSCore` — shared by daemon + clients. `WikiDaemon` holds live
`WikiRegistry` in-memory (not load-mutate-save per op), holds open
`SQLiteWikiStore` instances (Sendable, method-atomic), serializes mutations on a
`DispatchQueue`, seeds a Home page on `createWiki`. `main.swift`:
`NSXPCListener(machServiceName:)` + `RunLoop.current.run()`. launchd plist
(`signing/com.selfdrivingwiki.wikid.plist`) with `MachServices`, `RunAtLoad`,
`KeepAlive`, `IdleTimeout=300s`. Makefile targets: `install-daemon` /
`uninstall-daemon` / `daemon-status`.

**Phase 1C: wikictl as first XPC client (PR #370, merged).**
`WikiDaemonConnection` (in `WikiCtlCore`) — thin async XPC client,
JSON encode/decode of `WikiDescriptor` over `Data`. `wikictl main.swift`:
`run()` is now async; wiki resolution tries the daemon first, falls back to
direct `WikiResolver` if the daemon isn't running (graceful degradation). Four
new `wikictl wiki` subcommands: `list` / `create --name` / `delete --id` /
`rename --id --name`, all routed through the daemon via XPC. Store writes still
direct (`SQLiteWikiStore`) — "sole writer" deferred to Phase 2+ (decision D4).

**What does NOT change:** the app stays in-process (`WikiManager` untouched);
the File Provider extension reads SQLite directly; store writes from `wikictl`
open their own `SQLiteWikiStore` (WAL + method-atomic store handles
multi-writer); Darwin notification routing unchanged; all SQLite concurrency
invariants preserved (`mutate()` write-seam, `StoreEmissionExhaustivenessTests`,
`WikiReadPool` read-only connections).

## Verification

Historical verification remains in the progress record above.
