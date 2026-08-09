---
timestamp: 2026-08-08T210000Z
title: Markdown renderer Phase 1 native fenced-code highlighting
branch: feature/markdown-renderers-01-code-highlighting
status: active
phase: 1
---

# Markdown renderer Phase 1 native fenced-code highlighting

## Progress

Phase 1 adds native, vendored Tree-sitter token spans for ordinary Java, Scala,
HTML/XML, Swift, and JSON/JSONC code fences in the source Web reader. It keeps
the original fence language class, preserves escaped plain-code fallback, and
does not add typed embeds, renderer packages, native attachments, or package
attachments.

The C boundary owns mutable Tree-sitter state for one synchronous invocation.
Swift validates returned byte ranges against UTF-8 boundaries, escapes every
source slice, and emits only a fixed semantic token palette. The renderer has a
256 KiB per-block limit, a 100-block document limit, and cancellation fallback.
`MarkdownRenderOptions` makes the policy explicit: WikiReader shares one
document-wide highlighted-fence budget with its transclusions, while ChatWebView
uses a disabled policy and keeps fenced code escaped, inert, and free of
`sdw-code-*` spans.

The design and full immutable source/license provenance are in
[`plans/markdown-renderer-code-highlighting.md`](../plans/markdown-renderer-code-highlighting.md).
The tracked production-symbol and decision/error-branch inventory is
[`plans/markdown-renderer-code-highlighting-inventory.json`](../plans/markdown-renderer-code-highlighting-inventory.json).
The tracked finite review-disposition matrix is
[`plans/markdown-renderer-code-highlighting-review-dispositions.json`](../plans/markdown-renderer-code-highlighting-review-dispositions.json).
The ignored retained include-closure evidence is
`tmp/orchestration/markdown-renderer-embeds/include-closure-manifest.json`.

## Verification

Focused `MarkdownHTMLRendererTests` cover the five languages, approved aliases,
unsupported-language fallback, inert HTML, exact code text, limit fallback, and
cancellation fallback. Commit `a40156d790eb5f686ad536f8b897e34f8bb22983` is
the historical bounded Phase 1 candidate, not the current-head binding.
Delivery remains stopped while the exact-head audit findings close.

The H1 operator exception has a clean arm64 release comparison at base
`14f07d60093daf25596522924a77b6fa0742a23d` and implementation commit
`a40156d790eb5f686ad536f8b897e34f8bb22983`. The ignored record is
`tmp/orchestration/markdown-renderer-embeds/phase1-release-size-measurement-a40156d.json`.
Its SHA-256 is
`fd494056f59b8d99cb4f35a13e0c4ed53ba8a9825849ff0e81720863d26866df`.
It records an 8,251,456-byte linked app delta and no shipped test, benchmark,
or fixture file. The C contribution contains only the approved runtime, five
grammars, query wrapper, and reader implementation. The remaining audit gate
work binds normal-gate evidence to the exact remediation head. A release
aggregate rerun using the unchanged production highlighter source recorded
100 KiB p95 totals of 9.043 ms (Java), 12.229 ms (Scala), 8.654 ms (HTML),
11.521 ms (Swift), and 8.650 ms (JSON); its largest fresh-process RSS delta
was 21.36 MiB. `make build`, `make test`, bare SwiftPM tests, and focused
AddressSanitizer and ThreadSanitizer highlighter suites passed.
The TSan host emitted CoreData XPC environment warnings without a sanitizer
fault. Delivery readiness, push, and pull request actions remain stopped.

The operator reaffirmed the final exact-head H1 exception. The release
executable is 96,056,944 bytes. The final delta is 8,384,864 bytes. The prior
delta was 8,251,456 bytes. The additional approved growth is 133,408 bytes.
The final head is `f6cd101df847b92f2a439cabfbb1d7dd404d28c1`. The final tree is
`dfd81201b736fa82c7a14291858c22efe8698717`. The base and merge base are
`14f07d60093daf25596522924a77b6fa0742a23d`. The measurement used `make release`.
The final evidence record is
`tmp/orchestration/markdown-renderer-embeds/phase1-r1-final-head-evidence-f6cd101d.json`
with SHA-256
`88c68d53a82bd4134cd69178cfe0c999c3af7cece0662af394b590a3c444fd8d`.
The exception applies only to the five-grammar implementation and the same
124-file app attribution. It does not allow a new dependency, grammar, source
maximum, shipped test, benchmark, fixture, unrelated growth, or future waiver.
Any later identity, bundle, dependency, grammar, or unexplained size change
invalidates the exception and needs fresh evidence. PR 1 must disclose this
decision and its evidence.

The documentation-only successor may inherit F2 and H1 only while the canonical
measured-input manifest remains unchanged: `tmp/orchestration/markdown-renderer-embeds/measured-input-manifest-875a2438.json`
(SHA-256 `e4c330ef9b623621c2b52c639a54fc29cc33b901f466af684af840a9f126542e`).
The f6cd101d-to-875a2438 source/build-input diff is empty. Any manifest input,
bundle, dependency, grammar, query, fixture, build setting, or base change ends
this inheritance and requires new measurement and operator approval.

