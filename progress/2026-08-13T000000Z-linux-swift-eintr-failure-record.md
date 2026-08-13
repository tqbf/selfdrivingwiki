---
timestamp: 2026-08-13T000000Z
title: Linux SwiftPM EINTR diagnostic failure record
branch: chore/macos-only-required-gates
status: historical
---

# Linux SwiftPM EINTR diagnostic failure record

## Progress

**Recorded:** 2026-08-12 to 2026-08-13

This record preserves the mixed six-directory retained run set observed while
exercising the former Phase 2 `linux-swift` SwiftPM contract. The candidate was
Phase 2 PR #1093 work, not the later policy branch that records this correction.
The retained set contains EINTR failures before tests, one empty directory, and
passing diagnostics. Failures remain failures and passes remain passes; none is
product-platform support evidence.

## Candidate and environment identity

- Failed candidate branch: `feature/markdown-renderers-02-typed-embeds` (Phase 2
  PR #1093).
- Failed candidate committed head:
  `67f4a60249c3276ec48a21bf4153b0576a5bfb30`.
- Failed candidate tree:
  `390894a1243f66cef62cb1fa810ae7bd1def065f`.
- Failed candidate base:
  `b5f36c2b860cd2c45cb1b3053bc680cf1b8507de`.
- `dirty_diff_sha256`:
  `78f782a5e8ff084620431efecd4a7410892f428c15ba2d3616a91840a9820b6e`.
  This is the SHA-256 of the exact preflight `git diff` retained with the
  candidate evidence. Later candidate changes make recomputation from the
  current worktree differ, as expected.
- Pinned image:
  `docker.io/library/swift@sha256:69bf1f0281e13d82c9e49d67c2dd1dcc8c00bad738c860f4323d7078787ec8ea`.
  The platform was `linux/amd64` under local Docker Desktop on Apple silicon.
- The current `chore/macos-only-required-gates` branch and its policy commit
  `96562d057c27a4c0e9cf5d025029b97fd36c9095` are the later durable recording
  vehicle only. They were not the failed candidate.
- A related retained Phase 5 record used the same image digest on `aarch64`
  and explicitly recorded that the broad `WikiFSCoreTests` filter found zero
  tests; it does not claim a pass:
  `progress/2026-08-05T204818Z-dynamic-renderers-phase5-b3-b4-final-gates.md`.

## Retained six-directory run set

The retained directories are a mixed result set:

| Directory | Command/result |
| --- | --- |
| `20260812T153442Z-67f4a602` | Broad `WikiFSCoreTests` filter: EINTR failure before tests. |
| `20260812T160127Z-67f4a602` | Same broad filter and normal command: 2,444 tests in 217 suites passed in 40.765 seconds; no error lines. |
| `20260812T205238Z-67f4a602` | Focused `WikiFSCoreTests.RendererBridgeContractsTests`: EINTR failure before tests. |
| `20260813T051138Z-67f4a602` | Broad filter: EINTR failure before tests. This is the manifest/digest-bound failure. |
| `20260813T060050Z-67f4a602-serial-j1` | Empty directory; no result claim. |
| `20260813T060442Z-67f4a602-serial-j1-diagnostic` | Pass: no EINTR or code 4, container status 0, and 2,444 tests passed. |

For the specifically manifest-bound `20260813T051138Z-67f4a602` run, the
failure occurred after dependency resolution during
`swift build --target WikiFSCoreTests`; tests never started. Its representative
error path was:

- `/work/.build/x86_64-unknown-linux-gnu/debug/WikiFS_WikiFSCore.resources/wiki-state-chat-reference.md`.

Other resources, including `WikiFS_FuzzHarness.resources/fuzz-dict.txt` and Core
Prompts, appeared only in successful `Copying` lines while scheduling progressed;
they were not error victims. The chronological latest retained result is the
passing serial diagnostic, not a failed run.

The supported inference is narrow: local Linux diagnostics under Docker
Desktop/`linux/amd64` emulation were intermittent; serialization produced a
passing diagnostic, but neither successes nor failures establish Linux as a
supported product platform.

## Retained lifecycle evidence

The lifecycle manifest binds the specifically failed
`20260813T051138Z-67f4a602` run's gitignored evidence files by SHA-256. The
paths are not committed to the repository, but their digests are retained in
the manifest:

- Evidence: `tmp/linux-test/20260813T051138Z-67f4a602/evidence.txt` —
  `5430ec19724ae36046cbb656017e1405c38f6d3b424c4ff74ab742533ae09c68`.
- Runtime log —
  `7879724d355c962ccdf65205610359bab5ce545b0a95e5e5ee459bae44a4298e`.
- Container log —
  `aea61b538024524a5473e7f99705d0397029478ce3bca1693d3bfd5f21b82f12`.
- Toolchain log —
  `5434a810a28730de48fcf2a05a1ca7f02957511b78f4ce4ef8eb40df9fc24616`.

## Policy disposition

The macOS-only required-gate policy changes product acceptance, not historical
results. Linux portability remains an optional diagnostic that requires Apple
Container or Docker. The local Docker Desktop/`linux/amd64` results are
intermittent: the EINTR outcomes remain failed optional diagnostics, and the
serialized diagnostic remains a passing optional diagnostic. Neither outcome is
Linux support evidence. Required product validation remains the macOS `swift`
job and the repository's macOS build/test gates.

## Verification

This durable correction is recorded on the later policy branch. Its failed
candidate, tree/base identities, image, failure stage, representative paths,
and retained-evidence digests are stated above; the gitignored lifecycle files
remain uncommitted and are represented by manifest-bound digests.
