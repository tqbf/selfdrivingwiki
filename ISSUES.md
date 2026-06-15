# Known issues

Running list of known limitations / rough edges. Not bugs to fix right now —
things we've decided to live with, with enough context to revisit later.

## Read-after-write latency: ~5s replica-invalidation window

**Symptom.** After an in-app edit (page body, system prompt, ingest/remove), a
`cat` of the corresponding file on the mount can return the *old* bytes for up to
~5 seconds before it refreshes on its own. No relaunch is needed; it self-heals.

**Why.** Our File Provider extension is an `NSFileProviderReplicatedExtension`
(`Sources/WikiFSFileProvider/FileProviderExtension.swift`). In the replicated
model the OS daemon (`fileproviderd`) keeps a **materialized local copy** of each
item's bytes and serves `cat` from that copy — it does **not** pass every read
through to our extension. SQLite is the instantly-consistent source of truth; the
lag is entirely the daemon's replica refreshing lazily. The refresh path is async:

```
app save → onPageDidChange → signalEnumerator
        → (later) daemon calls enumerateChanges
        → sees higher itemVersion (contentVersion = row version)
        → discards its materialized copy
        → NEXT read triggers fetchContents → reads SQLite  ← only now is it fresh
```

So nothing in our code is stale; we're waiting on the daemon to notice the version
bump and re-fetch. Two items signaled together (e.g. `CLAUDE.md` + `AGENTS.md`)
can also refresh a few seconds apart — the daemon invalidates/re-fetches each
independently, with no ordering guarantee.

**Why it's probably fine.** In practice the only consumer of this filesystem is an
**agent we launch on demand** — it runs when we tell it to, not continuously. So
we can likely close the gap when it matters: e.g. busy-poll / force a sync (or an
explicit settle step) right before handing the mount to the agent, instead of
trying to make every `cat` read-through. **Not implementing this now** — noted so
we remember the option exists.

**What we would NOT do.** Make every `cat` read straight through to SQLite — that
means abandoning the replicated model, which is the whole point of this POC.

Recorded 2026-06-15 (system-prompt live-mount gate). Originally observed in the
Phase 2/3 caveats in `PROGRESS.md`.
