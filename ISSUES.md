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

**Mitigation (Phase D, 2026-06-16).** A *related, milder* symptom — a
freshly-created wiki failing to register/mount until relaunch, with NO error —
was hardened against in `FileProviderSpike.registerDomain`. It no longer does a
single best-effort `add(domain)` that swallows failures: it now **verifies** the
domain actually appears in `NSFileProviderManager.domains()` after each `add`,
**retries** a bounded number of times with a short backoff if a busy daemon
didn't take it (`DomainRegistrationPolicy.maxAttempts`, async sleep — never
blocks the main actor), **nudges** the new domain's root/working-set enumerator
on success so the mount materializes promptly, and **surfaces** any real `add`
failure to the console + `status` (never swallowed). This makes create→mount
immediate on a healthy-but-busy daemon and makes failures LOUD + self-healing.
It does NOT rescue a fully *wedged* replica (the case above) — that still needs a
domain teardown — but it covers the transient-busy window that was silently
dropping fresh registrations.

Recorded 2026-06-15 (Phase A write-path live gate); mitigation added 2026-06-16.

## Vendored Textual fork (in-repo path dependency)

**Symptom.** Textual is no longer a remote SPM dependency; it's vendored at
`Packages/Textual/` as a path dependency and carries a small fork. Upstream
Textual updates are no longer picked up automatically.

**Why.** Right-click link context menus need Textual internals — its
`NSTextInteractionView` owns right-click and the context menu, and the link
hit-test (`model.url(for:)`) plus the selection model are `internal`. There is no
public Textual API to customize the menu or select a whole link, so we vendor to
make three localized edits (`plans/link-context-menus.md`).

**What the fork changes** (vs upstream `textual` 0.5.0, rev `01b5187`):
- `Sources/Textual/LinkContextMenu.swift` (new) — public `LinkMenuItem`,
  `LinkContextMenuBuilder`, the `linkContextMenu` env value.
- `Sources/Textual/View+Textual.swift` — `.textual.linkContextMenu(_:)`.
- `…/TextLayout/TextLayoutCollection+RunSliceTraversal.swift` — `linkRange(for:)`
  + `url(at:)`.
- `…/TextSelectionModel.swift` — `linkRange(for:)` passthrough.
- `…/AppKit/NSTextInteractionView.swift` — right-click whole-link selection +
  link-menu builder; refactored `makeContextMenu`.
- `…/AppKit/AppKitTextInteractionOverlay.swift` — threads the env value.
- The manifest is byte-identical to upstream (no `testTarget` patch).

**Why it's probably fine.** The diff is tiny and isolated to the link-menu
feature; it does not change Textual's rendering or selection behavior for
non-link right-clickes. The vendored tree is a faithful copy of upstream minus
`.git`, build artifacts, and the `Examples/` tree.

**To re-sync upstream.** Diff the six files above against a fresh checkout of the
new version, port the edits, bump the recorded rev here. Do NOT re-point
`Package.swift` at a remote — carrying the fork is the point.

Recorded 2026-06-22 (link-context-menus PR).
