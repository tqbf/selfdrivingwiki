---
timestamp: 2026-07-27T044546Z
title: "fix: cooperative-pool starvation (#925) integrated, documented, and re-verified on `fix/cooperative-pool-starvation`"
branch: null
status: historical
timestamp_source: git-commit
---

# fix: cooperative-pool starvation (#925) integrated, documented, and re-verified on `fix/cooperative-pool-starvation`

## Progress


**What was integrated.** The branch reconstruction kept the approved three-phase
stack in order on top of the pre-integration feature-branch base:

- `779f4d9` — Phase 1 async subprocess migration
- `77bddaa` — Phase 2 async CLI Tantivy conversion
- `b3862a1` — Phase 3 non-blocking context-menu similar-page search

The safety ref created during the earlier history repair was left untouched:
`backup/fix-cooperative-pool-starvation-pre-rebuild-20260726-150103`.

**What verification found beyond the reconstructed commits.** The approved task
was not done at "history is correct"; Phase 4/5 verification exposed real
integration fallout that needed source fixes on this branch:

- `CLITantivyLegResolver` originally gained a process-global service cache so
  concurrent searches would not reopen the same index repeatedly. Under the full
  `swift test` host, that cache retained one `TantivySearchService` per temp
  test container for the life of the process, leaving many Tantivy watchers and
  `.tantivy-writer.lock` / sqlite handles open. The second bare full-suite run
  then stalled late. The final fix keeps only **in-flight** search coalescing:
  overlapping calls share one task only when the full `(wikiID, standardized
  container path, query, kind, limit)` key matches; requests differing in any
  component run independently, and completed searches release the service.
- `QueueEngine` needed `deinit` cleanup for `runningTasks` and pending
  `waitForCompletion` continuations, otherwise late-suite teardown could leave
  a waiter parked after the engine died.
- `AgentLauncher` needed to clear `currentRunToken` whenever a run finished or
  reset artifacts; otherwise a stale `onExit` disarm state broke
  `RunAwaitsTurnTests.secondRunProceedsWithoutDeadlock`.
- The hosted autocomplete tests needed explicit `NSWindow` retention during
  full-suite execution; filtered runs passed, but late-suite bare runs could
  freeze when the hosting window lifetime ended too early. The final full-suite
  wrapper fix also added `AutocompleteHostedTestGate` so the editor/composer
  hosted suites do not overlap each other under Swift Testing's suite-level
  parallelism.
- `SplitDiffSnapshotTests` was moved from `/tmp` to repo-local
  `tmp/test-snapshots/`, avoiding environment friction and keeping scratch
  artifacts inside the project as required by AGENTS.md.
- Several stale inline comments were updated to match the post-#634 / post-#925
  reality, including `WKWebViewJSTimeout`.
- Several suite-wide five-minute `Swift Testing` time limits were removed after
  they proved to be false queue-time failures under the larger full suite rather
  than genuine per-test hangs.

**Focused verification before the final bare reruns.**

- `swift build --build-tests` — passed.
- `swift test --filter AsyncProcessRunnerTests` — 10 tests passed.
- `swift test --filter PathPreflightTests` — no matching tests.
- `swift test --filter ACPProviderDiscoveryTests` — 7 tests passed.
- `swift test --filter ACPProviderModelProbeTests` — 25 tests in 2 suites passed.
- `swift test --filter FileProviderSetupVerifierTests` — 3 tests passed.
- `swift test --filter CLITantivyLegResolverTests` — 7 tests passed.
- `swift test --filter WikiLinkMenuNSItemsTests` — 7 tests passed.
- `swift test --filter YouTubeTranscriptSubprocessTests` — 14 tests passed.
- `swift test --filter RunAwaitsTurnTests` — 3 tests passed.
- `swift test --filter 'QueueEngineTests|QueueExtractionTests|QueueTranscriptionTests'`
  — 54 tests in 4 suites passed.

Additional debugging/late-suite validation that informed the final fixes:

- `swift test --filter SplitDiffSnapshotTests`
- `swift test --filter EditorAutocompleteHostedTests`
- `swift test --filter 'EditorAutocompleteHostedTests|ComposerAutocompleteHostedTests'`
- a 14-suite late-region subset covering the synchronized timeout zone

**Bare full-suite investigation record.**

- `tmp/test-logs/swift-test-run1-20260726-1538.log` — stalled first at
  `SplitDiffSnapshotTests` while the test still wrote scratch output under
  `/tmp`.
