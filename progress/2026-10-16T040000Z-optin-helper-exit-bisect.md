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
