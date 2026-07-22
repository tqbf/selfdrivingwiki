# Plan: Centralize WorkspaceStatus into a Guarded FSM

## Summary

Replace the 8 scattered raw-SQL `status` writes on `workspaces` with a single
`transitionWorkspace(id:to:allowedFrom:)` method that validates legal transitions
(mirroring `QueueStore.validateTransition`). Add a `WorkspaceStatus` enum with
documented legal transitions. No DB migration required (CHECK constraint deferred).

## Problem

`WorkspaceStatus` has 5 states (`open`, `merging`, `merged`, `conflicted`,
`abandoned`) written by **8 raw-SQL string literals** scattered across
`GRDBWikiStore`, each with ad-hoc `WHERE` self-guards. No central validator, no
DB CHECK. Nothing structurally prevents illegal transitions (`merged→open`,
`abandoned→merging`). Adding a new writer means re-deriving the legal set by
reading all 8 sites. This is the exact pattern `QueueItemState` already solved
via `QueueStore.validateTransition`.

## Design

### Step 1: Promote WorkspaceStatus to a proper enum

`Sources/WikiFSCore/Sources/SourceVersioning.swift:172` — the enum already
exists with 5 cases. Add a `legalTransitions` computed property or a static
method:

```swift
public enum WorkspaceStatus: String, CaseIterable, Codable, Sendable {
    case open, merging, merged, conflicted, abandoned

    /// Legal target states from this state.
    public var allowedTargets: Set<WorkspaceStatus> {
        switch self {
        case .open:        return [.merging, .abandoned]
        case .merging:     return [.merged, .conflicted, .abandoned]
        case .merged:      return []           // terminal
        case .conflicted:  return [.open, .abandoned]  // retry or give up
        case .abandoned:   return []           // terminal
        }
    }
}
```

### Step 2: Add transitionWorkspace to GRDBWikiStore

Add a private method that validates + writes. **Implementation note: every
status-write site already lives inside a `mutate(event:_:)` closure that passes
a `Database`. To preserve atomicity and the `mutate()` emission invariant
(AGENTS.md: every public mutator routes through `mutate` and emits), this
helper takes the existing `db` rather than opening its own write.**

```swift
/// Validate and execute a workspace status transition on `db`.
/// Throws `.notFound` if the row is missing, or
/// `.invalidStateTransition` if the current status is not in `allowedFrom`.
/// Mirrors `QueueStore.validateTransition`, but operates inside the caller's
/// savepoint (read-validate-write in one transaction — no TOCTOU window).
private func transitionWorkspace(
    on db: Database, id: String,
    to: WorkspaceStatus, allowedFrom: Set<WorkspaceStatus>
) throws {
    let currentRaw = try String.fetchOne(
        db, sql: "SELECT status FROM workspaces WHERE id = ?;",
        arguments: [id]
    )
    guard let currentRaw else { throw WorkspaceError.notFound(id) }
    guard let current = WorkspaceStatus(rawValue: currentRaw) else {
        throw WorkspaceError.invalidStateTransition(from: currentRaw, to: to)
    }
    guard allowedFrom.contains(current) else {
        throw WorkspaceError.invalidStateTransition(from: current, to: to)
    }
    try db.execute(
        sql: "UPDATE workspaces SET status = ?, updated_at = ? WHERE id = ?;",
        arguments: [to.rawValue, Date().timeIntervalSince1970, id]
    )
}
```

### Step 3: Route all write sites through transitionWorkspace

> **Corrected `allowedFrom`** — the plan's original table assumed the merge
> closure's step-1 `'merging'` write persisted into the rollback catch block.
> It does not: `mutate()` wraps the body in `db.inSavepoint` (see
> `GRDBWikiStore.swift:336`), so when the closure throws on conflict, the
> `'merging'` write is rolled back → status reverts to `'open'`. The catch
> block then writes `'conflicted'` from `.open`. Same for `reapStaleWorkspaces`
> (its SELECT only returns `'open'` rows). The `allowedFrom` below reflects
> the **actually reachable status at each write site** (verified by reading the
> code), which is what preserves existing behavior.