- `tmp/test-logs/swift-test-run1-fixed-20260726-1548.log` — surfaced broad
  300-second suite time-limit failures, which turned out to be queue-time false
  positives from suite-level `.timeLimit(.minutes(5))` annotations.
- `tmp/test-logs/swift-test-run2-final-20260726-1613.log`,
  `tmp/test-logs/swift-test-run2b-final-20260726-1629.log`, and
  `tmp/test-logs/swift-test-run2c-final-20260726-1641.log` — late-suite stalls
  used to isolate the hosted-window lifetime issue and then the retained CLI
  Tantivy service lifetime issue. A live sample of the final stalled helper was
  captured at `tmp/test-logs/swift-test-run2c-sample.txt`.

**Deterministic full-request-key follow-up after `4dc32dab`.**

The initial six-request regression used six real `TantivySearchService` instances
against one writable index, so full-suite load could produce rotating empty hits
that did not prove or disprove request-key discrimination. The follow-up restores
`SearchRetryPolicy.maximumAttempts` from the unjustified 20-attempt escalation to
5 and adds a DEBUG-only async executor inside newly created in-flight tasks. The
test scopes the executor to its unique wiki/container, records all six full
request keys, and returns request-specific sentinel hits; unrelated concurrent
tests fall through to production Tantivy. `withTestSearchExecutor` resets the
injection after both success and thrown failure. The separate nine-search
`concurrentResolversReturnExpectedResults` test remains the real-index async
concurrency smoke test.

Verification:

- `swift test --filter CLITantivyLegResolverTests` — passed twice after final
  scoping: 8 tests in 1 suite; test time 0.877 s and 0.867 s.
- `swift build --build-tests` — passed; build time 8.57 s, real 9.49 s.
- `tmp/test-logs/issue-925-deterministic-seam-full-run1.log` — completed rather
  than stalled, but failed with 15 CLI resolver issues because the first DEBUG
  executor revision intercepted unrelated parallel resolver tests. This exposed
  and led to the unique-wiki/container fallthrough fix; it is not acceptance.
- `tmp/test-logs/issue-925-deterministic-seam-full-run2.log` — timed out after
  700 s. The deterministic regression passed after 5.294 s (log line 7352), and
  no CLI resolver failure was recorded. The log then stopped in the unrelated
  hosted AppKit tail after `AddressBarLayoutHostedTests` passed, with autocomplete
  and quote-highlight hosted work still active. The command-owned orphaned
  `swiftpm-testing-helper` PID 1384 was sent SIGTERM after ownership was confirmed.
  This run is explicitly **not** full-suite acceptance.
- Scoped blocking-pattern audit and `git diff --check` passed. Repository-wide
  `git diff --check` still reports only the unrelated pre-existing trailing
  whitespace in `AGENTS.md:19`.

**Final post-fix acceptance.**

- `swift-test-run1-accept5-20260727-1727.log` — `3956 tests in 332 suites passed after 18.463 seconds`; `/usr/bin/time -p`: `real 23.10`, `user 22.97`, `sys 9.77`.
- `swift-test-run2-accept5-20260727-1728.log` — `3956 tests in 332 suites passed after 17.819 seconds`; `/usr/bin/time -p`: `real 19.04`, `user 20.18`, `sys 9.06`.
- `make test` — after capturing and killing two stalled wrapper-owned helper trees, the final rerun (`tmp/test-logs/make-test-rerun2-20260727.log`) passed: `3956 tests in 332 suites passed after 20.765 seconds`, wrapper epilogue `✓ tests pass`.
- explicit doc guards passed: `PLAN.md` links the issue plan, `progress/` contains this branch entry, and `plans/issue-925-cooperative-pool-starvation.md` exists.
- `git diff --check` still reports unrelated pre-existing trailing whitespace in `AGENTS.md:19`.

**Documentation.** Added
[`plans/issue-925-cooperative-pool-starvation.md`](plans/issue-925-cooperative-pool-starvation.md)
and indexed it from `PLAN.md`. The deep doc records the starvation mechanics,
the four fixed sites, the shared async-process contract, the lazy AppKit
submenu lifecycle, the retained-service follow-up fix, the verification
evidence, and the deferred standalone `wikictl` / `wikid` entry-point audit.

## Verification

Historical verification remains in the progress record above.