Canonical final-head evidence names the focused log
`tmp/orchestration/markdown-renderer-embeds/gates/focused-875a2438.log`
(SHA-256 `0fd1a3d085e8a92d4019aa9553d130e20e3ce317845fcdbfd12221d0cfd4dbf0`)
and make-test log `tmp/orchestration/markdown-renderer-embeds/gates/make-test-875a2438.log`
(SHA-256 `2bfc205bf508efa94fdb1e9ad0eb1e1ed04704dd770f404bd1dd6e25d14a779b`).
The nonempty prerequisite record is `gates/prerequisites-f6cd101d-r4.log`
(SHA-256 `115fc2d1c271aacc399f3e9131ae6d929cfe4c792c6882ea70034046512a9c1f`).

The independent `e18c9f62` audit measured every grammar at the accepted 256 KiB
maximum. Its worst parse-plus-query p95 was Scala at 31.527 ms and its highest
RSS delta was Scala at 31.19 MiB. The regular `CodeHighlightBenchmark` fresh
process later measured the committed nested Scala fixture at 36,306,944 bytes
(34.625 MiB), 2,752,512 bytes above the 32 MiB criterion. Operator exception
`operator-exception-phase-1-f2-memory-budget-20260809-001` accepts only this
exact five-grammar, 256 KiB, `nested-scala-maximum-v1` result. Its ignored
evidence is `tmp/orchestration/markdown-renderer-embeds/benchmark/f2-harness-74079438-validation.json`
(SHA-256 `ea1b9bbde0ee4cc0987bc85d3ff2262e12e9461f94b5bacae332953d14666e45`).
It does not change the 256 KiB pre-parse fallback, language set, query/runtime,
or general 32 MiB rule. The corrective pass fixes F5 by separating
the reader and chat policies and sharing the reader's budget with
TransclusionEmbedder. It also fixes M4/F7 with a committed deterministic nested
Scala fixture generator and regular SwiftPM executable measurement schema. The ignored probe
records stage timings, capture/token/range counts, and the explicitly limited
process-wide RSS delta. It does not change the five grammars, thresholds,
security policy, or later-phase scope. A fresh heterogeneous audit remains
required after the corrective commit.

The retained audit corroboration is
`tmp/orchestration/markdown-renderer-embeds/audit/phase1-independent-audit-e18c9f62.md`
(SHA-256 `391f363c01c92f3e9f9075548c7c834f1173610127b93655f1303c0e8eefdc70`).
The former per-grammar maxblock JSON files are not retained. The aggregate probe
remains retired. The `dd0ac890` documentation audit is
`tmp/orchestration/markdown-renderer-embeds/audit/phase1-independent-audit-dd0ac890.md`
(SHA-256 `4bba73445875156dc7f6d2c6cd32aec4013feadd435ac29919cc85e0d3ee4bf8`).
Its 99-input manifest remains `measured-input-manifest-875a2438.json`
(SHA-256 `e4c330ef9b623621c2b52c639a54fc29cc33b901f466af684af840a9f126542e`).
The four standalone benchmark harness sources are a required manifest addition
before the next measurement-affecting revision. They are not added now because
that would change the immutable measurement identity and require fresh evidence.

The app-enabled full SwiftPM suite is a documented non-pass. The approved base
`14f07d60093daf25596522924a77b6fa0742a23d` and candidate
`74079438437ad3177671285c4993392c6c135b9f` both exit 1 for
`LauncherChatAgentRuntimeTests.acpToolOutputKeepsTheDescriptorAndRendersRawOutputSafely`.
Each run has the same two wrapper assertions. The existing tool-detail helper
removes a complete provider-added Markdown fence before it escapes the payload.
The Phase 1 `.chat` option does not use that helper. The candidate log is
`tmp/test-logs/swift-test-20260809-073422.log` with SHA-256
`d6f938a46816ea0d1bf647037a416c58900ac8f9e27f4d4da68cb7a4e0e3eceb`.
The control manifest retains the exact-base comparison. This record does not
claim an app-enabled full-suite pass.

The M-1/M-2 corrective cycle removes the highlighting-enabled defaults from
both render entry points, makes absent reader context fail closed to disabled
highlighting, and reserves the shared document budget only after language,
size, cancellation, and basic highlighter eligibility pass. It also represents
the checked C ranges with a private validated-token stream before byte-buffer
assembly. The historical aggregate probe records `head == base` because its
out-of-tree harness captured identity incorrectly; it remains retained as
historical performance evidence and not exact-head proof. A new ignored
exact-head record binds this correction's F2, G1, app-size, sanitizer, and
normal-gate evidence without rewriting the historical artifacts.