| Site | Method | `to` | reachable-from (code-truth) | `allowedFrom` |
|------|--------|------|------|---------------|
| `createWorkspace` (~L4682) | INSERT | `'open'` | n/a (initial state) | stays INSERT |
| `workspaceMerge` step 1 (~L4896) | in main closure | `.merging` | `.open` | `[.open]` |
| `workspaceMerge` step 4 (~L5001) | in main closure | `.merged` | `.merging` | `[.merging]` |
| `workspaceMerge` catch (~L5015) | separate txn, post-rollback | `.conflicted` | `.open` | `[.open]` |
| `abandonWorkspace` (~L5058) | public | `.abandoned` | any non-terminal | `[.open, .merging, .conflicted]` |
| `workspaceRefresh` catch (~L5155) | separate txn, post-rollback | `.conflicted` | `.open` | `[.open]` |
| `workspaceRetryMerge` (~L5273) | public | `.open` | `.conflicted` | `[.conflicted]` |
| `reapStaleWorkspaces` (~L5306) | loop over stale `'open'` IDs | `.abandoned` | `.open` | `[.open]` |

Behavior changes (intended):
- The two `WHERE status = 'X'` self-guards (L4897 `status='open'`, L5274
  `status='conflicted'`) and their `db.changesCount > 0` friendly-error
  checks are removed; `transitionWorkspace` replaces them with a typed
  `WorkspaceError.invalidStateTransition`. No test asserts on the old
  `WikiStoreError.unexpected("… is not open/conflicted")` strings (verified).
- `abandonWorkspace` is newly restricted to non-terminal states
  (`[.open, .merging, .conflicted]`); today it has no guard. No caller
  abandons a terminal (`merged`/`abandoned`) workspace (verified in tests +
  `WorkspaceCommand`).

### Step 4: Add WorkspaceError

Lives next to `WorkspaceStatus` + `PageConflictError` in `SourceVersioning.swift`
(mirrors how `QueueStoreError` is a domain-local error type):

```swift
public enum WorkspaceError: Error, Equatable, CustomStringConvertible, LocalizedError {
    case notFound(String)
    case invalidStateTransition(from: WorkspaceStatus, to: WorkspaceStatus)
    // (an unknown raw string in the DB column is surfaced as invalidStateTransition
    //  with from = the raw string — but WorkspaceStatus is a closed enum, so the
    //  typed from-below overload is used; keep a String-`from` overload only if needed.)

    public var description: String { … }
    public var errorDescription: String? { description }
}
```

### Acceptance criteria

- **AC.1**: `WorkspaceStatus.allowedTargets` returns the correct legal set for each state.
- **AC.2**: `transitionWorkspace` throws `.invalidStateTransition` on illegal moves (e.g., `merged→open`).
- **AC.3**: All 7 UPDATE sites (excluding the initial INSERT) route through `transitionWorkspace`.
- **AC.4**: The `WHERE status=…` self-guards at each site are removed (the validator replaces them).
- **AC.5**: `swift build` + `swift test` pass.
- **AC.6**: New test: `WorkspaceTransitionTests` covering every legal + illegal transition.

### Files touched

- **Edit:** `Sources/WikiFSCore/Sources/SourceVersioning.swift` (add `allowedTargets` + `CaseIterable`/`Codable`; add `WorkspaceError`)
- **Edit:** `Sources/WikiFSCore/Store/GRDBWikiStore.swift` (add `transitionWorkspace`, route 7 sites, remove raw SQL + `WHERE status` guards)
- **New:** `Tests/WikiFSTests/WorkspaceTransitionTests.swift`

### Out of scope

- DB CHECK constraint (requires table-rebuild migration — separate PR)
- Typed IDs (SourceID/ChatID/VersionID newtypes — separate large effort)
- QueueRunState guard (only 2 cases, low risk)
