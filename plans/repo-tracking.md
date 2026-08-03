# Repository Tracking

## Purpose and scope

A wiki can track an app-owned git checkout. The user explicitly adds a remote,
then explicitly requests clone, fetch, or wiki update work. There is no polling
loop, automatic update, or File Provider projection.

Repository tracking is deliberately separate from source ingestion. Sources are
immutable bytes in the wiki database; repositories are mutable remote state with
an upstream `head_commit` and an agent-confirmed `last_ingested_commit`.

## Current architecture mappings

### 1. GRDB schema, store ownership, and migration

`GRDBWikiStore` owns the `tracked_repos` table at schema v49. A row contains a
typed `TrackedRepoID`, display name, remote URL, optional discovered branch,
upstream head, ingestion watermark, fetch timestamp, timestamps, and optimistic
version. The v48→v49 migration creates the table and unique remote URL index.

`WikiStore` exposes typed metadata operations only: add, list, get, find,
set branch, update fetch state, mark an ingested commit, and delete. These
operations are intentionally `NO-EMIT`: a repository is not a projected File
Provider resource. The daemon posts the existing coarse Darwin change after a
successful clone or fetch; the model refreshes the sidebar projection through
its established cross-process reload path.

### 2. Daemon, XPC, queue, and ACP boundaries

The app enqueues a typed `RepositoryWorkRequest` in the existing `.ingestion`
queue through `QueueEngineClient`/XPC. `QueueIngestionWorker` dispatches it to
`QueueIngestionProvider.runRepositoryWork`; the app-side provider rejects that
work so there is no local Git fallback.

`DaemonQueueIngestionProvider` owns all checkout and Git actions. Checkouts live
under Application Support at a wiki ID plus `TrackedRepoID` path, so they cannot
name a user checkout. `DaemonGitRunner` resolves and runs only the argv emitted
by `GitCommandPlan`; clone/fetch/reset therefore apply solely to daemon-owned
checkouts. The worker skips agent readiness for clone/fetch and requires it for
an update, which starts ACP work.

For an update, the daemon fetches, computes `RepoSyncPlan`, and stages an
authoritative `REPO_STATE.md`. Small work is one curator pass. Curator work uses
a deterministic `RepoReaderWorkPlan`: 2 through 19 read-only ACP readers digest
assigned paths in parallel, then one curator receives the ordered digests and is
the only session with `wikictl`. Reader cancellation stops each associated ACP
launcher. Readers receive no CLI profile, database environment, or write access.

### 3. `wikictl` and app request contracts

`wikictl repo list`, `repo get`, and `repo mark-ingested` operate through the
current `WikiStore`/GRDB contract. There is no CLI add/remove operation: adding
a remote has network and checkout consequences and remains an app action.
`mark-ingested` is the sole path that advances `last_ingested_commit` after the
curator has actually written wiki content.

The app validates remote input with `GitRemoteURL`, persists its descriptor in
`WikiStoreModel`, then enqueues a clone request. It never spawns Git or an
agent directly for repository work.

### 4. Redesigned app placement

`WikiStoreModel.trackedRepositories` is the observable GRDB projection.
`RepositoriesContainerView` is a Repositories section in the existing sidebar.
It provides an empty state, an accessible add sheet, and Fetch/Update controls.
Repository actions are queue requests rather than document tabs: a tracked
repository is a sync source, not a page or a File Provider item.

### 5. Authoritative tests

- `TrackedRepoStoreTests` verifies metadata watermarks and the v48→v49
  migration.
- `RepoReaderWorkPlanTests` verifies deterministic normalization, balanced
  coverage, and the 19-reader cap.
- `QueueIngestionWorkerTests` verifies a clone dispatches through the repository
  provider even when an agent is unavailable.
- Existing `GitCommandPlanTests`, `RepoSyncPlanTests`, `RepoStateSnapshotTests`,
  and `RepoCommand` coverage retain the pure command, planning, state, and CLI
  contracts.

## Non-goals and security boundaries

- Do not restore `SQLiteWikiStore`, direct app operation runners, or legacy
  repository tracker/UI files.
- Do not project repository rows or checkout files through File Provider.
- Do not permit agents to add/remap tracked remotes or operate user checkouts.
- Do not run automatic network fetches or token-spending updates.
- Do not give repo readers `wikictl`, wiki database paths, or write-capable ACP
  profiles.

## Known limitations

Drift is only as fresh as the last explicit fetch. A rewritten upstream history
causes a full re-read rather than a false incremental range. Private repository
authentication relies on the system Git/SSH setup and the daemon never stores a
credential itself.
