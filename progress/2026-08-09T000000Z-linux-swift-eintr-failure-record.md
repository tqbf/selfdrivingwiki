---
timestamp: 2026-08-09T000000Z
title: Linux SwiftPM EINTR diagnostic failure record
branch: chore/macos-only-required-gates
status: historical
---

# Linux SwiftPM EINTR diagnostic failure record

## Progress

**Recorded:** 2026-08-09

This record preserves repeated failures observed while exercising the former
Phase 2 `linux-swift` SwiftPM contract. The failures occurred before the test
suite could run: the container completed checkout and entered the generated
resource and SwiftPM build setup, then SwiftPM reported an interrupted system
call (`EINTR`) while reading or writing generated/build resources. These are
failed diagnostics, not passing portability evidence.

## Candidate and environment identity

- Candidate under review: `96562d057c27a4c0e9cf5d025029b97fd36c9095`
  (`chore/macos-only-required-gates`).
- Pinned candidate image: `docker.io/library/swift@sha256:69bf1f0281e13d82c9e49d67c2dd1dcc8c00bad738c860f4323d7078787ec8ea`
  (`swift:6.3.3-noble`, Ubuntu 24.04, `linux/amd64` for the current runner).
- A related retained Phase 5 record used the same digest on `aarch64` and
  explicitly recorded that the broad `WikiFSCoreTests` filter found zero tests;
  it does not claim a pass: `progress/2026-08-05T204818Z-dynamic-renderers-phase5-b3-b4-final-gates.md`.
- No retained `tmp/linux-test/` directory, runtime log, container log, or
  evidence-file digest for the repeated EINTR runs is present in this checkout.
  The absence is recorded rather than replaced with an invented digest.

## Failure stage and representative paths

The failure stage was before tests: after `make version prompts keychain` and
before the `swift test` invocation. The diagnostic's generated/build inputs
include:

- `Sources/WikiFSCore/GeneratedVersion.swift` (gitignored version output);
- `Sources/WikiFSCore/GeneratedKeychain.swift` (gitignored keychain output);
- `Sources/WikiFSCore/Resources/Prompts/` (checked-in prompt resource copies);
- the container-local `/work/.build/` SwiftPM build and generated-resource
  paths.

The exact interrupted operation was not retained in a repository artifact, so
this record does not claim a more specific file-level cause than SwiftPM's
pre-test generated-resource/build stage.

## Policy disposition

The macOS-only required-gate policy changes product acceptance, not historical
results. Linux portability remains an optional diagnostic that requires Apple
Container or Docker. Repeated EINTR outcomes remain failed optional
diagnostics and are not relabeled as passes, waived failures, or successful
portable-test evidence. Required product validation remains the macOS `swift`
job and the repository's macOS build/test gates.

## Verification

This durable record was added to the repository on 2026-08-09. Its candidate,
image, failure-stage, generated-path, and retained-evidence statements are
intentionally limited to the evidence listed above.
