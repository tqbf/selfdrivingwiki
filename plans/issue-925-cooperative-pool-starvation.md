# Issue #925: Cooperative Pool Starvation

## Summary

Issue #925 was an integration bug, not one bad call site in isolation. Four
different synchronous bridges were parking work inside the app's process:

1. `CLITantivyLegResolver` used a semaphore bridge around Tantivy search.
2. `PathPreflight` synchronously waited for a login-shell PATH probe.
3. `FileProviderSetupVerifier` synchronously waited for PluginKit subprocesses.
4. `WikiStoreModel` synchronously bridged async Tantivy-backed "Suggest…"/"Find Similar…"
   menu search onto the main actor.

Each bridge could look locally harmless, but together they consumed
cooperative-thread-pool workers and blocked the main actor at exactly the
places where the test suite fans out concurrent async work. The visible symptom
was not "one search test is slow"; it was unrelated suites stalling together,
because they were all sharing the same exhausted runtime resources.

## Why Unrelated Suites Stalled Together

The failing shape in #925 was cooperative-pool starvation:

- A task on the cooperative pool called into a blocking bridge.
- That bridge parked the current thread instead of suspending the task.
- Enough of those blocked workers accumulated that unrelated async work no
  longer had a worker to resume on.
- The late symptom appeared in whatever suite was waiting next, not
  necessarily the suite that introduced the blocking call.

That is why the original failures looked misleadingly broad: full-suite runs
would freeze in different late regions, and raising time limits only changed
where the symptom surfaced.

## Why `Task.detached` and Longer Timeouts Are Not Fixes

`Task.detached` can move blocking work off the caller's actor, but it does not
turn blocking into suspension. A detached task that calls `waitUntilExit()`,
`DispatchSemaphore.wait()`, or blocking pipe reads still occupies a real thread.
That can hide the problem in a focused test while leaving the full suite free
to starve later.

Longer timeouts are even worse for this class of bug: they make the suite wait
longer for a task that may never resume. The fix had to remove the blocking
bridges themselves, not stretch the watchdog.

## Fixed Site 1: Async CLI Tantivy Resolution

`Sources/WikiCtlCore/CLITantivyLegResolver.swift` now resolves page, source,
and chat BM25 legs asynchronously end to end. The old semaphore/result-box
bridge is gone.

The final integrated version has one additional lifetime fix beyond the
original async conversion: concurrent calls now coalesce only while a search is
actually in flight. The first reconstruction retained a process-global cache of
`TantivySearchService` instances keyed by temporary test containers; that kept
many Tantivy services, index watchers, and file handles alive for the whole
`swift test` host lifetime and caused a late full-suite stall. The fix was to
deduplicate active work rather than retain completed services indefinitely.

Current contract:

- `resolvePageLeg`, `resolveSourceLeg`, and `resolveChatLeg` are `async`.
- Overlapping searches for the same `(wikiID, containerDirectory)` share one
  in-flight task.
- Completed searches release their `TantivySearchService`, so temp test
  indexes are not pinned for the rest of the process.
- Rank order and nil semantics are preserved.

## Fixed Site 2: Async Login-Shell PATH Resolution

`Sources/WikiFSCore/Core/PathPreflight.swift` and the production callers that
depend on it now acquire login-shell PATH asynchronously through the shared
`AsyncProcessRunner`.

Current contract:

- `loginShellPATH` is async.
- `resolveOnLoginShell` is async and still falls back to process `PATH` if the
  shell probe fails.
- Production call sites await PATH at existing async boundaries rather than
  hiding synchronous shell work under `Task.detached`.
- Pure/injected resolver seams stay synchronous for deterministic tests.

## Fixed Site 3: Async PluginKit Verification

`Sources/WikiFS/Window/FileProviderSetupVerifier.swift` now runs PluginKit
queries and repair commands through the shared process runner rather than
`Process.waitUntilExit()`.

Current contract:

- unregister/add/enable ordering is preserved.
- combined stdout/stderr diagnostics are preserved.
- nonzero exits still surface as verifier failures.
- no blocking subprocess wait remains in the verifier path.

## Fixed Site 4: Lazy Async AppKit Similar-Page Menus

`Sources/WikiFSCore/Store/WikiStoreModel.swift` no longer contains the old
synchronous Tantivy bridge for similar-page search, and
`Sources/WikiFS/Reader/WikiLinkMenuNSItems.swift` no longer blocks the main
actor to populate "Suggest…" / "Find Similar…".

Current menu lifecycle:

- context-menu construction stays synchronous because AppKit requires that.
- the submenu starts as one disabled `Searching…` row.
- `SimilarPagesMenuLoader` starts exactly one async search when AppKit opens
  the submenu.
- completion replaces the placeholder with ranked pages, or with one disabled
  `No similar pages` row.
- closing the menu cancels in-flight work and invalidates stale completion via
  a generation token.

This preserves native AppKit behavior while removing the main-thread wait.

## Shared Async Process Runner Guarantees

The shared runner introduced for #925 lives in `WikiFSCore` and is the
production contract for in-process subprocess work:

- completion is driven by `Process.terminationHandler` plus a checked
  continuation.
- stdout/stderr are drained continuously without waiting for process exit to
  start reading.
- cleanup uses serialized stream shutdown and bounded final drain logic rather
  than `readDataToEndOfFile()` / `readToEnd()`.
