---
timestamp: 2026-08-14T010000Z
title: App Group id resolution fails fast instead of using a compiled-in default
branch: feature/fail-fast-app-group-resolution
status: complete
---

# App Group id resolution fails fast instead of using a compiled-in default

## Progress

`WikiIdentifiers` resolved `appGroupID` from five sources, first hit wins: an
environment variable, the `Bundle.main` Info.plist, a `wiki-identifiers.env`
sidecar next to the executable, `signing/local.config`, then a compiled-in
default of `group.org.sockpuppet.wiki`.

The last leg did not fail. It forked.

`DatabaseLocation.appGroupContainerDirectory()` is the one function that turns
the resolved id into filesystem state, and it calls
`createDirectory(withIntermediateDirectories: true)`. When resolution missed, it
made a second, empty container and continued. The process then read an empty
registry and wrote real config into the wrong place. That looks exactly like a
first run, so nothing reported a problem.

This machine holds the evidence. `~/Library/Group Containers/` contains both the
real `group.com.jjpdev.wiki`, which `containermanagerd` owns and protects, and a
plain `group.org.sockpuppet.wiki` that our own code created. The second one holds
an `agent-providers.json` written on 2026-08-13 with an empty `providerModels`
map, while the real container holds the populated one. Something resolved the
wrong group and reset provider config into it.

The failure has appeared in at least four launch contexts:

| Context | Fix applied at the time |
| --- | --- |
| `.build/debug/wikictl` dev CLI | added the `signing/local.config` leg |
| Search reindex reading an empty container | same root cause, same date |
| Nested `wikid.xpc` daemon (#887) | added the enclosing-`.app` sidecar candidate |
| `PATH` symlink shim | resolved symlinks when building candidate directories |

Every fix added another resolution leg. No added leg can stop the next launch
context from forking the same way, because the fallback is what makes a miss
silent.

Three properties made this hard to see:

1. The default is a plausible real identity. It is the upstream author's
   registered App Group, not an obviously-wrong sentinel, so it looks correct in
   a log.
2. The failure creates state instead of refusing, so a later reader cannot tell
   a wrong container from a new one.
3. The error surfaces far from the cause, as `no wiki matching <id> in the
   registry`, which reads as an empty registry.

## Changes

`WikiIdentifiers.resolve` now returns the value AND which leg produced it, as a
`ResolutionSource`. The four stated legs report `isExplicit == true`. The
compiled-in default reports `false`. Any explicit source counts as configured,
including the Info.plist key `build.sh` injects, because the build echoes the
group it used and that path is visible.

`DatabaseLocation.appGroupContainerDirectory()` throws
`WikiIdentifiersError.unconfiguredAppGroupID` when the id is not configured. The
guard runs before `createDirectory`, so a refusal leaves the filesystem
untouched. There is no correct behavior when the id is unknown: reading or
writing another installation's container is worse than refusing to start.

The error carries instructions, not a code. It names all four sources that were
checked, names the fallback it declined to use, and gives three ways to fix it.
It also conforms to `CustomStringConvertible`, because the CLI and the daemon
report failures with `"\(error)"`, which uses `String(describing:)` and printed
the raw enum case.

Diagnostics make a wrong-but-resolved container visible:

- `wikictl version` prints the App Group id and which leg produced it. `--json`
  adds `appGroupID`, `appGroupIDSource`, and `appGroupIDConfigured`. `version`
  needs no wiki, so it still answers when every other command fails.
- The `wikid` startup log records `source=` beside the existing `appGroup=` and
  `container=`.

Build-time defaults in `build.sh` and the `Makefile` are unchanged. A default is
harmless there because the build prints the group it used.

## What this does not do

It does not delete the stray `~/Library/Group Containers/group.org.sockpuppet.wiki`
container on this machine. That is existing state and removing it is the
operator's call.

## Verification

- `make build` — clean.
- `make test` — 3291 tests in 297 suites pass. No test depended on the
  compiled-in container default, which confirms the stated reason for keeping it
  was not load-bearing.
- `Tests/WikiFSTests/AppGroupResolutionFailFastTests.swift` — 9 new tests.
  `appGroupContainerDirectory` gains a seam that takes the id, the configured
  flag, and the home directory, because the real resolution is a `static let`
  fixed at process start. The tests cover the refusal, that the refusal creates
  no directory at all, that a configured id still resolves and is idempotent,
  that the default constant is allowed when somebody states it explicitly, the
  `isExplicit` split, distinct raw values for diagnostics, and that the message
  is actionable through `localizedDescription`, `"\(error)"`, and `description`.
- Checked by hand. A copy of `wikictl` placed outside the repo, with no sidecar
  and no `signing/local.config` in any parent, prints the full instructions and
  exits 1 on `wiki list`. It previously created a container and reported an
  empty registry. `wikictl version` on the same copy reports
  `group from: compiled-in default (NOT configured)` and a warning.
- `make lint` did not run. `swiftlint` is not installed on this machine. The
  changes add no bare `try?`, which is the only rule it enforces.
