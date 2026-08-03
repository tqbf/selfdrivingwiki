# W4 Implementation Plan — Concurrency at scale

**PR:** [#312](https://github.com/tqbf/selfdrivingwiki/pull/312)
**Gate:** Two ingestions run concurrently, queries and edits proceed
throughout, both land (one via merge).

## Implementation steps

### Step 1 — Configurable N-throttle on GenerationGate

Make `GenerationGate.maxConcurrent` configurable (default 1 for backward
compat). When N > 1, up to N generations can run simultaneously. This is a
resource-management concern, not a correctness concern (workspaces handle
correctness).

### Step 2 — Workspace reaper

A store method `reapStaleWorkspaces(ttl:)` that marks workspaces as
`abandoned` if they've been `open` longer than the TTL (crashed/abandoned
runs). Called on app launch or via `wikictl workspace reap [--ttl <seconds>]`.

### Step 3 — Tests + docs + PR
