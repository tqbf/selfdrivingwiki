# Opt-in app-test helper exit: highlighting-suite bisect (2026-10-16)

PR #1432 connects the executed-test gate and the run-summary gate to Make and CI. The helper exit still needs a root-cause fix. This note records a negative bisect on the same branch.

## Identify the missing run

The full log `tmp/test-logs/optin-app-tests-reconciled-20261015-205113.log` has 11 run starts and 10 summaries. The third run starts at line 10940 and executes `WikiFSAppTests`. The fourth run starts at line 17128 without a summary for the third run. The missing summary belongs to `WikiFSAppTests`.

The prior lldb capture stopped the app helper (PID 25771) at `exit`. Its main-thread stack was `exit → _swift_exit → swift_task_asyncMainDrainQueue → WikiFSAppTests main (test_entry_point.swift:0) → swiftpm-testing-helper`. Another worker was inside tree-sitter Scala highlighting in `CodeHighlightPerformanceTests.recordsDebugDiagnostics()`.

That snapshot did not show a task spawned by the test. `Tests/WikiFSAppTests/CodeHighlightPerformanceTests.swift:16-69` defines a synchronous test. Its `measure` loop at lines 122-131 calls each operation inline. The Scala highlighter call at lines 44-49 has `isCancelled: { false }`. The test does not create a `Task`, dispatch queue, or subprocess. It writes a measurement file only after all calls return (lines 55-64). In the saved full log, both tests and the suite finish before the app helper exits (lines 16508-16511). The observed worker was inside a test call, not evidence of escaped work.

## Exclude the suspected suite

Command: `scripts/test-optin-app-tests-reconciled.sh --skip CodeHighlightPerformanceTests`

Log: `tmp/test-logs/optin-app-tests-reconciled-20261015-205913.log`. No `CodeHighlightPerformanceTests` test or suite line appears, so the skip took effect. The sentinel executed once. The run-summary gate still counted **11 starts and 10 summaries** and exited 1. The third, app-test run starts at line 10933. The next bundle starts at line 17213 without an app-test summary.

The highlighting suite is not necessary to reproduce this helper exit. Do not change its synchronous measurement loop to structured concurrency. The `scope.parent.invalid` message appeared under `CordisTests`, not on the terminating app-helper stack. No evidence connects it to this exit.

## Next diagnostic

Attach lldb to the app helper before the hosted tests finish. Stop at the Swift Testing runner's completion and event-recording path, not only at `exit`. Capture its plan, outstanding test tasks, and event-delivery state. Compare the last app-test event with the unfinished test list in the full log. Then use smaller `--skip` subsets to isolate the group that changes the result. Do not infer a culprit from one worker stack: the exclusion test already refuted that inference.

No death fix or five-run verification is claimed. The run-summary gate continues to fail this defect loudly.

## Final bounded probe: app bundle alone

Toolchain: Apple Swift 6.4 (`swiftlang-6.4.0.34.1`), Testing Library Version 2084. `Package.resolved` does not pin Swift Testing. The library ships with the toolchain.

`WIKIFS_APP_TESTS=1 swift test --parallel --num-workers 1 --filter WikiFSAppTests` reproduced twice. Each invocation printed one `Test run started.`, no `Test run with …` summary, and returned 0. This bypasses the guarded runner for diagnosis only. Logs: `tmp/issue1422-alone1.log` and `tmp/issue1422-alone-capture.log`.

lldb attached to the app helper PID 71729. A scoped `libsystem_c.dylib` breakpoint stopped the main thread at `exit`. Full `bt` showed `exit → _swift_exit → swift_task_asyncMainDrainQueue → WikiFSAppTests main at test_entry_point.swift:0 → swiftpm-testing-helper`. `thread backtrace all` captured other active threads. `frame variable` produced no useful state. No run summary appeared in stdout before the stop or after detach. The physical stack has no Swift Testing runner frame between the drain function and `exit`: the suspended async call chain cannot identify the runner decision from this stop alone. See ignored `tmp/issue1422-alone-lldb.log`.

### Suite groups

`swift test list` found 314 app-suite identifiers. Disjoint filters used the listed `WikiFSAppTests.<suite>/` names. Every reproducing group executed tests, so these are not empty-filter results.

| App suite group | Suites | Starts / summaries | Exit | Interpretation |
| --- | ---: | ---: | ---: | --- |
| All app suites, twice | 314 | 1 / 0 each | 0 | Target reproduced. |
| Alphabetic first half | 157 | 1 / 0 | 1 | Separate `AppearanceSettingsHostedTests` assertion and index-out-of-range signal 5 confound this run. |
| Alphabetic second half | 157 | 1 / 0 | 0 | Target reproduced. |
| First quarter of second half | 78 | 1 / 0 | 0 | Target reproduced. |
| Second quarter of second half | 79 | 1 / 1 | 1 | 52 test issues. It did not show the silent exit. |
| First eighth of second half's first quarter | 39 | 1 / 0 | 0 | Target reproduced. |
| Second eighth of that quarter | 39 | 1 / 0 | 0 | Target reproduced independently. |
| Sentinel suite alone | 1 | 1 / 1 | 0 | Small control summarized. |

The two disjoint 39-suite groups had different unfinished tests. This bisection does not isolate one suite. It suggests multiple sufficient triggers or a runner/load interaction. The first-half signal-5 crash is a distinct defect and not evidence for this exit-0 mechanism.

### Time limits and next step

Upstream Swift Testing documents suite `.timeLimit` as a limit on **each test case**, not the suite as a whole. Its runner records `.timeLimitExceeded` as a test issue and posts `runEnded` after its test task group completes. The reproducing 39-suite logs show no time-limit issue. These are upstream-main semantics, not a source-level match to installed Testing 2084. DeepWiki returned `Repository not found` for `apple/swift-testing`, so it supplied no evidence.

The next useful capture is an async task backtrace or instrumented Testing event stream before `Runner.run` returns. Break on the installed library's `runEnded` event and inspect the event handler and outstanding test tasks. Compare a 39-suite deficit run with the one-suite control. Do not infer the caller of `_swift_exit` from the C stack, which cannot cross the async drain boundary. The root cause and five consecutive clean full runs remain open.
