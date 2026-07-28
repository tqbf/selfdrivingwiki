---
timestamp: 2026-07-26T185303Z
title: "refactor: finish the strong-typed-id conversion, `make test` green (3911 tests / 328 suites)"
branch: null
status: historical
timestamp_source: git-commit
---

# refactor: finish the strong-typed-id conversion, `make test` green (3911 tests / 328 suites)

## Progress


**Goal:** the `refactor/strong-typed-ids` branch had converted `QueueItem.id`
from `String` to `QueueItemID` (a `RawRepresentable` wrapper, matching
`PageID`/`WikiID`/`ProviderID`/`AcpSessionID`), but `swift build --build-tests`
didn't compile — 8 test files in `Tests/WikiFSAppTests/` still passed/compared
raw `String` where `QueueItem.ID` is now required.

**Compile fallout (mechanical, no behavior change):** wrapped every bare
string literal handed to a `QueueItem.ID`-typed parameter with
`QueueItemID(rawValue:)`, matching the existing `PageID(rawValue:)`
convention already used throughout the same files. Fixed a protocol
conformance drift (`FakeIngestionProvider`'s `queueItemID` params were still
`String`) and a few `.rawValue` unwraps at XPC/wire boundaries that correctly
stay `String` (`WikiDaemonWorkloadHostTests`'s JSON-decoded item id).

**Real bugs found once it compiled.** `QueueItemID`/`WikiID`/`ProviderID`
don't conform to `CustomStringConvertible` — so `"\(id)"` silently compiles
and prints `WikiID(rawValue: "01ABC…")` instead of the raw ULID, rather than
failing to build. This is exactly the failure mode the strong-typed-id
refactor exists to prevent, just relocated from "wrong string" to "wrong
string via a different spelling mistake." Found by running the full suite:
`WikiDaemonTests.createWikiCreatesDBFile` failed on a garbled sqlite path,
and `createWikiSeedsHomePage` **crashed the whole test binary**
(`pages[0]` on an empty array — the DB the test thought it was checking was
never created). Swept the rest of the suite for the same pattern before
re-running rather than fixing crashes one at a time:
`WikiDaemonTests.swift`, `WikiRegistryTests.swift`, `SessionManagerTests.swift`,
`WikiRegistryClientTests.swift` (13 sites — this file's DB-path construction
was almost entirely broken) all had `"\(descriptor.id).sqlite"` where
production code correctly uses `id.rawValue`; production itself
(`WikiDaemon.databaseURL(forWikiID:)`, `WikiDescriptor.dbFileName`) was
already right, so only tests were actually broken. Also fixed two
self-consistent-but-wrong production sites while auditing (`AgentLauncher`'s
per-provider scratch-dir name, `ProviderSelector`'s picker row ids) — both
compared only against themselves so they weren't user-visible bugs, but were
the same anti-pattern.

**Build:** `swift build --build-tests && make test` — full suite green.

## Verification

Historical verification remains in the progress record above.
