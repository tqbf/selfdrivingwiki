# Cordis Full-Architecture Review — Findings (round 1)

Verdict: NEEDS-FIXES. Reviewer output preserved verbatim; fixes tracked per
finding. Owner decision: fix all findings, then re-review until clean.

## Critical

1. **FIXED (`e36070bb`) — Production composition was code, not data.**
   App, daemon, and CLI boots now load the shipped bundle and profile YAML.
   Home and command patches use the same resolver. A final ambient patch adds
   only machine facts. The catalogs now contain definitions and injected
   factories, but they do not generate composition rows.
2. **FIXED (`0e817bd9`, `fab61ea6`, `231292c1`) — Tool and agent-loop event extension points were decorative.**
   Queue workers now run through `ToolRuntime.execute` in both production
   roots. Each dispatch registers a typed worker tool for one item. The dispatch
   removes the tool after success, failure, or cancellation.

   `AgentLoopService` now separates turn preparation from stream completion.
   `AgentLauncher` routes one-shot, staged, concurrent-executor, and interactive
   sends through one helper. The request waterfall can change the prompt. A
   pre-step result can skip the backend. The helper forwards backend events as
   they arrive and emits each turn and step boundary one time.

   The per-wiki runtime requires the resolved agent-loop service. Real launcher
   turns disable `SessionService` projection because the launcher owns durable
   chat persistence and streaming checkpoints. Cordis lifecycle listeners still
   receive all boundaries. Tests cover prompt changes, short-circuits, real
   lifecycle events, incremental delivery, and the one-shot send seam.

## Major

3. **FIXED (`95025abd`, `test(cordis): pin demoted app boot`) — App boot was a privileged assembly root.**
   `AppProcessPluginCatalog` now contains the injected app-target factories.
   The committed process-profile rows select all five process runtime leases.
   `WikiFSApp.init` no longer constructs `GenerationGate`, `AgentLauncher`, or
   any concrete process runtime factory. The boundary check rejects those
   constructors in the app initializer.

   Three process-scoped UI adapters remain in `WikiFSApp.init`:
   `DaemonTransportAppCoordinator`, `QueueActivityTracker`, and
   `BackgroundIngestCoordinator`. Each adapter depends on main-actor UI state
   or on the `SessionManager`, which the app creates after process startup.
   Cordis accepts only `Sendable` services and must not store these observable
   main-actor objects. These adapters do not select a domain implementation or
   own a Cordis runtime. Moving them requires new asynchronous forwarding
   facades, so this change keeps them as documented UI-shell concerns.
4. **FIXED (`dce9ea95`, `7a18c341`) — Per-wiki privileged construction survived.**
   The child profile now supplies the store, read pool, model, search runtime,
   generation gate, and agent launcher. `ProfileWikiSession` adapts these
   services for the UI. `SessionManager` permits synchronous construction only
   through an explicit test fixture. The boundary script rejects direct domain
   service construction outside narrow plugin and factory allowlists.
5. **FIXED (`9697ddba`) — `CordisBoot.boot`/`EntryTree.update` leaked partial state on failure.**
   Boot failures now dispose the tree and context. Update failures dispose all
   new handles exactly once and preserve cleanup failures.
6. **FIXED (`7f7c2fef`) — `EntryTree` disposal was not true LIFO.**
   `EntryTree` now records mount order. All removal, replacement, rollback, and
   full disposal paths use reverse mount order.
7. **FIXED (`f5a28a6a`) — Daemon wiki removal retained disposed stores and late child profiles.**
   The daemon evicts its store before child shutdown. The profile owner tracks,
   awaits, and shuts down every per-wiki task result. Reopening makes a new store
   and event bus.
8. **FIXED (`8ff14fe8`) — The app process owner leaked a profile after resolution failure.**
   The owner now shuts down a booted profile when service resolution fails.
   The test verifies that earlier leases dispose exactly once.
9. **FIXED (`0fe2cb31`) — Concurrent same-wiki `readySession` calls could double-boot.**
   `SessionManager` now uses one task per wiki. Concurrent callers await the
   same task, and the manager shuts down an uninstalled late result.

## Minor

10. **FIXED (`ccf6db5b`) — Store-to-Cordis bridge forwarding tasks were unowned.**
    The store component now owns forwarding admission and tasks. Disposal
    unsubscribes, cancels accepted tasks, and awaits all in-flight forwarding.
11. **FIXED (`b2d20839`) — Boot/config tests used synthetic rows.**
    The tests now load committed YAML and apply a fixture home patch. App,
    daemon, and CLI dump tests pin the resolved profiles. The authority test
    edits one copied app YAML row and boots the selected production catalog
    slice. The running renderer service registry changes with the YAML row.

## Positive observations (no action)

- Typed dispatch modes as compile-time contracts; well-tested low-level
  emit/waterfall and listener disposal (`CordisEventsTests`).
- Token-owned registries resist stale disposers.
- Search-before-child shutdown ordering; app termination ordering.
