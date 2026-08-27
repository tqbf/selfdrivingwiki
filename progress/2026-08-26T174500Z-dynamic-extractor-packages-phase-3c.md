---
timestamp: 2026-08-26T174500Z
title: Dynamic extractor packages Phase 3c package authoring tool
branch: feature/dynamic-extractor-packages
status: complete
---

# Dynamic extractor packages Phase 3c package authoring tool

## Progress

Phase 3c adds the extractor package authoring tool.

- `ExtractorPackageToolCore` provides typed command parsing, validation output, and failures.
- `extractor-package-tool validate <package-folder>` validates one local package in an isolated temporary store.
- Validation reports the package ID, version, exact digest, protocol revision, and sorted registration IDs.
- `extractor-package-tool protocol-smoke <package-folder> <request.json> <frames.jsonl>` checks protocol fixtures without running package code.
- Protocol smoke checks request decoding, package protocol compatibility, kind and MIME registration support, JSON Lines framing, request identity, output path, progress limits, and one terminal frame.
- Request and frame fixture reads are descriptor-based, size-bounded, identity-checked, and no-follow.
- Every command removes its isolated validation root on success and failure.
- The executable writes one sorted JSON result to standard output. It writes stable diagnostics to standard error.

## Verification

The following gates passed on 2026-08-26:

```text
swift build --product extractor-package-tool
swift test --filter 'ExtractorPackageToolCoreTests|ExtractorPackageToolSubprocessTests'
8 tests passed

make lint
swift build
git diff --check
```

The tests prove that validation does not execute the package entry point. They also cover malformed frames, request mismatch, output-path mismatch, missing terminal frames, symlinked fixture files, cleanup failures, subprocess output, and subprocess exit status.

LSP diagnostics are clear for the tool core, executable, and tests.
