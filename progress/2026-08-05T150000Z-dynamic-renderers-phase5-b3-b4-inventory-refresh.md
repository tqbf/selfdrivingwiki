---
title: Dynamic renderers Phase 5 B3/B4 inventory refresh
date: 2026-08-05
issue: 1026
phase: 5
---

# Dynamic renderers Phase 5 B3/B4 inventory refresh

This record updates the retained Phase 5 test inventory. The inventory covers
the integrated production range from `a1b1f28b592641dbb26333c58ac4c675dd231ec8`
to `3a07d94f412452e5dab42059b0beb7736c98711c`.

The inventory maps all changed production paths. These paths include the
no-replace move C target, schema v2, activation cleanup, directory validation,
staging recovery, and install-record descriptor guards. The resolver verifies
each mapped path, test name, suite count, and total count.

The portable test imports use Darwin on Darwin and Glibc on Linux. The tests
remain enabled for the Linux CI job and its `renameat2` shim path.

## Deferred recovery

A crash after the no-replace move and before the index commit can leave an
unindexed installed root. The installer lifecycle must reconcile this state
under an exclusive startup barrier or an ownership-and-age lease. This slice
does not add that lifecycle.

The local environment does not provide a Linux runtime. The inventory records
this limit. The portable import boundary and the C shim stay eligible for Linux
CI coverage.
