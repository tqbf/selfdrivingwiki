---
timestamp: 2026-09-23T103000Z
title: Issue 1314 chat fence denied the queue DB write
branch: bugfix/1314-zotero-readonly-sync
status: complete
---

# Issue 1314: the chat write fence denied the central queue DB write

## Progress

`wikictl extractor sync zotero --force` run from a chat failed with
`SQLite error 8: attempt to write a readonly database`. The cause was the
chat seatbelt fence, not file permissions.

`SandboxProfile` allowed writes only to the scratch dir, `~/.claude`, the
Claude temp base, and the active wiki `<ulid>.sqlite` plus its SQLite
sidecars. The central `queue.sqlite` matched no allow rule. The sync's
enqueue (`QueueStore.enqueue` → `INSERT INTO queue_items`) is the one write
the `--force` path makes, and the first-ever sync makes the same write after
creating the byteless source. Under the fence, SQLite's open-for-read-write
was denied, the connection fell back to read-only, and the INSERT surfaced
as `SQLITE_READONLY` (error 8). That is also why source
`01M36H1VKJDMZQQ2ZGDF3GJDG8` is zero-byte with no blob and no queue job: the
wiki DB write succeeded, the enqueue did not.

The fix adds an optional `queueDBPath` to `SandboxProfile.generate` and
`.invocation`, emitting `QUEUE_DB` literal write allows (base + the
`-wal`/`-shm`/`-journal` suffixes). `AgentLauncher.resolveSandboxInvocation`
passes the queue DB path beside the wiki DB. Omitting the parameter keeps the
profile byte-identical to the old fence. The extraction fence
(`ExtractorSandboxProfile`) is unchanged: extractor children never touch the
queue; the enqueue happens in the CLI/app process.

Verified at three levels, all inside disposable containers with fake
sidecar values, no real wiki, and no credentials:

1. Raw `sqlite3` INSERT under a hand-built pre-fix profile: fails with the
   exact message; a wiki DB INSERT control succeeds.
2. Live suite tests with the real generated profile: denial (pre-fix shape,
   with the readonly message) and success (post-fix), row checked through
   `QueueStore`.
3. End to end: the real built `wikictl` under the real fence runs
   `extractor sync zotero --force` in a disposable App Group container. The
   pre-fix fence prints `wikictl: SQLite error 8: attempt to write a
   readonly database` and strands a zero-byte `application/zotero` source;
   the fixed fence re-enqueues exactly one extraction job targeting that
   source. Fully offline — the `--force` path never touches the network.

One secondary observation: reviewed-overlay admission also writes into the
container (`<container>/extractors/`), so under the fence that admission
fails silently and package discovery falls back to the durable catalog the
app publishes. App-managed machines are unaffected. A CLI-only machine that
runs sync from a chat would additionally need an `extractors/` allowance;
that is a deliberate fence decision left out of this bounded fix.

## Recovery for the affected wiki

No manual repair is needed. After the fix, run
`wikictl extractor sync zotero --force` again (from the app or an
unsandboxed terminal): it re-enqueues the existing zero-byte source, and the
draining host extracts and stores the blob.

## Verification

- `make build` — passed.
- `make test` — passed (full default graph).
- `WIKIFS_APP_TESTS=1 swift test --filter 'AgentSandboxProcessTests|ExtractorSyncChatFenceTests'`
  — 14 tests passed, including the two new fence tests and the end-to-end
  sync-fence suite.
- `swift test --filter SandboxProfileTests` — passed (new allowance
  present/absent tests).
