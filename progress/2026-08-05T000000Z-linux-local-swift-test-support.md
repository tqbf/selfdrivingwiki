---
timestamp: 2026-08-05T000000Z
title: Add local Linux Swift test support
branch: feat/linux-test-support
status: complete
---

# Add local Linux Swift test support

## Progress

Issue #1077 adds a local Linux runner for the portable Swift test suite. The
runner uses a pinned Swift 6.3.3 Ubuntu 24.04 image and selects Apple
`container` before Docker. An explicit runtime request does not fall back.

The GitHub Linux job and local runner now use one shared test configuration.
The runner stores evidence and logs in `tmp/linux-test/`. It mounts the
checkout read-only and runs code generation and tests in a container copy. The
real Docker run showed that the official Swift image lacks `make`. The runner
now installs `make` with `libsqlite3-dev`, like the GitHub Ubuntu runner.
The first ARM Linux Docker run also showed 22 typecheck-fixture failures from
the `arm64` versus `aarch64` target spelling. The runner now fixes the image
platform to `linux/amd64`, which matches GitHub-hosted Ubuntu.

## Verification

`bash -n scripts/test-linux.sh scripts/lib/linux-swift-test-config.sh` passed.
`make -n test-linux-focus TEST_FILTER=WikiFSCoreTests.RendererStoreTests`
passed. `make test-linux` passed in Docker on `linux/amd64`: 2,307 tests in
191 suites passed. Evidence:
`tmp/linux-test/20260805T163249Z-af083f52/evidence.txt`.
