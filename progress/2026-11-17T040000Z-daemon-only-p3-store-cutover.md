---
timestamp: 2026-11-17T040000Z
title: Daemon-only P3 store cutover complete
branch: feature/daemon-only-p1-async-store
status: active
---

# Daemon-only P3 store cutover complete

## Progress

Phase 3 (plan `plans/daemon-only-access.md` P3 column) is implemented on
`feature/daemon-only-p1-async-store` across three slices (checkpoints
33-36).

- **Mode cutover.** `allowLocalStore` is launch-fixed and defaults to
  false (remote) in every configuration; `true` is compiled `#if DEBUG`
  with an env override release builds cannot read. StorePlugin boots the
  app's `RemoteWikiStore` through the injected factory with no local
  database open; no-factory remote fails explicitly rather than falling
  back. `StoreModeConfigurationTests` pin the default, the override
  mechanics, and that daemon failure cannot flip the mode.
- **Registry mediation.** `WikiRegistryClient` is a read cache in remote
  mode: create/rename/delete route to the daemon's XPC lifecycle ops,
  every former `wikis.json` write is gated (a debug miswire detector
  fires in remote), export/import are typed daemon-owned surfaces, and
  bootstrap's legacy branch is a no-op. Registry events ride a third
  pairwise-disjoint firehose envelope; the daemon emits at every
  registry mutation and the client's feed refreshes the cache.
  `WikiRegistryClientCacheOnlyTests` (11) pin the no-write invariant.
- **Legacy v0 import** runs in the daemon (both inits, pre-serving,
  empty-registry gated, idempotent — pinned).
- **Degradation UX.** Remote store failures classify into the existing
  health machine: an episode latch fires `noteStoreTransportDegraded`
  (orange non-dismissible "Reconnecting to the wiki daemon…" banner) and
  the first success fires recovered. Writes keep failing explicitly
  through the model's store error path.
- **Change-token reconciliation.** On re-handshake the client compares
  the daemon token against its cache and fires ONE coalesced reload when
  the token advanced (re-armed per epoch). Tests prove exactly-one reload
  after a missed second-writer commit and zero reloads on unchanged
  tokens.
- **TwoLiveSinks flake fixed.** Root cause was test-pinned ingest
  timing (the seeded Home event ingests asynchronously and can land
  after both handshakes), not a coordinator defect. The coordinator's
  watermark now rises whenever any sink is live (structural guarantee
  that a second handshaking sink never replays delivered events), the
  test waits for ingest deterministically, a new regression test pins
  the exact failing interleaving, and assertions were strengthened.
- **Exhaustiveness** (`RemoteStoreSurfaceExhaustivenessTests`,
  always-tier) pins the 169-name partition (wired 151 / removed 15 /
  client 3) and the executor-protocol-client triangle.
- **AC.10 suites** (`RemoteStoreDedupeTests` 5, `RemoteStoreConcurrencyTests`
  5) prove the exactly-once and concurrency semantics over the real
  socket transport.

Known follow-ups (queued, not regressions): MRU touch and home-page
pointer are cache-only in remote mode until the daemon gains those ops;
export/import are daemon-owned surfaces until daemon ops exist; the
manual daemon-kill scenario (plan P3 gate) is a recorded operator script
pending the P7 docs pass.

## Verification

- `make build` green; `make lint` 0 violations (781 files).
- Full `make test`: 5,128 tests, 0 failures.
- Opt-in suites: executor 44, RemoteWikiStore 26 (two new
  reconciliation tests), events 10 (strengthened + one new regression),
  dedupe 5, concurrency 5, bootstrap 4 — all green through the guarded
  runner; boundary 7/7 and mode 3/3 in the always tier.
