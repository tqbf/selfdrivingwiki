---
timestamp: 2026-07-25T234909Z
title: "test: a seam for the File Provider domain lifecycle, so #919 can't recur"
branch: null
status: historical
timestamp_source: git-commit
---

# test: a seam for the File Provider domain lifecycle, so #919 can't recur

## Progress


**Why.** #920 fixed the rename, but the reason nothing *caught* it was
structural: `FileProviderFacade` fused the decision ("a rename is a display-name
change") with the effect (`NSFileProviderManager` statics), and only the effect
is untestable. The repo already splits these once — `DomainRegistrationPolicy`
is a pure tested enum the facade defers to — the rename path just never got the
same treatment.

**The seam.** `FileProviderDomainService` (WikiFSCore, no FileProvider import)
covers exactly the three lifecycle calls: `add` / `remove` / `domains`.
`SystemFileProviderDomainService` (WikiFS) is the pass-through holding no
policy; `FileProviderFacade.init` takes one, defaulting to the real thing.
Item-level resolution (`NSFileProviderManager(for:)` → `getUserVisibleURL` /
`signalEnumerator`) stays on the concrete API — much wider surface, not where
the lifecycle bugs have been.

Two design details carry most of the value:

* **`remove(id:reason:)` takes a `DomainRemovalReason`** (`.wikiDeleted` /
  `.schemaMigration` / `.reenumerateHatch` — a rename is not among them). It
  makes the destructive call self-documenting at all three legitimate sites, and
  a test can assert an operation performed *no* teardown and name the
  illegitimate one in the failure message.
* **`domains()` returns display names, not just ids.** The old
  `isDomainRegistered` mapped `\.identifier.rawValue` and threw the name away,
  so domain *presence* was observable but the display name wasn't — nothing
  could confirm a rename had landed. `renameDomain` now re-reads the daemon
  after its `add` and logs a loud MISMATCH if the upsert was silently ignored.
  The whole #919 fix rests on documented-but-previously-unobservable behaviour;
  this is what makes it observable.

**Tests** (`FileProviderDomainLifecycleTests`, 8, in `WikiFSAppTests` which
already depends on `WikiFS`). Verified by reverting `renameDomain` to the old
remove+re-add: 3 fail, and the register/remove tests correctly stay green.

**What writing them turned up.** `registerDomain`'s "idempotent add-if-absent"
property is *conditional on no migration being pending* — with the schema
version unset it removes before adding, which is how the first draft of
`registerDomainDoesNotRenameAnAlreadyPresentDomain` passed for the wrong reason
(a fresh test process reads version 0). The suite is `.serialized` and each test
declares its migration state via `settled()`; `currentSchemaVersion` /
`schemaVersionKey` went internal so tests state it rather than hardcoding `2`.
Worth knowing generally: "idempotent" on that method has a precondition.

The test pinning `registerDomain` *cannot* rename is the one to keep. It encodes
why `renameDomain` can't just call it, so a future simplification that merges
them fails loudly instead of silently breaking rename.

## Verification

Historical verification remains in the progress record above.
