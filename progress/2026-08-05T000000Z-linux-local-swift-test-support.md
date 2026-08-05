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
checkout read-only and runs code generation and tests in a container copy.

## Verification

`bash -n scripts/test-linux.sh scripts/lib/linux-swift-test-config.sh` passed.
`make -n test-linux-focus TEST_FILTER=WikiFSCoreTests.RendererStoreTests`
passed. Docker was installed but its daemon was unavailable in this workspace.
