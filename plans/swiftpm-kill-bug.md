# SwiftPM testing-helper session-wide kill bug

## Summary

The `swiftpm-testing-helper` process sends SIGKILL to every process owned by
the current user. This kills Finder, Safari, Paseo, Docker, PostgreSQL, and
all other user processes. The behavior has occurred multiple times.

## Evidence

macOS unified log, 2026-08-13 21:45:23 PDT:

```
exited due to SIGKILL | sent by swiftpm-testing-helper[54870]
```

Affected processes (partial list from launchd log):

- `com.valvesoftware.steam.ipctool`
- `com.apple.uikitsystemapp`
- `com.apple.talagent`
- `com.apple.AppSSOAgent`
- `application.com.docker.docker`
- `com.apple.universalaccessd`
- `com.apple.syncdefaultsd`
- `homebrew.mxcl.postgresql@17`
- `com.apple.geod`
- `com.apple.UserNotificationCenterAgent`

Every killed process shows `sent by swiftpm-testing-helper[54870]`.

## Mechanism

The `swiftpm-testing-helper` binary is part of SwiftPM's test infrastructure.
Swift Testing launches it to run test cases in a separate process. The helper
called `kill(-1, SIGKILL)`, which sends signal 9 to every process the calling
user can signal.

## Context

The test helper (PID 54870) was running Self Driving Wiki tests. The last
logged activity at 21:45:18 was wiki store setup (opening tabs, pruning queue
event logs, loading resources). The mass kill occurred 5 seconds later.

## Containment

Tests now run inside a Tart macOS VM (`make test-vm`). If the test helper
goes rogue, it kills the VM's processes, not the host's.

## Status

- **Root cause:** Unknown. The kill originates inside the SwiftPM test helper
  binary, not in this repository's code. It may be triggered by a crash,
  memory corruption, or uncaught signal in the test process.
- **Upstream:** Not yet filed. Needs a minimal reproduction case.
- **Workaround:** VM-isolated test runs via `make test-vm`.
