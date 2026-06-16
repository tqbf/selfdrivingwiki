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

## Heavily-churned File Provider domain replica can wedge

**Symptom.** A single domain that has been hammered across many repeated
gate runs (create/delete pages, `WIKIFS_REENUMERATE` cycles, app re-signs and
reinstalls, mid-run kills) can get its **daemon-side materialized replica** into a
bad state: `fileproviderctl dump` shows phantom items from earlier sessions,
`NSFileProviderErrorDomain Code=-1005 "The file doesn't exist"` fetch errors, a
missing `indexes/` subtree, and "Stale NFS file handle" on files that used to
read. New `wikictl`/app writes stop appearing on that mount even though they ARE
in SQLite. The extension may not even be invoked.

**Why.** This is `fileproviderd`'s replica bookkeeping for that one domain getting
corrupted/desynced by churn — NOT our code and NOT the SQLite source of truth (a
`PRAGMA wal_checkpoint(TRUNCATE)` + read with a fresh reader confirms all rows are
durable). The same build on a **freshly-created** domain materializes fully and
correctly in ~1 s.

**Why it's probably fine.** It only shows up on the one domain we abuse during
testing; a fresh wiki is clean. It did NOT recover via the app's
`WIKIFS_REENUMERATE` remove+re-add, a `fileproviderd` bounce, or ~90 s of
reconciliation — a true reset needs a full domain teardown, which only the signed
app's lifecycle can do (`NSFileProviderManager.remove`; an ad-hoc CLI gets
FP -2001/-2014). **For live gates, create a fresh wiki rather than reusing the
long-lived `WikiFS` one.**

Recorded 2026-06-15 (Phase A write-path live gate).
