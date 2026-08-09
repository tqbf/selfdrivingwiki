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

`MarkdownRenderOptions` makes this policy explicit at the render boundary.
`WikiReaderView` creates one `.reader` option for the root conversion and
retains it for transclusion fetches; its `HighlightedCodeBlockBudget` is thus
document-wide rather than visitor-local. `ChatWebView` passes `.chat`, which
disables tokenization while retaining the ordinary escaped fence and its
original `language-<info>` class. Chat adds no token CSS and never emits an
`sdw-code-*` span.

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
records one runtime root and eight grammar parser or scanner roots, ten
non-system local includes, fourteen include edges, complete blob hashes,
licenses, candidate-byte verification, and zero escalations. Grammar-local
support headers preserve exact HTML and Scala closures without adding runtime
behavior.

## Performance and validation evidence

The release aggregate record is
`tmp/orchestration/markdown-renderer-embeds/benchmark/release-byte-buffer-aggregate-record.json`.
Its SHA-256 is
`8e08a7b88c5dc6a098d723d9f8282992ca2789744bba98444204e34411154055`.
It records three warmups and twenty release samples for each 100 KiB grammar
fixture. The total p95 values are Java 9.920 ms, Scala 12.185 ms, HTML 8.406
ms, Swift 11.725 ms, and JSON 8.729 ms. The largest RSS delta is Scala at
20.39 MiB. These samples establish the 100 KiB 50 ms latency criterion; the
maximum-size RSS criterion is established separately below.

The aggregate helper records parser, query, range-validation, HTML-assembly,
and total timings. It also records capture and emitted normalized-token counts;
the C ABI intentionally exposes no independent post-normalization range count,
so the emitted-token count is the observable range count. The direct UTF-8
builder removes per-token source strings and repeated UTF-8 conversion. It
keeps validated source order and first-range precedence. Query iteration and
overlap normalization remain linear.

The remediation release run reused the same production highlighter source hash
(`f0573c0497b941c149e9045406eebec4e8291400126f9486937bf243dde77337`) and
vendored C target as the app comparison. It ran the retained
`ReleaseCodeHighlightAggregateProbe` at the exact remediation head with three
warmups and twenty 100 KiB samples per grammar. Its p95 totals were Java
9.043 ms, Scala 12.229 ms, HTML 8.654 ms, Swift 11.521 ms, and JSON 8.650 ms.
Scala's 21.36 MiB fresh-process RSS delta was the largest. These are release
equivalent measurements: fixture creation, build/setup, and evidence writing
are outside the samples. The probe package reports one unhandled temporary
`Probe/main.swift` warning; that source is not in the aggregate executable or
the shipped app. The ignored exact-head record links the command, per-stage
values, hashes, and identity at
`tmp/orchestration/markdown-renderer-embeds/phase1-exact-head-evidence.json`.

The approved H1 exception has a separate before-and-after release measurement.
`tmp/orchestration/markdown-renderer-embeds/phase1-release-size-measurement-a40156d.json`
has SHA-256
`fd494056f59b8d99cb4f35a13e0c4ed53ba8a9825849ff0e81720863d26866df`.
It compares clean arm64 `make release` app bundles at base
`14f07d60093daf25596522924a77b6fa0742a23d` and implementation commit
`a40156d790eb5f686ad536f8b897e34f8bb22983`. The linked app executable grows
by 8,251,456 bytes. The approved C target contributes 8,165,388 bytes across
the runtime, five grammar parsers or scanners, and the query wrapper. The two
bundles each contain 124 files. They contain no test, benchmark, or fixture
artifact. The remaining 14,335 bundle bytes come from exact-head version data,
ad-hoc signatures, and one-byte MLX cache metadata variation. This measured
exception does not change the five-language set or any security policy.

The independent Claude audit at `e18c9f62230076954a9424b0a800210611ee3041`
also retained release measurements at the accepted 256 KiB maximum in
`tmp/orchestration/markdown-renderer-embeds/audit/maxblock-{java,scala,html,swift,json}.json`.
The p95 parse-plus-query values were Java 22.162 ms, Scala 31.527 ms, HTML
19.986 ms, Swift 28.799 ms, and JSON 22.927 ms. The largest observed RSS delta
was Scala at 31.19 MiB, below the 32 MiB requirement. Scala used 97.5% of that
budget, so F2 remains an architect-owned margin disposition rather than an
implementation claim of extra headroom.

The checked-in benchmark JSON is deterministic fixture metadata. It identifies
the source constructor, fixed units, byte truncation, and representative block
shape; ignored release records hold samples. The debug performance test is a
serialized diagnostic. Its `ru_maxrss` delta is process-wide and not
attributable solely to the highlighter, so it does not assert release latency
or RSS budgets. The release aggregate and maximum-block records remain the
performance evidence.

The committed `CodeHighlightBenchmarkFixtures` constructor supplies the
maximum-size nested Scala input. It repeats syntactically complete objects with
nested expressions, generic `Box[Map[String, List[Int]]]` values,
interpolation, and collection transformations, then finishes the exact byte
budget with a legal Scala line comment. The opt-in
`CodeHighlightPerformanceTests.releaseMaximumNestedScalaProbe` is the
reproducible fresh-process shell: each
`swift test -c release --filter CodeHighlightPerformanceTests.releaseMaximumNestedScalaProbe` invocation
performs three warmups and twenty measured calls after fixture construction.
It records parser, query, range-validation, HTML-assembly, and total p50/p95,
capture and emitted-token (validated-range) counts, and a clearly limited
process-wide RSS delta to the ignored benchmark directory. The exact-head
records are generated only after the corrective commit and are not shipped in
the app.

The supported SwiftPM sanitizer commands passed the focused six-test
highlighter suite. They were `WIKIFS_APP_TESTS=1 swift test --sanitize address
--filter CodeSyntaxHighlighterTests --jobs 4` and `WIKIFS_APP_TESTS=1 swift
test --sanitize thread --filter CodeSyntaxHighlighterTests --jobs 4`. The TSan
process emitted host CoreData XPC connection warnings during test-host
initialization, but no ThreadSanitizer fault; both selected suites passed. The
earlier manual `-Xlinker -fsanitize=address` command remains an Apple linker
limitation. It is not sanitizer success evidence.

## Review disposition

[`plans/markdown-renderer-code-highlighting-review-dispositions.json`](markdown-renderer-code-highlighting-review-dispositions.json)
is the finite disposition matrix for the earlier M1–M6 and L1–L11 findings and
the fresh F1–F10 findings. It binds both independent audit reports by SHA-256.
The F5 boundary is corrected by the explicit reader/chat policy and shared
reader-document budget. M4 and F7 are corrected by the committed deterministic
fixture constructor and fresh-process schema. F2 remains pending the new
exact-head maximum-size RSS evidence and a fresh independent audit; no margin
or threshold is claimed before that evidence exists.

## Maintenance and known limitation

All source is committed; builds neither fetch grammars nor use upstream `main`.
A refresh must pin immutable sources, repeat the closure audit, preserve
licenses, verify ABI compatibility, and update the inventory. Seven upstream
ICU macro-collision warnings from pinned Unicode headers are retained on this
macOS SDK. The vendor code is not suppressed or edited.
