# Cordis Full-Architecture Review — Findings (round 1)

Verdict: NEEDS-FIXES. Reviewer output preserved verbatim; fixes tracked per
finding. Owner decision: fix all findings, then re-review until clean.

## Critical

1. **Production composition is still code, not data; bundles are not
   authoritative.** App/daemon/CLI boot from hard-coded Swift entry arrays
   (`ProductionPluginCatalogs.swift` `ProductionProfileEntries`,
   `WikiFSApp.swift:236-290`, `CLITantivyLegResolver.swift:294-296`).
   `ProfileBundle` YAML loading exists but production never calls it.
   Fix: entry points resolve real bundle/profile/home/overlay layers through
   `ProfileBundle` (machine facts like DB URL/wiki id as an overlay), pass
   resolved rows to `CordisBoot`; add a test that edits only YAML and proves
   the booted graph changes.
2. **Tool and agent-loop event extension points are decorative.**
   `ToolServiceKeys`/`AgentLoopServiceKeys` define the waterfalls, but no
   production execution routes through them (`QueueEngine.swift:842-845`
   calls workers directly; agent execution stays in `AgentLauncher`).
   Fix: route the real agent request/turn driver through `AgentLoopService`
   and every real tool call through `ToolRuntime.execute`; end-to-end tests
   where a waterfall listener rewrites/short-circuits a real invocation.

## Major

3. **`AppProcessComposition` is a new privileged assembly root**
   (`RendererCompositionOwner.swift:176-329`, `WikiFSApp.swift:174-328`).
   Fix: reduce app boot to ambient facts + injected factory catalog +
   profile-layer loading; move owners/factories into row-selected plugins.
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
11. **Boot/config acceptance tests use synthetic rows, not committed YAML.**
    Fix: tests that load `bundles/*/cordis.patch.yml`, boot the
    production-shaped catalog, and pin app/daemon dump-config output.

## Positive observations (no action)

- Typed dispatch modes as compile-time contracts; well-tested low-level
  emit/waterfall and listener disposal (`CordisEventsTests`).
- Token-owned registries resist stale disposers.
- Search-before-child shutdown ordering; app termination ordering.
