---
timestamp: 2026-07-25T231112Z
title: "fix: rename a File Provider domain in place instead of remove + re-add (#919)"
branch: null
status: historical
timestamp_source: git-commit
---

# fix: rename a File Provider domain in place instead of remove + re-add (#919)

## Progress


**What was wrong.** `FileProviderFacade.renameDomain` did a real
`removeDomain` → `registerDomain` cycle, with a doc comment calling it
"cosmetic from the extension's point of view". It isn't. `NSFileProviderManager
.remove(domain)` tears down the daemon's on-disk replica — the same
migration-strength reset `migrateDomainsIfNeeded` uses *deliberately* to force a
clean daemon cache — and the header documents that the re-add then fails with
`NSFileWriteFileExistsError` if that replica location still exists. So a rename
could leave the wiki unregistered and unmounted, having already cleared
`activeWikiID`/`path` in `removeDomain`, with nothing but a `status` string to
show for it. It also opened a window in which the domain resolved to nothing at
all for any other FileProvider client.

**The API was there all along.** `NSFileProviderManager.h`: "If a domain with
the same identifier already exists, `addDomain` will update the display name and
hidden state of the domain and succeed." `add` is an upsert keyed by identifier,
so a rename never needs the domain to leave the daemon. The reason this was
missed is that `NSFileProviderDomain.displayName` is `readonly`, which reads as
"domains are immutable, so rename means replace" — the mutability lives on the
*manager*, not the model.

**The trap in the fix.** You can't just drop the `removeDomain` line and reuse
`registerDomain`: that is deliberately **add-if-absent** (its presence check is
what makes it idempotent and safe against a racing `registerAllDomains`), so it
short-circuits on the already-present domain and never applies the new name.
That guard is *why* the remove was there. `renameDomain` now calls
`NSFileProviderManager.add` directly. The `activate` call is gone too: the
identifier is stable and the domain never leaves the daemon, so the mount path
is unchanged and there is nothing to re-resolve — the old code only needed it to
repair the state `removeDomain` had just destroyed.

**Logging.** The rename path logs `wasRegistered` / `isActive` on entry plus the
outcome. `wasRegistered` is the diagnostic that matters: present means this was
the documented in-place update, absent means we registered from scratch and
could hit the leftover-replica failure. One `domains()` call on a
hand-triggered operation is cheap.

**On the crash in #919.** This does *not* claim to fix the `EXC_BREAKPOINT` in
`URL._unconditionallyBridgeFromObjectiveC`. No SDW frame appears on the crashing
thread and the trapping frame is a private `FPItemManager
_fetchURLForItemID:...` path we never call; the change is justified on its own
merits above. It does close the registration gap the issue hypothesised about.
The nil-`NSURL` force-bridge in Apple's private completion path is still worth
an Apple Feedback.

## Verification

Historical verification remains in the progress record above.
