---
timestamp: 2026-06-30T033610Z
title: "2026-06-29 — File Provider extension no longer links AppKit/PDFKit (macOS 26 crash)"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-06-29 — File Provider extension no longer links AppKit/PDFKit (macOS 26 crash)

## Progress


The `WikiFSFileProvider` extension crashed at launch on macOS 26 inside
`_EXRunningExtension._start` because its binary linked **AppKit** — forbidden
for a `com.apple.fileprovider-nonui` extension.

**Root cause.** `DisplayNameResolver` (in `WikiFSCore`) `import`s PDFKit, and
PDFKit transitively links AppKit. The extension links `WikiFSCore` as its sole
read-only dependency, so it inherited AppKit linkage even though it never runs
the PDF-title path.

**Fix (injectable seam).** PDF-title extraction is now injected:
`DisplayNameResolver.pdfTitleExtractor` defaults to a `nil`-returning closure,
keeping `WikiFSCore` — and therefore the extension — free of PDFKit/AppKit at
link time. The real PDFKit implementation lives in the **app** target
(`Sources/WikiFS/PDFTitleExtractor.swift`), which the extension does **not**
link, and is installed at launch via `DisplayNameResolver.installPDFTitleExtractor()`
(called from `WikiFSApp.init`). Non-app contexts (extension, `wikictl`, tests)
keep the default and fall through to the filename.

**MLX note.** This branch was originally built on top of a MiniLM/MLX embedding
feature series; that MLX work was **dropped** (it was a separate concern and
also pulled Metal/Accelerate/CoreML into the extension). The fix now stands on
`main` alone, where isolating PDFKit is *sufficient* to remove AppKit from the
extension. NL-based embeddings (PR #91) remain unaffected.

**Evidence.** `swift build` clean; 1211 tests pass; `otool -L` on the rebuilt
`WikiFSFileProvider` binary shows **no** AppKit/PDFKit/AVFoundation/Metal (only
FileProvider/Foundation/NaturalLanguage/JavaScriptCore/CFNetwork/Security). The
app binary still links PDFKit/AppKit, so PDF display-name resolution is
preserved. See PR #93.

## Verification

Historical verification remains in the progress record above.
