# Local Linux Swift test support

## Goal

Issue #1077 adds a local command that reproduces the portable `linux-swift`
CI test contract before a pull request is pushed.

## Design

`scripts/lib/linux-swift-test-config.sh` is the single source for the Linux
test filter, worker count, and skip list. The GitHub workflow sources it. The
local runner sources it before it starts a container.

`scripts/test-linux.sh` selects Apple `container` when it is installed. It
uses Docker when Apple `container` is unavailable. An explicit runtime request
cannot fall back to another runtime.

The runner uses a digest-pinned Swift 6.3.3 Ubuntu 24.04 image. This is
compatible with the CI job's Ubuntu and Swift 6.3 environment. The runner
installs the CI system dependency, `libsqlite3-dev`, inside the container.

The checkout mounts read-only at `/workspace`. The runner copies it to `/work`
inside the container. Code generation, build products, and package resolution
cannot change the host checkout or its macOS `.build` directory.

The runner records its inputs and Linux Swift version in `tmp/linux-test/`.
It keeps the runtime and verbose test logs after all outcomes.

## Commands

- `make test-linux` runs the complete portable suite.
- `make test-linux-focus TEST_FILTER=WikiFSCoreTests.<suite>` runs a focused
  portable suite.

## Non-goals

This support does not replace GitHub Actions. It does not change production
targets, SQLite behavior, renderer-store behavior, `make build`, `make test`,
or bare SwiftPM commands.
