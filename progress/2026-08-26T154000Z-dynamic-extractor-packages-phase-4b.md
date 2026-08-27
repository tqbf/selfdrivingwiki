---
timestamp: 2026-08-26T154000Z
title: Dynamic extractor packages Phase 4b process-backed adapter
branch: feature/dynamic-extractor-packages
status: complete
---

# Dynamic extractor packages Phase 4b process-backed adapter

## Progress

Phase 4b adds the process-backed extractor adapter between installed packages and existing extraction surfaces.

- `ProcessExtractorProvider` prepares one exact revision after rechecking admission twice around the authoritative catalog read.
- Preparation pins a validated snapshot into a private operation directory (`input`, `output`, `home`, `tmp`, `cache`, `package`) using the secure materialization primitive from 256e1083.
- `PreparedProcessOperation` owns that directory. Concurrent conversions use disjoint request-scoped subdirectories over the immutable snapshot, and the tree is removed when the operation dies.
- `ProcessPackagePDFExtractor` conforms to `MarkdownExtractor`: readiness probes entry-point executability plus runtime presence without downloads or conversions, progress frames stream through the existing `onProgress` seam, terminal failure frames surface their cause and message, and size or encoding mismatches throw typed errors so callers fall back.
- `ProcessPackageHTMLExtractor` conforms to `HtmlMarkdownExtractor`: result article metadata (added to protocol v1 additively) maps onto `HtmlExtractionResult`, and every failure path returns nil to trigger tag-based fallback.
- PDF preparations carry an interim `.localPdf2md` compatibility backend tag with a package-namespaced technique string; Phase 5 replaces this with typed provenance.
- The managed fixture now creates output parent directories before writing results, matching realistic extractor behavior under request-scoped paths.

## Verification

The following gates passed on 2026-08-26:

```text
swift test --filter 'ProcessExtractorProviderTests|ManagedExtractorProcessExecutorTests|RaceFreeProcessGroupRunnerTests'
15 tests passed

make lint
swift build
git diff --check
```

The tests install the real fixture binary as an immutable catalog revision via the Phase 3b writer, then exercise the full path: prepared conversion over pinned bytes, streamed progress text, HTML metadata propagation, nil fallback on a failure frame, and typed rejection of denied admission, digest mismatch, unknown revisions, and unregistered kinds.

## Remaining Phase 4 work

Nothing structural remains in Phase 4. The provider is ready for Phase 5 to consume it from generated plugins: registration factories wrapping `preparePDF`/`prepareHTML`, catalog reconciler, and the single-registry composition cutover.
