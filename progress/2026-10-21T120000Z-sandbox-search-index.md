---
timestamp: 2026-10-21T12:00:00Z
title: Allow cold CLI search in the chat sandbox
branch: bugfix/1457-sandbox-search-index
status: complete
---

# Allow cold CLI search in the chat sandbox

## Progress

- Addressed issue #1457. The chat sandbox now permits writes to the active wiki's derived search index.
- The profile permits creation of the shared `search-index` directory, but not writes to sibling wiki indexes.
- Search paths derive from the active database path and use the existing canonicalization helper.
- Read-only profiles remain unchanged. No new write permission applies to unrelated App Group files.
- Added profile assertions and a live Seatbelt test. The test starts without the shared index directory and finds a seeded page.
- CLI failure reporting remains unchanged. The resolver still treats an unavailable index as an absent lexical search leg.

## Verification

- `make build` passed.
- Profile tests passed after their expected parameter counts were updated.
- The live cold-search test passed with `WIKIFS_APP_TESTS=1`.
- The live test also confirmed that sibling index creation and unrelated container writes fail.
- Language-server diagnostics reported no issues in `SandboxProfile.swift`.
- `make test` passed, including 4,663 tests in its main test executable and the remaining test executables.
- `WIKIFS_APP_TESTS=1 swift test --filter 'AgentSandboxProcessTests|ACPWiringTests'` passed all 64 tests.
