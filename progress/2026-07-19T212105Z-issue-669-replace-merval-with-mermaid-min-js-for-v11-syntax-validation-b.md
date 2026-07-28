---
timestamp: 2026-07-19T212105Z
title: "2026-07-19 — Issue #669: Replace merval with mermaid.min.js for v11 syntax validation (branch `feature/mermaid-validator-v11`)"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-07-19 — Issue #669: Replace merval with mermaid.min.js for v11 syntax validation (branch `feature/mermaid-validator-v11`)

## Progress


**Problem.** `MermaidValidator` validated mermaid blocks via the vendored
`merval.bundle.js`, a third-party validator pinned to an older Mermaid grammar.
It rejected valid Mermaid v11 syntax like `A@{ shape: delay }` (the form the
official v11 docs use), so users couldn't save pages containing v11 diagrams —
even though the reader (upgraded to mermaid v11.16.0 in PR #648) renders them
fine. Classic version skew: one library renders, another validates.

**Fix.** Use the SAME vendored `mermaid.min.js` (v11.16.0) for validation that
the reader uses for rendering. Call `mermaid.parse(text)` in a `JSContext`;
if the returned Promise rejects, the diagram is invalid. Now anything that
renders also validates, and vice versa — no version skew possible.

**Key technical discoveries** (full write-up in `plans/669-mermaid-validator-v11.md`):

1. `mermaid.parse()` ALWAYS returns a Promise and never throws synchronously.
   The validator attaches `.then`/`.catch` to a holder object, then flushes the
   JSC microtask queue before reading the result.
2. Swift's JavaScriptCore overlay does NOT expose `JSPerformMicrotaskCheckpoint()`;
   we `dlsym` it from the system framework. ~1.5–2 ms per validation.
3. mermaid.min.js bundles DOMPurify, whose factory returns `undefined` without a
   DOM → `Zs.addHook is not a function`. A minimal DOM/timer/window polyfill is
   installed BEFORE evaluating the mermaid bundle. The polyfill source is
   documented in `MermaidValidator.domPolyfillJS` and the working scratch test
   `tmp/mermaid-test/test_polyfill.swift`.
4. The CORRECT v11 shape syntax is `A@{ shape: delay }` — NO square brackets.
   The bug report's literal `A[@{ shape: delay }]` (inside brackets) is actually
   INVALID mermaid syntax and is (correctly) rejected. merval rejected both
   forms; mermaid v11.16.0's own parser accepts the correct form.
5. mermaid is more lenient than merval: `flowchart LR\n  A B` is now VALID (the
   existing `MISSING_ARROW` test cases had to change). All genuine syntax errors
   come back with `code: "PARSE_ERROR"` (no more `MISSING_ARROW` etc.).

**Scope.**

- `Sources/WikiFSMarkdown/MermaidValidator.swift` — rewrote the JSContext
  setup: DOM polyfill → mermaid bundle → `mermaid.initialize()` →
  `globalThis.__merval.validateMermaid` wrapper (kept the `__merval` global name
  for call-site stability). `validateSingle` now calls the wrapper, flushes
  microtasks, reads the holder. `loadDefault()` resolves `mermaid.js` (was
  `merval.js`). Public API unchanged — callers in `PageCommand.swift` and
  `WikiStoreModel.swift` untouched.
- `build.sh` — removed the `MERVAL_JS` copy block. The existing `MERMAID_JS`
  block now produces the single `mermaid.js` used for BOTH rendering and
  validation. `Resources/merval.bundle.js` is left in the repo (deferred
  deletion).
- `Tests/WikiFSTests/MermaidValidatorTests.swift` — bundle loader switched to
  `mermaid.min.js`; "invalid" test bodies changed from `A B` to `A[unclosed`
  (mermaid accepts `A B`); `MISSING_ARROW` assertions replaced with
  `PARSE_ERROR`. New tests: `validV11ShapeSyntaxPasses`,
  `validV11ShapeRectPasses`, `invalidBracketAtSyntaxIsCaught`,
  `validV11ShapeSavesEndToEnd`.
- `Tests/WikiFSTests/MermaidEditorWarningTests.swift` — same bundle +
  invalid-body migration as above (was loading merval directly and asserting
  `MISSING_ARROW`).
- `Tests/WikiFSTests/WikiCtlCommandTests.swift` — `repoMermaidValidator()`
  switched to `mermaid.min.js`.
- `plans/669-mermaid-validator-v11.md` — NEW; full investigation + plan.

**Verification.** `swift build` passes; `swift test` passes (all 3046 tests in
260 suites, ~36 s). MermaidValidatorTests: 23/23 pass (including the new v11
cases). Per-validation latency ~2 ms; one-time JSContext + polyfill setup
~50–200 ms (amortized via `MermaidValidator.shared`).

**Open follow-ups.**

- Delete `Resources/merval.bundle.js` once the build is confirmed green in CI
  (deferred per the task spec).
- If a future mermaid bundle adds new DOM dependencies, extend
  `MermaidValidator.domPolyfillJS` (and re-verify via the scratch tests under
  `tmp/mermaid-test/`).

## Verification

Historical verification remains in the progress record above.