- cancellation terminates the launched process, escalates if needed, and still
  guarantees exactly-once completion.
- callers do not use `waitUntilExit()`, semaphore bridges, or detached wrappers
  just to hide blocking subprocess work.

## Additional Integration Fixes Found During Verification

The reconstructed stack needed three extra fixes during Phase 5 verification:

1. `Sources/WikiFSEngine/QueueEngine.swift` now cancels `runningTasks` and
   resumes `waitForCompletion` continuations with `CancellationError()` in
   `deinit`, fixing a full-suite teardown stall where waiters could outlive the
   engine.
2. `Sources/WikiFSEngine/AgentLauncher.swift` now clears `currentRunToken`
   whenever a run finishes or resets artifacts, fixing a stale `onExit`
   disarm/teardown race that broke `RunAwaitsTurnTests`.
3. AppKit-hosted autocomplete tests now retain their `NSWindow` long enough for
   the hosted editor/composer interaction to settle under full-suite pressure,
   and the editor/composer hosted suites now share an async test gate so Swift
   Testing does not overlap their window-owning flows during the full matrix.

These were not new design work; they were integration fallout exposed by the
same "run the entire suite twice" acceptance gate.

## Pattern Audit

The scoped #925 audit is:

- `CLITantivyLegResolver.swift`: no `DispatchSemaphore`, no `.wait(`, no
  `SearchBox`, no `Task.detached`.
- `WikiStoreModel.swift` Tantivy path: no `resolveTantivyLegSync`, no
  `TantivyLegBox`, no `DispatchSemaphore`.
- `PathPreflight.swift`: no `waitUntilExit`, no blocking tail reads.
- `FileProviderSetupVerifier.swift`: no `waitUntilExit`, no detached wrapper
  around blocking subprocess work.

The wider repo still contains other blocking-style APIs in out-of-scope or
non-test-reachable areas. The notable example found during audit was
`HelperPodcastTokenProvider`, which still uses blocking `readDataToEndOfFile`.
That is intentionally recorded here as separate follow-up work rather than
silently folded into #925.

## Verification

### Focused build and regression suites

Verified on `fix/cooperative-pool-starvation` with:

- `swift build --build-tests`
- `swift test --filter AsyncProcessRunnerTests`
- `swift test --filter PathPreflightTests`
- `swift test --filter ACPProviderDiscoveryTests`
- `swift test --filter ACPProviderModelProbeTests`
- `swift test --filter FileProviderSetupVerifierTests`
- `swift test --filter CLITantivyLegResolverTests`
- `swift test --filter WikiLinkMenuNSItemsTests`
- `swift test --filter YouTubeTranscriptSubprocessTests`
- `swift test --filter RunAwaitsTurnTests`
- `swift test --filter 'QueueEngineTests|QueueExtractionTests|QueueTranscriptionTests'`

Additional full-suite debugging validation during integration included:

- `swift test --filter SplitDiffSnapshotTests`
- `swift test --filter EditorAutocompleteHostedTests`
- `swift test --filter 'EditorAutocompleteHostedTests|ComposerAutocompleteHostedTests'`
- a late-suite subset covering the previously synchronized timeout region

### Full-suite acceptance

Pre-fix bare full-suite behavior:

- one full `swift test` pass completed
- subsequent bare runs stalled in late-suite regions
- captured logs live under `tmp/test-logs/`
- the final root cause fixed after those captures was the retained CLI Tantivy
  service cache described above

Final post-fix acceptance on the integrated branch:

- `swift-test-run1-accept5-20260727-1727.log`: `Test run with 3956 tests in 332 suites passed after 18.463 seconds.` `/usr/bin/time -p`: `real 23.10`, `user 22.97`, `sys 9.77`.
- `swift-test-run2-accept5-20260727-1728.log`: `Test run with 3956 tests in 332 suites passed after 17.819 seconds.` `/usr/bin/time -p`: `real 19.04`, `user 20.18`, `sys 9.06`.
- `make test`: initial wrapper run stalled in the same hosted-AppKit/WebKit idle shape captured at `tmp/test-logs/make-test-stall-20260727-helper-sample.txt` and `tmp/test-logs/make-test-rerun-stall-20260727-helper-sample.txt`; after adding `AutocompleteHostedTestGate`, `tmp/test-logs/make-test-rerun2-20260727.log` passed with `Test run with 3956 tests in 332 suites passed after 20.765 seconds.` and wrapper epilogue `✓ tests pass`.

### Guard checks

Final integration guard commands:

- `rg -n 'issue-925-cooperative-pool-starvation\\.md' PLAN.md && rg -n '^## fix: cooperative-pool starvation \\(#925\\)' PROGRESS.md && test -f plans/issue-925-cooperative-pool-starvation.md` → passed.
- `git diff --check`: failed only on unrelated pre-existing trailing whitespace in `AGENTS.md:19`.

## Deferred Standalone CLI/Daemon Audit

Issue #925 intentionally scoped only in-process blocking sites that are
reachable from the app and `swift test`. Standalone entry-point synchronization
in `Sources/wikictl/main.swift` and `Sources/wikid/main.swift` remains a
separate audit item unless required for compilation by one of the four in-scope
fixes.

That distinction matters because a standalone CLI bridge can still be ugly
without starving the app's cooperative pool. This document records the deferral
so a future audit can tackle those entry points explicitly rather than assuming
#925 covered them.
