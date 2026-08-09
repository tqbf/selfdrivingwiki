# Markdown renderer Phase 1: ordinary fenced-code highlighting

## Scope and safety contract

This phase adds native Tree-sitter highlighting only for ordinary fenced code in
the source Web reader. It does not add typed embeds, renderer packages, native
attachments, or package attachments. The original `language-<info>` class and
ordinary escaped-code behavior remain unchanged.

The closed language set is Java, Scala, HTML, Swift, and JSON. Only `xml` maps
to HTML and `jsonc` maps to JSON. Any other fence, source above 256 KiB,
document block after the first 100, cancellation, unavailable C result, or
invalid token result uses the existing escaped-code fallback.

The C boundary creates and destroys its parser, tree, query, and cursor during
one synchronous call. One query definition per grammar is initialized with
`pthread_once`. The initializer filters captures that have no closed-palette
mapping before it publishes the query. Swift receives a value-token buffer,
validates every byte range as a UTF-8 `String` boundary, and escapes source
bytes into one capacity-planned buffer. It wraps source only in the closed
`sdw-code-*` palette. No mutable Tree-sitter state crosses a task or actor
boundary. The implementation does not use `@unchecked Sendable`.

The pinned runtime proves the shared-query lifetime. `query.c` stores a
`const TSQuery *` in `TSQueryCursor` and declares
`ts_query_cursor_exec(TSQueryCursor *, const TSQuery *, TSNode)`. The cursor
owns execution state. Query mutation APIs accept `TSQuery *`. The host calls
those APIs only during `pthread_once` initialization. It never mutates a
published query.

## Pinned source provenance

The runtime is `tree-sitter/tree-sitter` v0.25.8,
`f2f197b6b27ce75c280c20f131d4f71e906b86f7`, tree
`b53cf95c7fcb4c9dd44277156edfa1c5a484d655`, MIT license blob
`451fe1d26ee6043ac94f6c8a81a6143f17748b4d`. Its Unicode data license is
retained beside the runtime license.

| Language | Upstream and immutable commit | Tree | MIT license blob |
| --- | --- | --- | --- |
| Java | `tree-sitter/tree-sitter-java` `94703d5a6bed02b98e438d7cad1136c01a60ba2c` | `f8e314b45faa4b1bd7c1ee795fc3f053a112b627` | `4e0446f76ca7d380d615e31b5500711df66a9ea2` |
| Scala | `tree-sitter/tree-sitter-scala` `2d55e74b0485fe05058ffe5e8155506c9710c767` | `7809f22f5dab0ac1b9581ea0e2b491bb92686415` | `bd0a4d6c7d625591c54e1f023b93af2a4650271a` |
| HTML | `tree-sitter/tree-sitter-html` `5a5ca8551a179998360b4a4ca2c0f366a35acc03` | `f86fd63225415ac83b15876fd0dd26630f892260` | `4b52d191cead337b11e274b79459a86f1b5a7779` |
| Swift | `alex-pinkus/tree-sitter-swift` lightweight tag `0.7.3-with-generated-files`, target `31d17fe7e818a2048c808b5c6fdc2dc792f4f5b5` | `eec1f03c95fd281f9426f83896ef69eb10d453ec` | `f158d7005311344ac316830fe68492214e1645e6` |
| JSON | `tree-sitter/tree-sitter-json` `ee35a6ebefcef0c5c416c0d1ccec7370cfca5a24` | `5d8e32e569c691bbf78473e6bfcb436a630f71fe` | `4b52d191cead337b11e274b79459a86f1b5a7779` |

The Swift ref is lightweight, not annotated. The investigated official snapshot
remains recorded as `tree-sitter/tree-sitter-swift`
`db675450dcc1478ee128c96ecc61c13272431aab`, tree
`6ee63c951e1d3ea7af54cac19d84c7ddf0e707e1`. The successor provides parser
`6ef7bd6096ad584013883faa991f962e9525bc0b`, scanner
`bb2dcac58b28652f3bd187914cd77a3d7092101e`, query
`82ad68d4ed1c8e4415452cd4d7f8c658148736d0`, and MIT license.

`tmp/orchestration/markdown-renderer-embeds/include-closure-manifest.json`
records nine parser/scanner roots, ten non-system local includes, fourteen
include edges, complete blob hashes, licenses, candidate-byte verification, and
zero escalations. Grammar-local support headers preserve exact HTML and Scala
closures without adding runtime behavior.

## Performance and validation evidence

The release aggregate record is
`tmp/orchestration/markdown-renderer-embeds/benchmark/release-byte-buffer-aggregate-record.json`.
Its SHA-256 is
`8e08a7b88c5dc6a098d723d9f8282992ca2789744bba98444204e34411154055`.
It records three warmups and twenty release samples for each 100 KiB grammar
fixture. The total p95 values are Java 9.920 ms, Scala 12.185 ms, HTML 8.406
ms, Swift 11.725 ms, and JSON 8.729 ms. The largest RSS delta is Scala at
20.39 MiB. Every result meets the 50 ms and 32 MiB requirements.

The aggregate helper records parser, query, range-validation, HTML-assembly,
and total timings. It also records capture and token counts. The direct UTF-8
builder removes per-token source strings and repeated UTF-8 conversion. It
keeps validated source order and first-range precedence. Query iteration and
overlap normalization remain linear.

The supported SwiftPM sanitizer commands passed the focused six-test
highlighter suite. They were `WIKIFS_APP_TESTS=1 swift test --sanitize address
--filter CodeSyntaxHighlighterTests --jobs 4` and `WIKIFS_APP_TESTS=1 swift
test --sanitize thread --filter CodeSyntaxHighlighterTests --jobs 4`. The TSan
process emitted host CoreData XPC connection warnings. It reported no sanitizer
fault and the suite passed. The earlier manual `-Xlinker -fsanitize=address`
command remains an Apple linker limitation. It is not sanitizer success
evidence.

## Maintenance and known limitation

All source is committed; builds neither fetch grammars nor use upstream `main`.
A refresh must pin immutable sources, repeat the closure audit, preserve
licenses, verify ABI compatibility, and update the inventory. Seven upstream
ICU macro-collision warnings from pinned Unicode headers are retained on this
macOS SDK. The vendor code is not suppressed or edited.
