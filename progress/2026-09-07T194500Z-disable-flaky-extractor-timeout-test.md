---
timestamp: 2026-09-07T194500Z
title: Disable the load-flaky runtime-entry executor test
branch: chore/disable-flaky-extractor-timeout-test
status: complete
---

# Disable the load-flaky runtime-entry executor test

## Progress

`ManagedExtractorProcessExecutorTests.runtimeEntryAllowsReadable
NonExecutableFile` spawns the fixture runtime and requires it to finish
inside the executor's 5 s wall-clock limit. On a loaded machine, fixture
startup alone can exceed the limit. Observed on clean `main`: about one
failure per three full-suite runs, always this test, always "ran 5.4 s of
the 5.0 s limit … never completed startup".

The test is disabled with a `.disabled` trait and a comment describing the
failure mode and the re-enable condition: a load-tolerant startup budget
(a separate startup phase, or a progress-aware timeout) instead of the
fixed wall clock. The asserted behavior — a readable non-executable
runtime entry point is accepted — is unchanged and still covered by the
suite once re-enabled.

## Verification

- `swift test --filter ManagedExtractorProcessExecutorTests` — 16 tests:
  15 pass, the disabled test is skipped with the documented reason.
