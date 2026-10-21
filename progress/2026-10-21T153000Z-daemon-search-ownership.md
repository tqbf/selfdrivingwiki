---
timestamp: 2026-10-21T15:30:00Z
title: Move persistent search ownership to the daemon
branch: bugfix/concurrent-cli-search
status: complete
---

# Move persistent search ownership to the daemon

## Progress

- Read the retry in chat `01M5EBKEHSASW2G0RKTW5EY9T1`, wiki `01M41BV9H7N34EAW18R7G9SQEP`.
- Runtime logs show six concurrent CLI searches at 15:05:56 UTC. Writer-lock conflicts caused false zero-result reports.
- The recovery path treated failed opens as corruption and removed shared index files. Removed that recovery path.
- The Tantivy dependency acquires a writer on every open and has no reader-only API.
- Rejected a temporary-index implementation after the operator requested a design without workarounds.
- The target design gives the daemon one persistent runtime per wiki. App and CLI clients use search and autocomplete RPCs.
- Production app sessions now accept an injected search facade instead of starting a local writer.
- Removed agent sandbox write access to the search index. The daemon does not require that permission.
- Design: `plans/daemon-search-ownership.md`.

## Verification

- The rejected temporary-index implementation passed its targeted tests, but that result does not verify the daemon migration.
- A focused test confirms a competing writer open throws without removing files or breaking the original writer.
- Final `make build` passed and assembled the signed app.
- Final `make test` passed, including 4,663 main-suite tests and the package suites.
- `WIKIFS_APP_TESTS=1 swift test --filter 'DaemonSearch|CLITantivyLegResolver|TantivyIndexerOpenFailure|AgentSandboxProcessTests'` passed all 48 tests.
- Focused cases cover concurrent startup, external SQLite writes, autocomplete, close and reopen, transport timeout, malformed replies, and sandboxed CLI failure reporting.
- This session did not install the new app or repeat the original chat in the running app. The installed app still uses the earlier build.
