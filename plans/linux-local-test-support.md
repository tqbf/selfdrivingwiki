# Local Linux Swift test support

## Goal

This document describes an opt-in Linux portability diagnostic. Self Driving Wiki
supports macOS only. Linux source portability is best-effort and is not a pull-request
or release gate. The diagnostic preserves the prior Linux test contract and its
retained evidence, including failures such as EINTR; a failure is not a pass.

Issue #1077 added a local command that reproduced the former `linux-swift` diagnostic
contract before a pull request was pushed. The EINTR history is retained in
[`progress/2026-08-09T000000Z-linux-swift-eintr-failure-record.md`](../progress/2026-08-09T000000Z-linux-swift-eintr-failure-record.md).

## Design

`scripts/lib/linux-swift-test-config.sh` is the single source for the optional
Linux diagnostic test filter, worker count, and skip list. The local runner
sources it before it starts a container. No GitHub required check sources it.

`scripts/test-linux.sh` selects Apple `container` when it is installed. It
uses Docker when Apple `container` is unavailable. An explicit runtime request
cannot fall back to another runtime.

The runner uses a digest-pinned Swift 6.3.3 Ubuntu 24.04 image on
`linux/amd64`. This matches GitHub-hosted Ubuntu, rather than the host ARM
image variant. The runner installs `libsqlite3-dev` and `make` inside the
container. GitHub-hosted Ubuntu already provides `make`.

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

This support does not change production targets, SQLite behavior, renderer-store
behavior, `make build`, `make test`, or bare SwiftPM commands. It has no CI
equivalent and remains an optional local diagnostic.
