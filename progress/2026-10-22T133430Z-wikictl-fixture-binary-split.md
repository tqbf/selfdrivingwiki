---
timestamp: 2026-10-22T133430Z
title: "Fixture-binary split: wikictl loses its local database pathway; wikictl-fixture owns it"
branch: feature/wikictl-fixture-target
status: implemented
---

# Fixture-binary split: wikictl loses its local database pathway; wikictl-fixture owns it

## Progress

The operator direction was: the shipping `wikictl` must have NO local database
pathway at all; fixture runs get their own build-only binary.

- New `wikictl-fixture` executable target (`Sources/wikictl-fixture`,
  `Package.swift`): build-only, never bundled (build.sh stages only `wikictl`
  into `Contents/Helpers`). It owns the `--database-path`/`WIKI_DB_PATH`
  selector parsing (`FixtureArgumentParser`), the typed explicit-database
  validation/resolution (`FixtureWikiResolver` — absolute, `.sqlite`, outside
  the App Group container), the in-process `CLIStoreProfile` boot, the local
  command executor, and the fixture extractor sync/fetch leg
  (`ExtractorFixtureLeg.swift` moved from `Sources/wikictl`). Commands reuse
  WikiCtlCore's command layer via the new `ArgumentParser.parseCommand`
  seam — one grammar, two binaries.
- `wikictl` rejects `--database-path`/`WIKI_DB_PATH` with a usage error
  naming the fixture binary (exit 2); help never mentions them;
  `Invocation.databasePath` is gone; `WikiCtlRunner.runOrdinary` routes every
  command through the daemon (no store profile, no executor);
  `WikiResolver` keeps only App Group container resolution.
- `scripts/check-cordis-boundaries`: the ExtractorFixtureLeg allowlist is
  removed — `QueueStore(`, `WikiRegistry.load(`, and `GRDBWikiStore(` are
  unconditionally rejected in `Sources/WikiCtlCore` and `Sources/wikictl`.
  The `wikictl-fixture` target sits outside the scoped CLI rules like the
  test targets; its store profile joins the named `makeStore`/`BootedProfile`
  facade boundaries.
- The live semantic evaluation harness (the operator's endgame) now runs on
  REAL throwaway wikis: each leg creates its wiki through the daemon's
  registry over the socket (`DaemonWikiRegistryClient.createWiki`) and fully
  evicts it afterwards (`deleteWiki`), on success and failure paths; a
  missing daemon is a typed `daemonUnavailable` stop, never a local fallback.
  The harness's measurement boot opens the daemon-created database in-process
  for loop-trace hooks (a second WAL-mode writer). `AgentLauncher.
  wikiDatabaseOverride` and `AgentRunContext.databasePath` are removed —
  every trusted selector renders `--wiki` only, and `WIKI_DB_PATH` leaves the
  exported run environment. The agent-facing `ingest-write-rule.md` prompt
  drops the isolated-evaluation selector spelling.
- Tests: the explicit-database-path suite moved to the new
  `WikiCtlFixtureTests` target (in-process, plus the fixture store-profile
  and renderer-catalog suites ported from the app tier); `wikictl` gained
  `WikiCtlFixtureFlagRejectionTests` (flag/env/mixed rejection + unchanged
  ordinary parsing); `CordisBoundaryScriptTests` covers the removed allowlist
  (the old allowlisted file back inside `wikictl` FAILS — the negative
  proof), the fixture-target exemption, and the `GRDBWikiStore(` rule shape.
- Plan docs: `plans/cli-domain-commands.md` gained §"The fixture binary";
  `plans/wiki-strategy-evaluation-harness.md`'s Isolation section now
  describes daemon-created/evicted wikis.

Commits: 5aa2a8cf (target extraction + flag removal), d5ac9c83 (boundary
tightening), 2e2bd4b2 (harness migration), plus the docs commit for this
note and the plan section.

## Verification

- `swift build --build-tests` green (warnings-as-errors on), including the
  new `wikictl-fixture` product; `swift build --product wikictl-fixture`
  builds the binary.
- Targeted suites green: `WikiCtlFixtureTests` (11 tests),
  `WikiCtlFixtureFlagRejectionTests` (5), `CordisBoundaryScriptTests` (8),
  `CLITantivyLegResolverTests` + `DaemonCommandSocketTests` +
  `RendererSourceTypeCompositionTests` (29, `WIKIFS_APP_TESTS=1`),
  `AgentRunContextTests` (20), `WikiStrategyEvaluationHarnessTests` +
  `WikiStrategyOfflineRecheckTests` (31).
- `scripts/check-cordis-boundaries` green with the tightened rules; the
  negative proof (a reintroduced `QueueStore(` in
  `Sources/wikictl/ExtractorFixtureLeg.swift`) fails the check by test.
