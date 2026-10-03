---
timestamp: 2026-10-02T172500Z
title: Wiki strategies and cumulative ingestion
branch: feature/wiki-strategies-cumulative-ingestion
status: active
---

# Wiki strategies and cumulative ingestion

## Progress

The repository was clean on `main` before branch creation. The approved scope covers strategy persistence, request capture, mounted projection, the editor, cumulative writes, and evaluation infrastructure.

- GRDB schema head was version 55 at implementation start.
- The mutation seam uses `unsafeReentrantWrite` and savepoints, not the older SQLite lock API.
- One-shot operations stage a captured state document.
- Interactive chat also has warm-session follow-up paths that need per-turn strategy context.
- File Provider root documents use stable identities and a request-scoped read connection.
- Existing snapshot tests live in `AgentStagingTests` and `BookmarkStateSnapshotTests`.
- `make version prompts` completed before integration builds.

The shared strategy renderer and optional snapshot field are added. Default snapshots omit the new section. Custom strategy context appears before the inventory. The design document and user-guide page describe precedence, template behavior, and semantic limits. Persistence, atomic upsert, request capture, projection, editor, prompt validation, and both harnesses have separate implementation tasks.

Completed code tasks, still unverified, include strategy persistence, strategy projection, request capture, atomic upsert, and the first editor implementation. Active corrections cover visible editor switch workflows, strict pipeline assertions, production assignment resolver wiring, and test fixture hygiene. The live evaluation runner and explicit disposable-database selector are still under implementation.

## Verification

No new Swift tests or full build gates have passed yet. The first `make build` failed on the incomplete Strategy detail-view route. The editor task then added that route. The first targeted `swift test` compile failed on an old CLI page-add pattern. That pattern is updated. The retry failed on an unused mutation result after link helpers changed their return type. The atomic-write task owns the correction. No tests executed in these failed compile attempts.

The third targeted compile failed on a Swift Testing macro around a key-path `allSatisfy` call in the pipeline harness. The pipeline correction task replaced that assertion. The fourth compile failed on an invalid `break` in an atomicity test catch block. The parent replaced it with `return`. The fifth compile caught the wiki-switch workflow during an edit, before its helper landed. No targeted tests have executed yet. The active implementation tasks must stabilize before the next compile.

No live semantic evaluation has run. No human rubric decision exists yet. No phase commits, push, PR, independent implementation review, full gates, or live semantic results exist yet. The implementation is not release-ready. Do not mark the saved goal complete until the approved acceptance criteria are checked. Later entries or updates must record actual command results, review findings, and unresolved blockers.
